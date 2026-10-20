import Foundation

struct ReminderInputMatch: Equatable {
    let title: String
    let due: ReminderDue
    let ranges: [NSRange]
    let issue: String?
}

enum ReminderInputResult: Equatable {
    case none
    case matched(ReminderInputMatch)
    case needsAttention(String)
}

/// Parses one-off Chinese reminders without changing the user's input. All
/// ranges refer to the original UTF-16 text, including emoji/full-width digits.
enum ReminderInputParser {
    private enum Day {
        case offset(Int)
        case monthDay(year: Int?, month: Int?, day: Int)
        case monthOffset(Int, day: Int)
        case weekday(Int, week: Int?)
    }

    private struct Clock {
        var hour: Int
        let minute: Int
        var dayCarry = 0
        var impliedDay: Int?
    }

    private enum Value {
        case day(Day)
        case clock(Clock)
        case interval(TimeInterval)
        case issue(String)
    }

    private struct Token {
        let range: NSRange
        let value: Value
    }

    private enum Kind: Sendable {
        case fullDate, isoDate, monthDate, dayNumber, relativeDay, weekday
        case relativeTime, chineseTime, colonTime, englishTime, vagueTime, unsupportedRange
    }

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let kind: Kind
        init(_ pattern: String, _ kind: Kind) {
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.kind = kind
        }
    }

    private static let numberPattern = "(?:[0-9０-９]+|[零〇一二两兩三四五六七八九十百千]+)"
    private static let longPeriodPattern = "凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|晚间|夜里|夜间|今晚(?:上)?|明晚(?:上)?|今早|明早"
    private static let periodPattern = longPeriodPattern + "|晚|早"
    private static let rules: [Rule] = {
        let n = numberPattern
        let p = periodPattern
        return [
            Rule("(?<![0-9０-９])(?:半(?:个)?小时|\(n)(?:个)?半小时|\(n)(?:个)?小时(?:\(n)分钟?)?|\(n)分钟?|一刻钟)(?:之?后|以后)", .relativeTime),
            Rule("(?:(\(n))年\\s*)?(\(n))月\\s*(\(n))(?:日|号|號)", .fullDate),
            Rule("(?<![0-9０-９])([0-9０-９]{4})[-/]([0-9０-９]{1,2})[-/]([0-9０-９]{1,2})(?![0-9０-９])", .isoDate),
            Rule("(?:(?:\(p))\\s*)?\(n)\\s*[~～—-]\\s*\(n)(?:点|點|时|時|号|號|日)", .unsupportedRange),
            Rule("[-−]\(n)(?:点|點|时|時)", .unsupportedRange),
            Rule("(下个月|下月|本月|这个月)\\s*(\(n))(?:号|號|日)", .monthDate),
            Rule("(大后天|后天|後天|明天|明日|今天|今日|昨天|昨日|前天|\(n)天(?:之?后|以后))", .relativeDay),
            Rule("(下下|下|本|这)?(?:周|星期|礼拜)([一二三四五六日天1-7])", .weekday),
            Rule("(?:((?:\(p)))\\s*|(?<=周[一二三四五六日天1-7])|(?<=星期[一二三四五六日天1-7])|(?<=礼拜[一二三四五六日天1-7])|(?<![0-9０-９零〇一二两兩三四五六七八九十百千周期拜]))(\(n))\\s*(?:点|點|时|時)(?:\\s*(半|一刻|三刻|\(n)\\s*(?:分钟?|分鐘)?(?![0-9０-９零〇一二两兩三四五六七八九十百千点點时時])))?", .chineseTime),
            Rule("(?<![0-9０-９:：])(?:((?:\(p)))\\s*)?([0-9０-９]{1,3})[:：]([0-9０-９]{1,3})(?![0-9０-９]|\\s*[ap]m)", .colonTime),
            Rule("(?<![0-9０-９:：])([0-9０-９]{1,2})(?:[:：]([0-9０-９]{1,2}))?\\s*(am|pm)(?![a-z])", .englishTime),
            Rule("(?<![0-9０-９零〇一二两兩三四五六七八九十百千])(\(n))(?:号|號|日)", .dayNumber),
            Rule("(?:\(longPeriodPattern))", .vagueTime)
        ]
    }()

    private static let recurrence = try! NSRegularExpression(
        pattern: "每(?:隔|逢)|每(?:\(numberPattern))?(?:个)?(?:天|日|晚|早|周|星期|礼拜|月|年|小时|分钟)|隔(?:天|日|周|月)|工作日|周[一二三四五六日天][到至]周?([一二三四五六日天])"
    )
    private static let prefix = try! NSRegularExpression(pattern: "^\\s*(?:请)?(?:提醒我)?(?:在|于)?\\s*")
    private static let gap = try! NSRegularExpression(pattern: "^[\\s，,、。；;：:]*(?:(?:或者|或|和|及|与|到|至|的|在|于)\\s*)?$")

    static func parse(_ raw: String, now: Date, calendar: Calendar = .current) -> ReminderInputResult {
        let source = raw as NSString
        let full = NSRange(location: 0, length: source.length)
        guard source.length > 0, source.length <= 4_096 else { return .none }
        if recurrence.firstMatch(in: raw, range: full) != nil {
            return .needsAttention("暂不支持重复提醒，请改写为单次提醒或按原文创建。")
        }

        var candidates: [Token] = []
        for rule in rules {
            for match in rule.regex.matches(in: raw, range: full) {
                candidates.append(Token(range: match.range, value: value(for: rule.kind, match: match, source: source)))
            }
        }
        // Longest expressions win: a full date owns its day number, and a
        // complete clock owns its period label. Never parse a partial fallback
        // inside a longer, invalid expression.
        var tokens: [Token] = []
        for candidate in candidates.sorted(by: {
            $0.range.length == $1.range.length ? $0.range.location < $1.range.location : $0.range.length > $1.range.length
        }) {
            if !tokens.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) {
                tokens.append(candidate)
            }
        }
        tokens.sort { $0.range.location < $1.range.location }

        // Only temporal blocks at either edge are automatic. In particular,
        // "买28号电池" keeps its product number as part of the title.
        let prefixRange = prefix.firstMatch(in: raw, range: full)?.range ?? NSRange(location: 0, length: 0)
        var cursor = NSMaxRange(prefixRange)
        var selected: [Token] = []
        for token in tokens {
            guard token.range.location >= cursor else { continue }
            let between = source.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
            guard isGap(between) else { break }
            selected.append(token)
            cursor = NSMaxRange(token.range)
        }
        let hasLeadingBlock = !selected.isEmpty
        let leadingEnd = cursor
        cursor = source.length
        for token in tokens.reversed() {
            if selected.contains(where: { $0.range == token.range }) { break }
            let end = NSMaxRange(token.range)
            guard end <= cursor else { continue }
            let between = source.substring(with: NSRange(location: end, length: cursor - end))
            guard isGap(between) else { break }
            selected.append(token)
            cursor = token.range.location
        }
        guard !selected.isEmpty else { return .none }

        var days: [Day] = []
        var clocks: [Clock] = []
        var intervals: [TimeInterval] = []
        for token in selected {
            switch token.value {
            case .day(let day): days.append(day)
            case .clock(let clock):
                clocks.append(clock)
                if let offset = clock.impliedDay { days.append(.offset(offset)) }
            case .interval(let interval): intervals.append(interval)
            case .issue(let issue): return .needsAttention(issue)
            }
        }
        guard days.count <= 1, clocks.count <= 1, intervals.count <= 1,
              intervals.isEmpty || (days.isEmpty && clocks.isEmpty) else {
            return .needsAttention("识别到多个时间，请保留一个明确的提醒时间。")
        }

        let due: ReminderDue
        if let interval = intervals.first {
            due = ReminderDue(date: now.addingTimeInterval(interval), isAllDay: false)
        } else {
            let clock = clocks.first
            guard let day = resolve(days.first, clock: clock, now: now, calendar: calendar),
                  let instant = combine(day: day, clock: clock, calendar: calendar) else {
                return .needsAttention("日期或时间无效，请检查月份、日期和时刻。")
            }
            due = ReminderDue(date: instant, isAllDay: clock == nil)
        }

        // Remove whole temporal edge blocks, including their connecting
        // punctuation/particles, while retaining every character of the task.
        var ranges: [NSRange] = []
        if hasLeadingBlock { ranges.append(NSRange(location: 0, length: leadingEnd)) }
        if cursor < source.length { ranges.append(NSRange(location: cursor, length: source.length - cursor)) }
        let title = NSMutableString(string: raw)
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            title.deleteCharacters(in: range)
        }
        let cleaned = (title as String).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。；;：:")))
        let isPast = due.isAllDay
            ? calendar.startOfDay(for: due.date) < calendar.startOfDay(for: now)
            : due.date <= now
        return .matched(ReminderInputMatch(
            title: cleaned, due: due, ranges: ranges,
            issue: isPast ? "这个时间已经过去，请调整日期或时间。" : nil
        ))
    }

    private static func isGap(_ text: String) -> Bool {
        gap.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func value(for kind: Kind, match: NSTextCheckingResult, source: NSString) -> Value {
        func text(_ index: Int) -> String {
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
        func int(_ index: Int) -> Int { number(text(index)) ?? -1 }
        switch kind {
        case .fullDate:
            return .day(.monthDay(year: text(1).isEmpty ? nil : int(1), month: int(2), day: int(3)))
        case .isoDate:
            return .day(.monthDay(year: int(1), month: int(2), day: int(3)))
        case .monthDate:
            return .day(.monthOffset(text(1).hasPrefix("下") ? 1 : 0, day: int(2)))
        case .dayNumber:
            return .day(.monthDay(year: nil, month: nil, day: int(1)))
        case .relativeDay:
            let expression = text(1)
            let offsets = ["今天": 0, "今日": 0, "明天": 1, "明日": 1, "后天": 2, "後天": 2, "大后天": 3, "昨天": -1, "昨日": -1, "前天": -2]
            if let offset = offsets[expression] { return .day(.offset(offset)) }
            let count = expression.prefix { !"天".contains($0) }
            guard let offset = number(String(count)), (1 ... 3_650).contains(offset) else { return .issue("相对日期超出支持范围。") }
            return .day(.offset(offset))
        case .weekday:
            let week = text(1)
            let symbol = text(2)
            let weekdays = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
            let weekday = weekdays[symbol] ?? ((Int(symbol) ?? 7) % 7 + 1)
            let offset: Int? = week.isEmpty ? nil : (week == "下下" ? 2 : (week == "下" ? 1 : 0))
            return .day(.weekday(weekday, week: offset))
        case .relativeTime:
            let expression = source.substring(with: match.range)
            let hours = try! NSRegularExpression(pattern: "(\(numberPattern))(?:个)?(半)?小时")
            let minutes = try! NSRegularExpression(pattern: "(\(numberPattern))分钟?")
            var seconds: Double = 0
            for part in hours.matches(in: expression, range: NSRange(expression.startIndex..., in: expression)) {
                let string = expression as NSString
                seconds += Double(number(string.substring(with: part.range(at: 1))) ?? 0) * 3_600
                if part.range(at: 2).location != NSNotFound { seconds += 1_800 }
            }
            for part in minutes.matches(in: expression, range: NSRange(expression.startIndex..., in: expression)) {
                seconds += Double(number((expression as NSString).substring(with: part.range(at: 1))) ?? 0) * 60
            }
            if expression.hasPrefix("半") { seconds = 1_800 }
            if expression.hasPrefix("一刻钟") { seconds = 900 }
            guard seconds > 0, seconds <= 365 * 86_400 else { return .issue("相对时间超出支持范围。") }
            return .interval(seconds)
        case .chineseTime, .colonTime:
            let period = text(1)
            let minuteText = text(3).trimmingCharacters(in: .whitespaces)
            let minute: Int
            if minuteText == "半" { minute = 30 }
            else if minuteText == "一刻" { minute = 15 }
            else if minuteText == "三刻" { minute = 45 }
            else if minuteText.isEmpty { minute = 0 }
            else { minute = number(minuteText.replacingOccurrences(of: "分钟", with: "").replacingOccurrences(of: "分鐘", with: "").replacingOccurrences(of: "分", with: "").trimmingCharacters(in: .whitespaces)) ?? -1 }
            return clock(hour: int(2), minute: minute, period: period)
        case .englishTime:
            let hour = int(1)
            guard (1 ... 12).contains(hour) else { return .issue("12小时制的小时应在1到12之间。") }
            return clock(hour: hour % 12 + (text(3).lowercased() == "pm" ? 12 : 0), minute: text(2).isEmpty ? 0 : int(2), period: "")
        case .vagueTime:
            return .issue("请补充具体时刻，例如“晚上10点”。")
        case .unsupportedRange:
            return .issue("请使用一个有效的日期和具体时刻，暂不解析时间段。")
        }
    }

    private static func clock(hour: Int, minute: Int, period: String) -> Value {
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute) else {
            return .issue("时间无效：小时应在0到23之间，分钟应在0到59之间。")
        }
        var clock = Clock(hour: hour, minute: minute)
        if period.hasPrefix("今晚") || period.hasPrefix("明晚") {
            clock.impliedDay = period.hasPrefix("明") ? 1 : 0
        } else if period == "今早" || period == "明早" {
            clock.impliedDay = period == "明早" ? 1 : 0
        }
        let evening = ["傍晚", "晚上", "晚间", "夜里", "夜间"].contains(period) || period.contains("晚")
        if evening || period == "下午" {
            if hour > 0 && hour < 12 { clock.hour += 12 }
            if evening && (hour == 12 || hour == 0) { clock.hour = 0; clock.dayCarry = 1 }
            if evening && (13 ... 17).contains(hour) { return .issue("晚上的时刻不明确，请使用24小时制。") }
            if period == "下午" && hour == 0 { return .issue("下午的时刻不明确，请使用24小时制。") }
        } else if period == "中午" {
            if hour == 1 || hour == 2 { clock.hour += 12 }
            else if hour != 11 && hour != 12 { return .issue("中午的时刻不明确，请使用24小时制。") }
        } else if period == "凌晨" {
            if hour == 12 { clock.hour = 0 }
            else if hour > 6 { return .issue("凌晨的时刻不明确，请使用24小时制。") }
        } else if !period.isEmpty && hour > 12 {
            return .issue("上午的时刻不明确，请使用24小时制。")
        }
        return .clock(clock)
    }

    private static func number(_ raw: String) -> Int? {
        let text = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        if let value = Int(text), value >= 0 { return value }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        guard !text.isEmpty, text.count <= 12 else { return nil }
        if !text.contains(where: { "十百千".contains($0) }) {
            var value = 0
            for character in text {
                guard let digit = digits[character] else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        var result = 0
        var digit = 0
        var previousUnit = 10_000
        for character in text {
            if let next = digits[character] { digit = next }
            else {
                let unit = character == "十" ? 10 : (character == "百" ? 100 : (character == "千" ? 1_000 : 0))
                guard unit > 0, unit < previousUnit else { return nil }
                result += max(digit, 1) * unit
                digit = 0
                previousUnit = unit
            }
        }
        return result + digit
    }

    private static func resolve(_ day: Day?, clock: Clock?, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        guard let day else {
            guard let clock else { return nil }
            if let instant = combine(day: today, clock: clock, calendar: calendar), instant > now { return today }
            return calendar.date(byAdding: .day, value: 1, to: today)
        }
        switch day {
        case .offset(let offset):
            return calendar.date(byAdding: .day, value: offset, to: today)
        case .monthOffset(let offset, let day):
            guard let monthStart = calendar.dateInterval(of: .month, for: today)?.start,
                  let month = calendar.date(byAdding: .month, value: offset, to: monthStart) else { return nil }
            return exactDay(year: calendar.component(.year, from: month), month: calendar.component(.month, from: month), day: day, calendar: calendar)
        case .weekday(let weekday, let week):
            let current = calendar.component(.weekday, from: today)
            var offset: Int
            if let week {
                offset = -((current + 5) % 7) + (weekday + 5) % 7 + week * 7
            } else {
                offset = (weekday - current + 7) % 7
                if offset == 0, let clock, let instant = combine(day: today, clock: clock, calendar: calendar), instant <= now { offset = 7 }
            }
            return calendar.date(byAdding: .day, value: offset, to: today)
        case .monthDay(let year, let month, let day):
            guard (1 ... 31).contains(day), month.map({ (1 ... 12).contains($0) }) ?? true,
                  year.map({ (1 ... 9_999).contains($0) }) ?? true else { return nil }
            let currentYear = calendar.component(.year, from: today)
            if let month {
                if let year { return exactDay(year: year, month: month, day: day, calendar: calendar) }
                for offset in 0 ... 8 {
                    if let candidate = exactDay(year: currentYear + offset, month: month, day: day, calendar: calendar),
                       isUpcoming(candidate, clock: clock, now: now, calendar: calendar) { return candidate }
                }
            } else {
                guard let monthStart = calendar.dateInterval(of: .month, for: today)?.start else { return nil }
                for offset in 0 ... 12 {
                    guard let candidateMonth = calendar.date(byAdding: .month, value: offset, to: monthStart),
                          let candidate = exactDay(year: calendar.component(.year, from: candidateMonth), month: calendar.component(.month, from: candidateMonth), day: day, calendar: calendar) else { continue }
                    if isUpcoming(candidate, clock: clock, now: now, calendar: calendar) { return candidate }
                }
            }
            return nil
        }
    }

    private static func isUpcoming(_ day: Date, clock: Clock?, now: Date, calendar: Calendar) -> Bool {
        guard let instant = combine(day: day, clock: clock, calendar: calendar) else { return false }
        return clock == nil ? day >= calendar.startOfDay(for: now) : instant > now
    }

    private static func exactDay(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    private static func combine(day: Date, clock: Clock?, calendar: Calendar) -> Date? {
        guard let clock else { return calendar.startOfDay(for: day) }
        guard let targetDay = calendar.date(byAdding: .day, value: clock.dayCarry, to: day),
              let instant = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: targetDay),
              calendar.isDate(instant, inSameDayAs: targetDay),
              calendar.component(.hour, from: instant) == clock.hour,
              calendar.component(.minute, from: instant) == clock.minute else { return nil }
        return instant
    }
}

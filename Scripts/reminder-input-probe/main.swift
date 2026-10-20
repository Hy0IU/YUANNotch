import Foundation

struct ReminderDue: Equatable {
    let date: Date
    let isAllDay: Bool
}

@main
struct ReminderInputProbe {
    @MainActor
    static func main() {
        var failures = 0
        func check(_ name: String, _ passes: Bool) {
            print("\(passes ? "PASS" : "FAIL") \(name)")
            if !passes { failures += 1 }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, year: Int = 2026) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let now = date(10, 20, 12)
        let cases: [(String, String, Date, Bool)] = [
            ("28号晚上10点买药", "买药", date(10, 28, 22), false),
            ("28号晚10点买药", "买药", date(10, 28, 22), false),
            ("28号的晚上10点买药", "买药", date(10, 28, 22), false),
            ("二十八号晚上十点买药", "买药", date(10, 28, 22), false),
            ("２８号晚上１０点买药", "买药", date(10, 28, 22), false),
            ("明天上午九点半开会", "开会", date(10, 21, 9, 30), false),
            ("下周三下午三点交报告", "交报告", date(10, 28, 15), false),
            ("本周日交报告", "交报告", date(10, 25), true),
            ("周二晚上10点买药", "买药", date(10, 20, 22), false),
            ("周二上午9点买药", "买药", date(10, 27, 9), false),
            ("周三10点开会", "开会", date(10, 21, 10), false),
            ("周三三点开会", "开会", date(10, 21, 3), false),
            ("星期三三点开会", "开会", date(10, 21, 3), false),
            ("下周三下午15:30开会", "开会", date(10, 28, 15, 30), false),
            ("下下周一开会", "开会", date(11, 2), true),
            ("半小时后取快递", "取快递", date(10, 20, 12, 30), false),
            ("一个半小时后取快递", "取快递", date(10, 20, 13, 30), false),
            ("1小时30分钟后取快递", "取快递", date(10, 20, 13, 30), false),
            ("十五分钟后喝水", "喝水", date(10, 20, 12, 15), false),
            ("一刻钟后喝水", "喝水", date(10, 20, 12, 15), false),
            ("三天后交报告", "交报告", date(10, 23), true),
            ("10月28日买药", "买药", date(10, 28), true),
            ("2026年10月28号买药", "买药", date(10, 28), true),
            ("2026-10-28 22:30 买药", "买药", date(10, 28, 22, 30), false),
            ("请提醒我在明天晚上10点买药", "买药", date(10, 21, 22), false),
            ("买药，明晚10点", "买药", date(10, 21, 22), false),
            ("明天买药晚上10点", "买药", date(10, 21, 22), false),
            ("明天9pm开会", "开会", date(10, 21, 21), false),
            ("明天12am开会", "开会", date(10, 21), false),
            ("明天晚上12点买药", "买药", date(10, 22), false),
            ("晚上10点买药", "买药", date(10, 20, 22), false),
            ("上午10点买药", "买药", date(10, 21, 10), false),
            ("本月28号🛒买药", "🛒买药", date(10, 28), true),
            ("💊买药 明天晚上十点半", "💊买药", date(10, 21, 22, 30), false),
            ("1号买药", "买药", date(11, 1), true),
            ("下个月1号买药", "买药", date(11, 1), true),
            ("2月29号买药", "买药", date(2, 29, year: 2028), true)
        ]
        for (input, title, expected, allDay) in cases {
            let result = ReminderInputParser.parse(input, now: now, calendar: calendar)
            if case .matched(let match) = result {
                check(input, match.title == title && match.due.date == expected && match.due.isAllDay == allDay && match.issue == nil)
                if match.title != title || match.due.date != expected { print("  got \(match.title), \(match.due.date); expected \(title), \(expected)") }
            } else {
                check(input, false)
                print("  \(result)")
            }
        }
        for input in ["买28号电池", "买10个苹果", "第28号实验记录", "记录2026-10-28版本的问题", "买药", "🧪10点观察记录的结论", "早起读书"] {
            check("literal: \(input)", ReminderInputParser.parse(input, now: now, calendar: calendar) == .none)
        }
        for input in ["2月30号买药", "明天25点买药", "明天10:80买药", "明天或后天买药", "明天9点10点买药", "明天9-10点开会", "明天-1点开会", "每天晚上10点买药", "每周三下午3点开会", "买药每个月28号22点", "每两天买药", "周一、周三开会", "明天晚上买药"] {
            if case .needsAttention = ReminderInputParser.parse(input, now: now, calendar: calendar) {
                check("needs attention: \(input)", true)
            } else { check("needs attention: \(input)", false) }
        }
        if case .matched(let match) = ReminderInputParser.parse("今天上午9点买药", now: now, calendar: calendar) {
            check("explicit past date stays visible as a warning", match.issue != nil && match.due.date == date(10, 20, 9))
        } else { check("explicit past date", false) }
        if case .matched(let match) = ReminderInputParser.parse("31号买药", now: date(4, 30), calendar: calendar) {
            check("missing day skips to the next valid month", match.due.date == date(5, 31))
        } else { check("missing day", false) }
        if case .matched(let match) = ReminderInputParser.parse("1月1号买药", now: date(12, 31), calendar: calendar) {
            check("year rollover", match.due.date == date(1, 1, year: 2027))
        } else { check("year rollover", false) }
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let beforeDST = pacific.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        if case .needsAttention = ReminderInputParser.parse("明天凌晨2点半喝水", now: beforeDST, calendar: pacific) {
            check("DST gaps never silently change the requested clock", true)
        } else { check("DST gaps", false) }

        var clock = now
        let composer = ReminderComposer(nowProvider: { clock }, calendar: calendar)
        composer.draft = "28号晚上10点买药"
        let preview = composer.resolution(now: clock).due
        check("recognition preserves the raw input and uses compact menu previews",
              composer.draft == "28号晚上10点买药" && !composer.showsCustomRow
                && composer.displayedDateOption == .custom && composer.displayedTimeOption == .custom)
        let created = composer.consume()
        check("Return consumes exactly the previewed title and timestamp",
              created?.title == "买药" && created?.due == preview && preview?.date == date(10, 28, 22))
        check("create resets automatic/manual/literal state for the next item",
              composer.draft.isEmpty && composer.inputResult == .none && !composer.hasManualDueSelection
                && !composer.usesLiteralInput && composer.dateOption == .none && composer.timeOption == .none)

        composer.draft = "半小时后取快递"
        let relativePreview = composer.resolution(now: clock).due
        clock = clock.addingTimeInterval(90)
        check("relative due time does not drift between preview and Return",
              composer.consume()?.due == relativePreview && relativePreview?.date == now.addingTimeInterval(1_800))

        composer.draft = "28号晚上10点买药"
        composer.select(dateOption: .tomorrow)
        check("changing the recognized day keeps its clock",
              composer.resolution(now: clock).due?.date == date(10, 21, 22) && composer.hasManualDueSelection)
        composer.draft = "29号晚上8点买药和水果"
        let manual = composer.consume()
        check("later typing cannot overwrite a manual due choice",
              manual?.title == "买药和水果" && manual?.due?.date == date(10, 21, 22))

        composer.draft = "28号晚上10点买药"
        composer.select(dateOption: .none)
        check("explicit No Date clears the detected clock too", composer.consume()?.due == nil)
        composer.draft = "28号晚上10点买药"
        composer.select(timeOption: .none)
        let allDay = composer.consume()
        check("explicit No Time retains the recognized day as all-day",
              allDay?.due?.date == date(10, 28) && allDay?.due?.isAllDay == true)

        composer.draft = "28号晚上10点买药"
        composer.setLiteralInput(true)
        let literal = composer.consume()
        check("literal override preserves the whole text without an automatic due date",
              literal?.title == "28号晚上10点买药" && literal?.due == nil && !composer.usesLiteralInput)
        composer.draft = "2月30号买药"
        check("invalid input cannot create or erase the draft",
              !composer.canCommit && composer.consume() == nil && composer.draft == "2月30号买药")
        composer.draft = "每天晚上10点买药"
        check("repeated reminders are never silently created as one-off items",
              composer.inputIssue != nil && !composer.canCommit && composer.consume() == nil)
        composer.setLiteralInput(true)
        check("a repeated phrase can be kept only as an explicit plain-text choice",
              composer.consume()?.title == "每天晚上10点买药")

        composer.draft = "今天上午9点买药"
        check("explicit past time prompts instead of rolling forward", composer.inputIssue != nil && !composer.canCommit)
        composer.select(dateOption: .tomorrow)
        check("manual date correction resolves a past-time warning", composer.canCommit && composer.consume()?.due?.date == date(10, 21, 9))
        composer.draft = "明天晚上10点"
        check("a date without a task cannot create an empty reminder", !composer.canCommit && composer.inputIssue != nil)
        composer.draft = "1分钟后喝水"
        clock = clock.addingTimeInterval(120)
        check("a stale preview is not silently reinterpreted at submission",
              composer.consume() == nil && composer.submissionIssue != nil && !composer.draft.isEmpty)

        print(failures == 0 ? "every check passed" : "\(failures) checks failed")
        if failures > 0 { exit(1) }
    }
}

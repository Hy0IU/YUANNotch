import Foundation

struct AssistantAgendaError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A civil day is not a midnight UTC timestamp. Its Date is the start of that day
/// in the snapshot's viewing zone, which must still match at approval time.
struct AssistantAgendaDate: Equatable, Sendable {
    let date: Date
    let dayOnly: Bool

    static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func parse(_ text: String, in zone: TimeZone) throws -> Self {
        let invalid = AssistantAgendaError("Use a valid yyyy-MM-dd date or an ISO 8601 date and time with an explicit UTC offset.")
        // Validate the entire input before Foundation can normalize an impossible
        // date, infer a missing zone, or silently ignore trailing text.
        guard text.utf8.count <= 32 else { throw invalid }
        let parts = text.split(separator: "T", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let day = parts[0].wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})/),
              let year = Int(day.1), year > 0, let month = Int(day.2), let number = Int(day.3) else { throw invalid }
        var components = DateComponents(year: year, month: month, day: number)
        var dateZone = zone
        var milliseconds = 0
        if parts.count == 2 {
            guard let clock = parts[1].wholeMatch(of: /([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]{1,3}))?)?(Z|[+-][0-9]{2}:?[0-9]{2})/),
                  let hour = Int(clock.1), hour < 24, let minute = Int(clock.2), minute < 60 else { throw invalid }
            let second = clock.3.flatMap { Int($0) } ?? 0
            guard second < 60 else { throw invalid }
            components.hour = hour
            components.minute = minute
            components.second = second
            if let fraction = clock.4 { milliseconds = Int((String(fraction) + "00").prefix(3)) ?? 0 }
            if clock.5 == "Z" {
                dateZone = .gmt
            } else {
                let offset = clock.5.dropFirst()
                guard let hours = Int(offset.prefix(2)), let minutes = Int(offset.suffix(2)), minutes < 60, hours * 60 + minutes <= 18 * 60,
                      let fixed = TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (clock.5.first == "-" ? -1 : 1)) else { throw invalid }
                dateZone = fixed
            }
        }
        let calendar = Self.calendar(in: dateZone)
        guard let date = calendar.date(from: components) else { throw invalid }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == year, actual.month == month, actual.day == number else { throw invalid }
        if parts.count == 1 { return Self(date: calendar.startOfDay(for: date), dayOnly: true) }
        guard actual.hour == components.hour, actual.minute == components.minute, actual.second == components.second else { throw invalid }
        return Self(date: date.addingTimeInterval(Double(milliseconds) / 1000), dayOnly: false)
    }

    func text(in zone: TimeZone) -> String {
        if dayOnly {
            let day = Self.calendar(in: zone).dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
        }
        return date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: date.timeIntervalSinceReferenceDate.rounded() != date.timeIntervalSinceReferenceDate, timeZone: zone))
    }

    func reminderComponents(in zone: TimeZone) -> DateComponents {
        // Timed values use UTC, so even the repeated hour at a DST transition
        // represents the instant approved. Date-only reminders are floating.
        let calendar = Self.calendar(in: dayOnly ? zone : .gmt)
        let units: Set<Calendar.Component> = dayOnly ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute, .second, .nanosecond]
        var components = calendar.dateComponents(units, from: date)
        components.calendar = calendar
        components.timeZone = dayOnly ? nil : .gmt
        return components
    }
}

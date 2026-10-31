import Foundation

enum ScheduleSourceKind: String, CaseIterable, Sendable {
    case calendar
    case reminders
}

enum ScheduleAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case writeOnly
    case fullAccess

    var canRead: Bool { self == .fullAccess }
}

struct ScheduleColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
}

/// A readable EventKit calendar or reminders list, including read-only sources.
struct ScheduleSource: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let account: String
    let kind: ScheduleSourceKind
    let color: ScheduleColor

    var key: String { "\(kind.rawValue):\(id)" }
}

/// A value snapshot, never an EventKit object. `start` is a reminder's due date,
/// not a scheduled start; only events have an end or occupy a time interval.
struct ScheduleEntry: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let kind: ScheduleSourceKind
    let title: String
    let start: Date
    let end: Date?
    let isAllDay: Bool
    let location: String?

    func occurs(on day: Date, calendar: Calendar) -> Bool {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return false }
        if kind == .calendar, let end, end > start {
            return start < interval.end && end > interval.start
        }
        return start >= interval.start && start < interval.end
    }
}

struct ScheduleDay: Identifiable, Equatable {
    let date: Date
    let reminders: [ScheduleEntry]
    let events: [ScheduleEntry]

    var id: Date { date }

    static func make(date: Date, entries: [ScheduleEntry], calendar: Calendar) -> ScheduleDay {
        let day = calendar.startOfDay(for: date)
        var reminders: [ScheduleEntry] = []
        var events: [ScheduleEntry] = []
        for entry in entries where entry.occurs(on: day, calendar: calendar) {
            switch entry.kind {
            case .calendar: events.append(entry)
            case .reminders: reminders.append(entry)
            }
        }
        func precedes(_ lhs: ScheduleEntry, _ rhs: ScheduleEntry) -> Bool {
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.title != rhs.title { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
            return lhs.id < rhs.id
        }
        reminders.sort(by: precedes)
        events.sort(by: precedes)
        return ScheduleDay(date: day, reminders: reminders, events: events)
    }
}

/// Shared query boundary for the schedule surface and future local consumers.
/// Calendar-day queries deliberately do not use Plans' 04:00 accounting boundary.
protocol ScheduleServing: Sendable {
    func authorization(for kind: ScheduleSourceKind) -> ScheduleAuthorization
    func requestAccess(for kind: ScheduleSourceKind) async throws -> ScheduleAuthorization
    func sources(for kind: ScheduleSourceKind) async -> [ScheduleSource]
    func entries(in range: DateInterval, sources: [ScheduleSource]) async throws -> [ScheduleEntry]
    func changes() async -> AsyncStream<Void>
}

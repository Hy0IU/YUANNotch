import AppKit
import EventKit
import Foundation

/// Owns a notification registration without requiring an actor-isolated deinit.
/// The token is immutable; NotificationCenter supports removal from any thread.
final class ScheduleNotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(
        center: NotificationCenter = .default,
        name: Notification.Name,
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: nil, using: handler)
    }

    deinit { center.removeObserver(token) }
}

enum ScheduleServiceError: LocalizedError {
    case readAccessRequired(ScheduleSourceKind, ScheduleAuthorization)
    case sourcesUnavailable(ScheduleSourceKind)
    case reminderFetchFailed
    case accessRequestFailed(ScheduleSourceKind, String)

    var errorDescription: String? {
        switch self {
        case .readAccessRequired(let kind, let authorization):
            let name = kind == .calendar ? "Calendar" : "Reminders"
            switch authorization {
            case .notDetermined:
                return "\(name) access has not been requested. Allow access to read its schedule."
            case .denied:
                return "\(name) access is denied. Allow access in System Settings → Privacy & Security."
            case .restricted:
                return "\(name) access is restricted by this Mac's privacy policy."
            case .writeOnly:
                return "\(name) has write-only access. Full access is required to read the schedule."
            case .fullAccess:
                return "\(name) read access is unavailable."
            }
        case .sourcesUnavailable(let kind):
            return kind == .calendar
                ? "A selected calendar is no longer available. Refresh the calendar sources."
                : "A selected reminders list is no longer available. Refresh the reminders sources."
        case .reminderFetchFailed:
            return "EventKit could not read reminders: the query returned no result."
        case .accessRequestFailed(let kind, let reason):
            let name = kind == .calendar ? "Calendar" : "Reminders"
            return "Could not request \(name) access: \(reason)"
        }
    }
}

/// Schedule reads share the reminders actor and its EventKit connection.
/// Separate stores can disagree about permissions: EventKit's class-level
/// status query may read a connection created before the other store's grant.
extension AppleRemindersService: ScheduleServing {

    nonisolated func authorization(for kind: ScheduleSourceKind) -> ScheduleAuthorization {
        switch EKEventStore.authorizationStatus(for: Self.entityType(for: kind)) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .writeOnly: .writeOnly
        case .fullAccess: .fullAccess
        @unknown default: .denied
        }
    }

    func requestAccess(for kind: ScheduleSourceKind) async throws -> ScheduleAuthorization {
        try Task.checkCancellation()
        let granted: Bool
        do {
            switch kind {
            case .calendar:
                granted = try await store.requestFullAccessToEvents()
            case .reminders:
                granted = try await store.requestFullAccessToReminders()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = error as NSError
            throw ScheduleServiceError.accessRequestFailed(
                kind,
                "\(failure.localizedDescription) (\(failure.domain), \(failure.code))"
            )
        }
        // An EventKit store touched before a grant can retain an empty view.
        // No calendars or items are cached, so resetting cannot stale a cache.
        store.reset()
        try Task.checkCancellation()
        return granted ? .fullAccess : authorization(for: kind)
    }

    func sources(for kind: ScheduleSourceKind) async -> [ScheduleSource] {
        guard authorization(for: kind).canRead, !Task.isCancelled else { return [] }
        store.refreshSourcesIfNecessary()
        return store.calendars(for: Self.entityType(for: kind))
            .map { calendar in
                ScheduleSource(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    account: calendar.source?.title ?? "",
                    kind: kind,
                    color: Self.color(from: calendar)
                )
            }
            .sorted {
                if $0.account != $1.account {
                    return $0.account.localizedStandardCompare($1.account) == .orderedAscending
                }
                if $0.title != $1.title {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.id < $1.id
            }
    }

    func entries(in range: DateInterval, sources: [ScheduleSource]) async throws -> [ScheduleEntry] {
        try Task.checkCancellation()
        var result: [ScheduleEntry] = []
        for kind in ScheduleSourceKind.allCases {
            let requested = sources.filter { $0.kind == kind }
            guard !requested.isEmpty else { continue }
            try requireReadAccess(for: kind)
            let identifiers = Set(requested.map(\.id))
            // Include subscribed and other read-only sources. Writability has
            // no bearing on whether a calendar belongs in this read surface.
            let calendars = store.calendars(for: Self.entityType(for: kind))
                .filter { identifiers.contains($0.calendarIdentifier) }
            guard calendars.count == identifiers.count else {
                throw ScheduleServiceError.sourcesUnavailable(kind)
            }
            guard range.duration > 0 else { continue }
            switch kind {
            case .calendar:
                result.append(contentsOf: try eventEntries(in: range, calendars: calendars))
            case .reminders:
                // Query incomplete items, then filter their actual components.
                // EventKit's absolute-date predicate can omit a floating civil
                // due date when its stored time zone differs from the Mac's.
                let predicate = store.predicateForIncompleteReminders(
                    withDueDateStarting: nil,
                    ending: nil,
                    calendars: calendars
                )
                let entries = try await reminderEntries(matching: predicate)
                result.append(contentsOf: entries.filter { Self.intersects($0, range: range) })
            }
            try Task.checkCancellation()
            try requireReadAccess(for: kind)
        }
        return result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }

    private func eventEntries(in range: DateInterval, calendars: [EKCalendar]) throws -> [ScheduleEntry] {
        var entriesByID: [String: ScheduleEntry] = [:]
        var cursor = range.start
        let calendar = Calendar(identifier: .gregorian)
        // EventKit event predicates have a maximum search span. Year-sized
        // queries keep freely expanded schedule ranges complete, and IDs merge
        // cross-boundary/multi-day events returned by adjacent queries.
        while cursor < range.end {
            try Task.checkCancellation()
            let nextYear = calendar.date(byAdding: .year, value: 1, to: cursor) ?? range.end
            let end = min(nextYear, range.end)
            let predicate = store.predicateForEvents(withStart: cursor, end: end, calendars: calendars)
            for event in store.events(matching: predicate) {
                if let entry = Self.entry(from: event), Self.intersects(entry, range: range) {
                    entriesByID[entry.id] = entry
                }
            }
            cursor = end
        }
        return Array(entriesByID.values)
    }

    private func reminderEntries(matching predicate: NSPredicate) async throws -> [ScheduleEntry] {
        let calendar = Calendar.autoupdatingCurrent
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: ScheduleServiceError.reminderFetchFailed)
                    return
                }
                // Only value snapshots cross the callback's isolation boundary.
                continuation.resume(returning: reminders.compactMap {
                    Self.entry(from: $0, calendar: calendar)
                })
            }
        }
    }

    // MARK: - Value projections

    nonisolated static func entry(from event: EKEvent) -> ScheduleEntry? {
        guard let sourceID = event.calendar?.calendarIdentifier,
              !sourceID.isEmpty,
              let itemID = event.calendarItemIdentifier as String?, !itemID.isEmpty,
              let start = event.startDate,
              let end = event.endDate else { return nil }
        let occurrence = event.occurrenceDate ?? start
        return ScheduleEntry(
            id: occurrenceID(sourceID: sourceID, itemID: itemID, occurrenceDate: occurrence),
            sourceID: sourceID,
            kind: .calendar,
            title: event.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            location: event.location
        )
    }

    nonisolated static func entry(
        from reminder: EKReminder,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ScheduleEntry? {
        guard !reminder.isCompleted,
              let sourceID = reminder.calendar?.calendarIdentifier,
              !sourceID.isEmpty,
              let itemID = reminder.calendarItemIdentifier as String?, !itemID.isEmpty,
              let components = reminder.dueDateComponents,
              let due = dueDate(from: components, calendar: calendar) else { return nil }
        return ScheduleEntry(
            id: "reminders:\(sourceID):\(itemID)",
            sourceID: sourceID,
            kind: .reminders,
            title: reminder.title ?? "",
            start: due.date,
            end: nil,
            isAllDay: due.isAllDay,
            location: nil
        )
    }

    nonisolated static func dueDate(
        from components: DateComponents,
        calendar: Calendar = .autoupdatingCurrent
    ) -> (date: Date, isAllDay: Bool)? {
        guard components.year != nil, components.month != nil, components.day != nil else { return nil }
        let isAllDay = components.hour == nil && components.minute == nil
            && components.second == nil && components.nanosecond == nil
        var dueCalendar = components.calendar ?? calendar
        // A date-only reminder names a civil day, not midnight in a remote
        // zone. Keep its Y/M/D in the viewing zone instead of shifting its day.
        // Timed reminders honor an explicit zone; nil means the current zone.
        dueCalendar.timeZone = isAllDay ? calendar.timeZone : (components.timeZone ?? calendar.timeZone)
        var components = components
        components.calendar = nil
        components.timeZone = nil
        guard let date = dueCalendar.date(from: components) else { return nil }
        return (isAllDay ? calendar.startOfDay(for: date) : date, isAllDay)
    }

    nonisolated static func occurrenceID(sourceID: String, itemID: String, occurrenceDate: Date) -> String {
        "calendar:\(sourceID):\(itemID):\(occurrenceDate.timeIntervalSinceReferenceDate.bitPattern)"
    }

    private nonisolated static func intersects(_ entry: ScheduleEntry, range: DateInterval) -> Bool {
        if entry.kind == .calendar, let end = entry.end, end > entry.start {
            return entry.start < range.end && end > range.start
        }
        return entry.start >= range.start && entry.start < range.end
    }

    private nonisolated static func color(from calendar: EKCalendar) -> ScheduleColor {
        guard let cgColor = calendar.cgColor,
              let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
            return ScheduleColor(red: 0.5, green: 0.5, blue: 0.5)
        }
        return ScheduleColor(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
    }

    private nonisolated static func entityType(for kind: ScheduleSourceKind) -> EKEntityType {
        kind == .calendar ? .event : .reminder
    }

    private func requireReadAccess(for kind: ScheduleSourceKind) throws {
        let status = authorization(for: kind)
        guard status.canRead else { throw ScheduleServiceError.readAccessRequired(kind, status) }
    }

}

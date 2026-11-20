import EventKit
import Foundation

struct AssistantAgendaSnapshot: Sendable {
    let modelContext: String
    fileprivate let generation: UUID
    fileprivate let zone: TimeZone
    fileprivate let sources: [AgendaSource]
    fileprivate let records: [String: AgendaRecord]
}

/// An approval capability, not a decoded model payload. Only prepare can issue
/// one, for the exact before/after values shown, and apply can consume it once.
@MainActor final class AssistantPreparedChange {
    let headline: String
    let summary: String
    fileprivate let generation: UUID
    fileprivate let source: AgendaSource
    fileprivate let before: AgendaRecord?
    fileprivate let after: AgendaValues
    fileprivate let zone: TimeZone
    fileprivate var consumed = false

    fileprivate init(headline: String, summary: String, snapshot: AssistantAgendaSnapshot, source: AgendaSource, before: AgendaRecord?, after: AgendaValues) {
        self.headline = headline
        self.summary = summary
        generation = snapshot.generation
        self.source = source
        self.before = before
        self.after = after
        zone = snapshot.zone
    }
}

private enum AgendaEntity: String, Encodable, Sendable {
    case reminder, event
    var ekType: EKEntityType { self == .reminder ? .reminder : .event }
    var sourceName: String { self == .reminder ? "Reminders list" : "Calendar" }
}

private struct AgendaSource: Equatable, Sendable {
    let id: String
    let kind: AgendaEntity
    let title: String
    let account: String
    let accountID: String?
    let writable: Bool
}

private extension AgendaSource {

    init(_ calendar: EKCalendar, kind: AgendaEntity) {
        id = calendar.calendarIdentifier
        self.kind = kind
        title = calendar.title
        account = calendar.source?.title ?? ""
        accountID = calendar.source?.sourceIdentifier
        writable = calendar.allowsContentModifications && !calendar.isSubscribed && calendar.type != .birthday
    }
}

private struct AgendaValues: Equatable, Sendable {
    var title: String
    var due: AssistantAgendaDate?
    var start: AssistantAgendaDate?
    var end: AssistantAgendaDate?
    var completed: Bool?

    func description(in zone: TimeZone) -> String {
        var result = "Title: \(quoted(title))"
        if let completed {
            result += "\nDue: \(due?.text(in: zone) ?? "None")\nStatus: \(completed ? "Completed at approval" : "Open")"
        } else if let start, let end {
            result += "\nStart: \(start.text(in: zone))\nEnd (exclusive): \(end.text(in: zone))"
            result += start.dayOnly ? "\nAll-day event" : "\nTimed event"
        }
        return result
    }

    func compactTiming(in zone: TimeZone) -> String {
        func label(_ value: AssistantAgendaDate, omitDay: Bool = false) -> String {
            value.date.formatted(Date.FormatStyle(date: omitDay ? .omitted : .abbreviated, time: value.dayOnly ? .omitted : .shortened, timeZone: zone))
        }
        if let start, let end {
            let calendar = AssistantAgendaDate.calendar(in: zone)
            if start.dayOnly, calendar.date(byAdding: .day, value: 1, to: start.date) == end.date { return "\(label(start)) (all day)" }
            let sameDay = !start.dayOnly && calendar.isDate(start.date, inSameDayAs: end.date)
            return "\(label(start))–\(label(end, omitDay: sameDay))" + (start.dayOnly ? " (end exclusive)" : "")
        }
        return due.map { "Due \(label($0))" } ?? "No due date"
    }
}

private func quoted(_ value: String) -> String {
    // Keep a title containing newlines or directional overrides from looking
    // like another field in the locally authored approval.
    var result = ""
    for scalar in value.debugDescription.unicodeScalars {
        if CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{2028}" || scalar == "\u{2029}" {
            result += "\\u{\(String(scalar.value, radix: 16))}"
        } else { result.unicodeScalars.append(scalar) }
    }
    return result
}

/// Count only the alerts eligible for a due-date edit. Never send alarm
/// contents to the model or replace a reminder's whole alarm array.
private struct ReminderAlertCounts: Equatable, Sendable {
    let total: Int
    let atDue: Int

    static func matches(_ alarm: EKAlarm, due: AssistantAgendaDate?) -> Bool {
        guard let due, !due.dayOnly, alarm.absoluteDate == due.date else { return false }
        return alarm.type == .display && alarm.proximity == .none && alarm.structuredLocation == nil
            && alarm.soundName == nil && alarm.emailAddress == nil
    }

    static func read(_ reminder: EKReminder, due: AssistantAgendaDate?) -> Self? {
        let alarms = reminder.alarms ?? []
        guard reminder.hasAlarms == !alarms.isEmpty else { return nil }
        return Self(total: alarms.count, atDue: alarms.count(where: { matches($0, due: due) }))
    }
}

private struct AgendaRecord: Equatable, Sendable {
    let id: String
    let sourceID: String
    let kind: AgendaEntity
    let values: AgendaValues
    let modified: Date?
    let created: Date?
    let zone: TimeZone?
    let reminderStart: DateComponents?
    let reminderDue: DateComponents?
    let reminderAlerts: ReminderAlertCounts?
    let restriction: String?
}

private extension AgendaRecord {

    init?(_ item: EKCalendarItem, kind: AgendaEntity, viewingZone: TimeZone) {
        guard let calendar = item.calendar, !item.calendarItemIdentifier.isEmpty else { return nil }
        id = item.calendarItemIdentifier
        sourceID = calendar.calendarIdentifier
        self.kind = kind
        modified = item.lastModifiedDate
        created = item.creationDate
        zone = item.timeZone
        var values = AgendaValues(title: item.title ?? "")
        var restriction: String?
        if modified == nil { restriction = "EventKit did not supply an edit version." }
        if item.hasRecurrenceRules || item.hasAttendees { restriction = "Recurring or shared items cannot be changed here." }
        if !calendar.allowsContentModifications { restriction = "The source is read-only." }
        switch kind {
        case .reminder:
            guard let reminder = item as? EKReminder else { return nil }
            reminderStart = reminder.startDateComponents
            reminderDue = reminder.dueDateComponents
            values.completed = reminder.isCompleted
            if let components = reminderDue {
                guard let due = AppleRemindersService.dueDate(from: components, calendar: AssistantAgendaDate.calendar(in: viewingZone)) else { return nil }
                values.due = AssistantAgendaDate(date: due.date, dayOnly: due.isAllDay)
            }
            reminderAlerts = ReminderAlertCounts.read(reminder, due: values.due)
            if reminder.isCompleted { restriction = "The reminder is already completed." }
        case .event:
            guard let event = item as? EKEvent, let start = event.startDate, let end = event.endDate else { return nil }
            reminderStart = nil
            reminderDue = nil
            reminderAlerts = nil
            values.start = AssistantAgendaDate(date: start, dayOnly: event.isAllDay)
            values.end = AssistantAgendaDate(date: end, dayOnly: event.isAllDay)
            // An aligned occurrenceDate alone does not distinguish an ordinary
            // event from a series on every backend. Apply also resolves the
            // canonical item and checks its recurrence rules, identity and dates.
            let displaced = event.occurrenceDate.map { $0 != start } ?? false
            if event.isDetached || displaced || event.organizer != nil || event.birthdayContactIdentifier != nil || event.status == .canceled {
                restriction = "Recurring, detached, invited, birthday, or canceled events cannot be changed here."
            }
        }
        self.values = values
        self.restriction = restriction
    }
}

@MainActor final class AssistantAgenda {
    private var generation = UUID()

    func snapshot(range: DateInterval, includeReminders: Bool, includeEvents: Bool, allowedSourceIDs: Set<String>) async throws -> AssistantAgendaSnapshot {
        let id = UUID()
        generation = id
        let snapshot = try await Self.readSnapshot(range: range, reminders: includeReminders, events: includeEvents, allowed: allowedSourceIDs, generation: id)
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        return snapshot
    }

    func prepare(_ action: AssistantAction, in snapshot: AssistantAgendaSnapshot) throws -> AssistantPreparedChange {
        guard snapshot.generation == generation, snapshot.zone == .current else { throw Self.stale }
        let kind: AgendaEntity
        let creating: Bool
        let verb: String
        switch action.kind {
        case .createReminder: (kind, creating, verb) = (.reminder, true, "Create reminder")
        case .updateReminder: (kind, creating, verb) = (.reminder, false, "Update reminder")
        case .completeReminder: (kind, creating, verb) = (.reminder, false, "Complete reminder")
        case .createEvent: (kind, creating, verb) = (.event, true, "Create event")
        case .updateEvent: (kind, creating, verb) = (.event, false, "Update event")
        }
        let before: AgendaRecord?
        let sourceID: String
        if creating {
            guard action.targetID == nil, let destination = action.sourceID, action.title != nil else {
                throw AssistantAgendaError("Creating an item needs a destination and title, not an existing target.")
            }
            sourceID = destination
            before = nil
        } else {
            guard action.sourceID == nil, let id = action.targetID, let record = snapshot.records[id], record.kind == kind else {
                throw AssistantAgendaError("The proposal must target an item from this request and cannot move it to a different source.")
            }
            if let restriction = record.restriction { throw AssistantAgendaError(restriction) }
            sourceID = record.sourceID
            before = record
        }
        guard let source = snapshot.sources.first(where: { $0.id == sourceID && $0.kind == kind }), source.writable else {
            throw AssistantAgendaError("The destination is not a selected, writable \(kind.sourceName).")
        }
        var after = before?.values ?? AgendaValues(title: "", completed: kind == .reminder ? false : nil)
        if let title = action.title {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 1024 else {
                throw AssistantAgendaError("The title must be nonblank and no longer than 1024 UTF-8 bytes.")
            }
            after.title = title
        }
        switch action.kind {
        case .completeReminder:
            guard action.title == nil, action.due == nil, action.start == nil, action.end == nil else {
                throw AssistantAgendaError("Completing a reminder cannot also change its title or dates.")
            }
            after.completed = true
        case .createReminder, .updateReminder:
            guard action.start == nil, action.end == nil else { throw AssistantAgendaError("Reminders use a due date, not event start/end times.") }
            if let due = action.due {
                after.due = try AssistantAgendaDate.parse(due, in: snapshot.zone)
                if let before, before.values.due != after.due, before.reminderAlerts == nil {
                    throw AssistantAgendaError("The reminder's existing alarms cannot be verified. Change its due date in Apple Reminders.")
                }
                if let constraint = before?.reminderStart {
                    guard let start = AppleRemindersService.dueDate(from: constraint, calendar: AssistantAgendaDate.calendar(in: snapshot.zone)),
                          let deadline = after.due, deadline.date >= start.date else {
                        throw AssistantAgendaError("That due date conflicts with the reminder's existing start date.")
                    }
                }
            }
        case .createEvent, .updateEvent:
            guard action.due == nil else { throw AssistantAgendaError("Events use start and end times, not a reminder due date.") }
            if let start = action.start { after.start = try AssistantAgendaDate.parse(start, in: snapshot.zone) }
            if let end = action.end { after.end = try AssistantAgendaDate.parse(end, in: snapshot.zone) }
            guard let start = after.start, let end = after.end, start.dayOnly == end.dayOnly, start.date < end.date else {
                throw AssistantAgendaError("An event needs a start and a later, exclusive end, both all-day dates or both times.")
            }
        }
        guard after != before?.values else { throw AssistantAgendaError("The proposal would not change anything.") }
        var summary = "\(verb)\n\(kind.sourceName): \(quoted(source.title))"
        if !source.account.isEmpty { summary += " • \(quoted(source.account))" }
        if snapshot.sources.contains(where: { $0.id != source.id && $0.kind == kind && $0.title == source.title && $0.account == source.account }) {
            summary += "\nSource ID: \(quoted(source.id))"
        }
        if let before, let targetID = action.targetID, snapshot.records.contains(where: { id, row in
            id != targetID && row.kind == kind && row.sourceID == source.id && row.values == before.values
        }) { summary += "\nSnapshot item: \(quoted(targetID))" }
        summary += "\n\nBefore\n\(before?.values.description(in: snapshot.zone) ?? "No item")\n\nAfter\n\(after.description(in: snapshot.zone))"
        summary += "\n\nTime zone: \(snapshot.zone.identifier). "
        if creating, kind == .reminder, let due = after.due, !due.dayOnly {
            summary += "Add an absolute alarm at \(due.text(in: snapshot.zone)) (the due time)."
        } else if let before, let counts = before.reminderAlerts, before.values.due != after.due, let newDue = after.due {
            if counts.atDue > 0, let oldDue = before.values.due {
                let alarms = "\(counts.atDue) plain due-time alarm\(counts.atDue == 1 ? "" : "s")"
                summary += newDue.dayOnly ? "Remove \(alarms) at \(oldDue.text(in: snapshot.zone)) for the new date-only due date." : "Move \(alarms) from \(oldDue.text(in: snapshot.zone)) to \(newDue.text(in: snapshot.zone))."
            } else {
                summary += "No plain absolute alarm matches the previous timed due date; no alarm will be added or removed."
            }
            summary += " Other alarms are not edited; relative alerts follow their item's date."
        } else {
            summary += creating ? "No explicit alarm is added; system defaults may apply." : "Alarm settings are not edited. Relative alerts follow their item's date; absolute alerts keep their time."
        }
        var titles = quoted(Self.clipped(after.title))
        if let old = before?.values.title, old != after.title { titles = "\(quoted(Self.clipped(old))) → \(titles)" }
        var timing = after.compactTiming(in: snapshot.zone)
        if let old = before?.values, old.due != after.due || old.start != after.start || old.end != after.end {
            timing = "\(old.compactTiming(in: snapshot.zone)) → \(timing)"
        }
        if after.completed == true { timing += " · Open → Completed" }
        let headline = "\(verb) · \(titles)\n\(quoted(Self.clipped(source.title))) · \(timing)"
        return AssistantPreparedChange(headline: headline, summary: summary, snapshot: snapshot, source: source, before: before, after: after)
    }

    func apply(_ change: AssistantPreparedChange) async throws {
        try Task.checkCancellation()
        guard change.generation == generation, !change.consumed, change.zone == .current else { throw Self.stale }
        let source = change.source
        guard EKEventStore.authorizationStatus(for: source.kind.ekType) == .fullAccess else {
            throw AssistantAgendaError("Full access to \(source.kind.sourceName) is no longer available.")
        }
        // A fresh connection, not an EKObject retained while the user was
        // reviewing. From here through commit there is no suspension point.
        let store = EKEventStore()
        guard let calendar = store.calendar(withIdentifier: source.id),
              calendar.allowedEntityTypes.contains(source.kind == .reminder ? .reminder : .event),
              AgendaSource(calendar, kind: source.kind) == source, source.writable else { throw Self.stale }
        var existing: EKCalendarItem?
        if let before = change.before {
            guard let item = store.calendarItem(withIdentifier: before.id), item.calendar?.calendarIdentifier == source.id,
                  let now = AgendaRecord(item, kind: source.kind, viewingZone: change.zone), now.restriction == nil, now == before else { throw Self.stale }
            existing = item
        }
        let after = change.after
        let before = change.before?.values
        switch source.kind {
        case .reminder:
            let reminder: EKReminder
            if let existing {
                guard let typed = existing as? EKReminder else { throw Self.stale }
                reminder = typed
            } else {
                reminder = EKReminder(eventStore: store)
                reminder.calendar = calendar
            }
            if after.title != before?.title { reminder.title = after.title }
            if let due = after.due, due != before?.due {
                try Self.setDue(due, on: reminder, before: change.before, zone: change.zone)
            }
            if after.completed == true { reminder.isCompleted = true }
            try store.save(reminder, commit: true)
        case .event:
            guard let start = after.start, let end = after.end else { throw Self.stale }
            let event: EKEvent
            if let existing {
                guard let typed = existing as? EKEvent else { throw Self.stale }
                event = typed
            } else {
                event = EKEvent(eventStore: store)
                event.calendar = calendar
            }
            if after.title != before?.title { event.title = after.title }
            if start.dayOnly != before?.start?.dayOnly {
                event.isAllDay = start.dayOnly
                event.timeZone = start.dayOnly ? nil : change.zone
            }
            if start != before?.start { event.startDate = start.date }
            // Some backends shift the end when setting start. Always restore the
            // approved exclusive end on a date edit, never on title-only edits.
            if start != before?.start || end != before?.end { event.endDate = end.date }
            try store.save(event, span: .thisEvent, commit: true)
        }
        change.consumed = true
    }

    private static func setDue(_ due: AssistantAgendaDate, on reminder: EKReminder, before: AgendaRecord?, zone: TimeZone) throws {
        guard let before else {
            reminder.dueDateComponents = due.reminderComponents(in: zone)
            if !due.dayOnly { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
            return
        }
        let alarms = reminder.alarms ?? []
        let moving = alarms.filter { ReminderAlertCounts.matches($0, due: before.values.due) }
        guard let counts = before.reminderAlerts, counts.total == alarms.count, counts.atDue == moving.count else { throw stale }
        let untouched = alarms.filter { !ReminderAlertCounts.matches($0, due: before.values.due) }
            .map { (alarm: $0, absolute: $0.absoluteDate, relative: $0.relativeOffset) }
        // Remove only the plain matching alarms while moving the deadline. In
        // particular, do not reconstruct geofences, mail, sound or procedure alarms.
        for alarm in moving { reminder.removeAlarm(alarm) }
        reminder.dueDateComponents = due.reminderComponents(in: zone)
        let moved = due.dayOnly ? 0 : moving.count
        for _ in 0..<moved { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        let result = reminder.alarms ?? []
        let expectedAtDue = moved + untouched.count(where: { ReminderAlertCounts.matches($0.alarm, due: due) })
        guard result.count == untouched.count + moved,
              result.count(where: { ReminderAlertCounts.matches($0, due: due) }) == expectedAtDue,
              untouched.allSatisfy({ old in
                  result.contains { $0 === old.alarm && $0.absoluteDate == old.absolute && $0.relativeOffset == old.relative }
              }) else {
            throw AssistantAgendaError("EventKit could not preserve the reminder's other alarms. Nothing was saved; change the due date in Apple Reminders.")
        }
    }

    private static var stale: AssistantAgendaError {
        AssistantAgendaError("The item, destination, time zone, or proposal has changed. Request a fresh preview; nothing was saved.")
    }
}

// Only values cross the EventKit callback and async boundaries. Predicates are
// constructed with nonempty, selected calendars only (empty can mean “all”).
private extension AssistantAgenda {
    struct ContextSource: Encodable {
        let sourceID: String, name: String, account: String
        let kind: AgendaEntity, writable: Bool
    }
    struct ContextItem: Encodable {
        let targetID: String, sourceID: String, title: String
        let kind: AgendaEntity, editable: Bool
        let editRestriction: String?
        let due: String?, start: String?, end: String?, completed: Bool?
    }
    struct Context: Encodable {
        let rangeStart: String, rangeEndExclusive: String, timeZone: String
        var limitations: [String]
        var sources: [ContextSource] = []
        var items: [ContextItem] = []
    }

    nonisolated static func readSnapshot(range: DateInterval, reminders: Bool, events: Bool, allowed: Set<String>, generation: UUID) async throws -> AssistantAgendaSnapshot {
        guard range.duration > 0, range.duration <= 367 * 86400 else { throw AssistantAgendaError("Choose a positive agenda range of at most one year.") }
        try Task.checkCancellation()
        let zone = TimeZone.current
        var context = Context(rangeStart: AssistantAgendaDate(date: range.start, dayOnly: false).text(in: zone), rangeEndExclusive: AssistantAgendaDate(date: range.end, dayOnly: false).text(in: zone), timeZone: zone.identifier, limitations: [
            "Only selected sources are read. Events overlap the half-open range. Only open reminders due in the range and open reminders without a due date are included. Records without a usable identifier or representable dates cannot be shown. Notes, locations, alarms, attendees and completed history are not sent. Long titles and source names are shortened. IDs for items belong to this snapshot only."
        ])
        var sources: [AgendaSource] = []
        var records: [String: AgendaRecord] = [:]
        var checked: [AgendaEntity] = []
        var resolved = Set<String>()
        lazy var store = EKEventStore()
        for (kind, included) in [(AgendaEntity.reminder, reminders), (.event, events)] {
            guard included else { context.limitations.append("\(kind.sourceName) reading is switched off."); continue }
            guard EKEventStore.authorizationStatus(for: kind.ekType) == .fullAccess else {
                context.limitations.append("\(kind.sourceName) read access has not been granted. Its contents are unknown."); continue
            }
            guard !allowed.isEmpty else { context.limitations.append("No sources selected for \(kind.sourceName); nothing was read."); continue }
            let selected = store.calendars(for: kind.ekType).filter {
                !$0.calendarIdentifier.isEmpty && $0.calendarIdentifier.utf8.count <= 256 && allowed.contains($0.calendarIdentifier)
            }.sorted { $0.calendarIdentifier < $1.calendarIdentifier }
            resolved.formUnion(selected.map(\.calendarIdentifier))
            guard !selected.isEmpty else { context.limitations.append("No selected \(kind.sourceName) is available; none read."); continue }
            let calendars = Array(selected.prefix(24))
            if selected.count > calendars.count { context.limitations.append("Only the first 24 of \(selected.count) selected \(kind.sourceName) sources were read.") }
            checked.append(kind)
            let eligible = Set(calendars.map(\.calendarIdentifier))
            var writableIDs = Set<String>()
            for calendar in calendars {
                let source = AgendaSource(calendar, kind: kind)
                if source.writable { writableIDs.insert(source.id) }
                sources.append(source)
                context.sources.append(ContextSource(sourceID: source.id, name: clipped(source.title), account: clipped(source.account), kind: kind, writable: source.writable))
            }
            func add(_ rows: [AgendaRecord], limit: Int, label: String) {
                if rows.count > limit { context.limitations.append("Showing \(limit) of \(rows.count) \(label). Do not infer that omitted items are free time or absent.") }
                for row in rows.prefix(limit) {
                    let id = "\(kind == .event ? "E" : "R")-\(generation.uuidString.prefix(8))-\(context.items.count + 1)"
                    records[id] = row
                    let value = row.values
                    context.items.append(ContextItem(
                        targetID: id, sourceID: row.sourceID, title: clipped(value.title), kind: kind,
                        editable: row.restriction == nil && writableIDs.contains(row.sourceID), editRestriction: row.restriction,
                        due: value.due?.text(in: zone), start: value.start?.text(in: zone), end: value.end?.text(in: zone),
                        completed: value.completed
                    ))
                }
            }
            switch kind {
            case .reminder:
                let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
                let rows: [AgendaRecord] = try await withCheckedThrowingContinuation { continuation in
                    store.fetchReminders(matching: predicate) { items in
                        guard let items else { continuation.resume(throwing: AssistantAgendaError("EventKit could not read the selected reminder lists.")); return }
                        continuation.resume(returning: items.compactMap { reminder in
                            guard let sourceID = reminder.calendar?.calendarIdentifier, eligible.contains(sourceID), !reminder.isCompleted,
                                  let row = AgendaRecord(reminder, kind: .reminder, viewingZone: zone) else { return nil }
                            if let due = row.values.due, !(range.start..<range.end).contains(due.date) { return nil }
                            return row
                        })
                    }
                }
                let dated = rows.filter { $0.values.due != nil }.sorted {
                    let lhs = $0.values.due!.date, rhs = $1.values.due!.date
                    return lhs == rhs ? $0.id < $1.id : lhs < rhs
                }
                let undated = rows.filter { $0.values.due == nil }.sorted { $0.id < $1.id }
                add(dated, limit: 32, label: "open reminders due in range")
                add(undated, limit: 16, label: "undated open reminders")
            case .event:
                let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
                let rows = store.events(matching: predicate).compactMap { event -> AgendaRecord? in
                    guard let sourceID = event.calendar?.calendarIdentifier, eligible.contains(sourceID),
                          let start = event.startDate, let end = event.endDate, start < range.end,
                          (end > range.start || (start == end && start >= range.start)) else { return nil }
                    return AgendaRecord(event, kind: .event, viewingZone: zone)
                }.sorted {
                    let lhs = $0.values.start!.date, rhs = $1.values.start!.date
                    return lhs == rhs ? $0.id < $1.id : lhs < rhs
                }
                add(rows, limit: 48, label: "event occurrences")
            }
            try Task.checkCancellation()
        }
        // Never publish rows if access was revoked during the asynchronous fetch.
        guard checked.allSatisfy({ EKEventStore.authorizationStatus(for: $0.ekType) == .fullAccess }) else {
            throw AssistantAgendaError("Agenda access changed while reading. Request a new snapshot.")
        }
        if resolved.count < allowed.count { context.limitations.append("\(allowed.count - resolved.count) selected source IDs were unavailable or excluded from this read.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(context), as: UTF8.self)
        return AssistantAgendaSnapshot(modelContext: text, generation: generation, zone: zone, sources: sources, records: records)
    }

    nonisolated static func clipped(_ value: String) -> String {
        guard value.utf8.count > 192 else { return value }
        return String(decoding: value.utf8.prefix(192), as: UTF8.self) + "…"
    }
}

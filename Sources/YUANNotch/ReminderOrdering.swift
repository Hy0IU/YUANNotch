import Foundation

// MARK: - Panel model

/// How a row's write is doing.
///
/// There is deliberately no `synced` case: the app cannot read iCloud state,
/// and an EventKit write succeeds even when the Mac is offline. Anything
/// claiming sync would be a lie (see the plan's B2).
enum ReminderSyncState: Equatable {
    case idle
    case writing
    case failed(String)
}

/// A reminder as the panel renders it: either a live row from EventKit, or a
/// local placeholder for a create that has not reached the store yet.
struct ReminderPanelItem: Identifiable, Equatable {
    enum Origin: Equatable {
        case remote(id: String)
        case pendingLocal(id: UUID)
    }

    let id: String
    let origin: Origin
    let title: String
    let dueDate: Date?
    /// True for a day-level due date (see `ReminderDue`): grouping must not
    /// read a time of day out of `dueDate`.
    let isDueDateAllDay: Bool
    /// When the reminder was added — EventKit's `creationDate` for a row that
    /// exists on the system, and the moment the user pressed return for a
    /// placeholder that has not landed yet. Optional because EventKit declares
    /// `creationDate` nullable; a nil sorts last rather than first, so a row
    /// whose age is unknown cannot claim to be the newest.
    let createdDate: Date?
    let syncState: ReminderSyncState

    /// A placeholder has no system-side existence, so completing it is
    /// meaningless — these rows have their checkbox disabled.
    var isCompletable: Bool { remoteID != nil }

    /// Editing rewrites the reminder on the system, so it needs a row that is
    /// there. The same fact `isCompletable` rests on, asked a different
    /// question: they travel together today but need not stay married, and each
    /// name says which behaviour it gates.
    var isEditable: Bool { remoteID != nil }

    var remoteID: String? {
        if case .remote(let id) = origin { return id }
        return nil
    }

    var localID: UUID? {
        if case .pendingLocal(let id) = origin { return id }
        return nil
    }
}

enum ReminderGroup: String, CaseIterable, Identifiable {
    case overdue
    case today
    case tomorrow
    case later
    case undated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .later: return "Later"
        case .undated: return "No date"
        }
    }

    static func group(
        for dueDate: Date?,
        isAllDay: Bool = false,
        now: Date,
        calendar: Calendar
    ) -> ReminderGroup {
        guard let dueDate else { return .undated }

        // Overdue's boundary depends on the date's kind:
        // - A day-level due date is overdue only once its day has passed:
        //   "today, no time" stays in Today until midnight, the way
        //   Reminders.app reads it.
        // - Otherwise it is `dueDate < now`, not `< start of today`: a
        //   15-minute reminder created this morning is overdue by the
        //   afternoon, and leaving it under "Today" contradicts how
        //   Reminders.app reads it.
        let overdueBoundary = isAllDay ? calendar.startOfDay(for: now) : now
        if dueDate < overdueBoundary { return .overdue }

        // The remaining sections are day-interval tests against `now` itself —
        // deliberately not `isDateInToday`/`isDateInTomorrow`, which read the
        // real clock and would ignore the `now` parameter this function takes.
        // Reading every section off `now` keeps the function honest: callers
        // that pass a fixed `now` (tests, a future "as of" view) get answers
        // about that moment, not about whenever the call happened to run.
        let todayStart = calendar.startOfDay(for: now)
        if dueDate < calendar.date(byAdding: .day, value: 1, to: todayStart)! { return .today }
        if dueDate < calendar.date(byAdding: .day, value: 2, to: todayStart)! { return .tomorrow }
        return .later
    }
}

/// How the rows inside each group are ordered. The groups themselves stay in
/// their fixed calendar narrative — Overdue, Today, Tomorrow, Later, No date —
/// because that order is about time, not about the user's reading preference;
/// only the ordering *within* a group is a choice.
enum ReminderSortOrder: String, CaseIterable, Identifiable {
    /// Newest first. The default: the list is a working surface, and what the
    /// user just added is what they are most likely to look for. Ordering by
    /// due date would bury it under everything already scheduled.
    case added
    case dueDate
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .added: return "Recently Added"
        case .dueDate: return "By Due Date"
        case .title: return "By Title"
        }
    }

    var systemImage: String {
        switch self {
        case .added: return "clock"
        case .dueDate: return "calendar"
        case .title: return "textformat"
        }
    }

    /// The one place row ordering is decided. Every caller sorts through here,
    /// so a new order is an added case rather than a second sort somewhere.
    func comparator() -> (ReminderPanelItem, ReminderPanelItem) -> Bool {
        switch self {
        case .added: return Self.addedDatesBefore
        case .dueDate: return Self.dueDatesBefore
        case .title: return Self.titlesBefore
        }
    }

    private static func addedDatesBefore(_ lhs: ReminderPanelItem, _ rhs: ReminderPanelItem) -> Bool {
        switch (lhs.createdDate, rhs.createdDate) {
        case let (left?, right?):
            // **Descending**: the newest addition comes first, which is the
            // whole point of this order. Seconds only, for the same reason the
            // due-date order compares on that scale — the value arrives through
            // a components round-trip, so sub-second deltas are noise.
            let lhsSecond = Int(left.timeIntervalSince1970)
            let rhsSecond = Int(right.timeIntervalSince1970)
            if lhsSecond != rhsSecond { return lhsSecond > rhsSecond }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case (nil, nil):
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case (nil, _):
            return false
        case (_, nil):
            return true
        }
    }

    private static func dueDatesBefore(_ lhs: ReminderPanelItem, _ rhs: ReminderPanelItem) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?):
            // Reminder due dates carry second granularity only (measured), so
            // only compare on that scale — sub-second deltas are an artefact of
            // the components round-trip, not real ordering information.
            let lhsSecond = Int(left.timeIntervalSince1970)
            let rhsSecond = Int(right.timeIntervalSince1970)
            if lhsSecond != rhsSecond { return lhsSecond < rhsSecond }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case (nil, nil):
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case (nil, _):
            return false
        case (_, nil):
            return true
        }
    }

    private static func titlesBefore(_ lhs: ReminderPanelItem, _ rhs: ReminderPanelItem) -> Bool {
        let order = lhs.title.localizedStandardCompare(rhs.title)
        if order != .orderedSame { return order == .orderedAscending }
        // Identical titles still need a deterministic order, or rows swap
        // places between renders. Due order is the fallback: it is already
        // defined for every pair and matches the other menu's reading.
        return dueDatesBefore(lhs, rhs)
    }
}

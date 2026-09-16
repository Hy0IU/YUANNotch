import EventKit
import Foundation

/// Read/write access level for the user's reminders database.
///
/// `.writeOnly` is a defensive branch only: macOS exposes no
/// `requestWriteOnlyAccessToReminders`, so a reminder store cannot normally
/// reach that state. It is mapped anyway so an unexpected status never gets
/// treated as read access.
enum RemindersAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case writeOnly
    case fullAccess

    var canRead: Bool { self == .fullAccess }
}

/// A reminder list (`EKCalendar`) projected to the fields the UI needs.
struct ReminderList: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let isDefault: Bool
    /// `true` when the list lives only on this Mac (`EKSourceType.local`), so
    /// anything written into it never reaches the user's other devices. This
    /// is the only reliable criterion — the source *name* is display-only.
    let isLocalOnly: Bool
    /// Source name for display ("iCloud", "On My Mac", …). Never used for
    /// logic; see `isLocalOnly`.
    let sourceTitle: String
}

/// A reminder projected to value types.
///
/// `EKReminder` is not `Sendable`, so it must never escape a fetch callback.
/// This struct is the only shape that crosses an isolation boundary.
struct ReminderSnapshot: Identifiable, Equatable, Sendable {
    /// `calendarItemIdentifier` — the local, per-device handle (see C7).
    let id: String
    /// `calendarItemExternalIdentifier` — server-side identity. Can be `nil`,
    /// is not unique, and differs between devices for Exchange reminders, so
    /// it is only a fallback resolution hint, never a primary key.
    let externalID: String?
    let title: String
    let dueDate: Date?
    let isCompleted: Bool
    let hasAlarm: Bool
    let listID: String
    let lastModified: Date?
}

enum RemindersServiceError: LocalizedError, Equatable {
    case notAuthorized
    case listNotFound
    case reminderNotFound
    case fetchFailed
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Reminders access has not been granted"
        case .listNotFound:
            return "The selected reminders list no longer exists"
        case .reminderNotFound:
            return "The reminder no longer exists"
        case .fetchFailed:
            return "EventKit returned no result for the reminders query"
        case .operationFailed(let reason):
            return reason
        }
    }
}

/// The surface `ReminderStore` depends on.
///
/// Keeping this a protocol is what allows the store's merge, grouping and
/// retry-queue logic to be unit-tested without EventKit: the only member that
/// touches the system database is `AppleRemindersService`.
protocol RemindersServing: Sendable {
    func authorizationStatus() -> RemindersAuthorization
    func requestAccess() async throws -> RemindersAuthorization
    func availableLists() async -> [ReminderList]
    func defaultList() async -> ReminderList?
    func snapshot(in listID: String) async throws -> [ReminderSnapshot]
    func create(title: String, dueDate: Date, in listID: String, marker: UUID) async throws -> ReminderSnapshot
    func update(id: String, title: String?, dueDate: Date?) async throws
    func setCompleted(id: String, isCompleted: Bool) async throws
    func resolve(id: String, externalID: String?, in listID: String) async -> ReminderSnapshot?
    func delete(id: String) async throws
    /// Debounced change signal. The stream lives as long as the service.
    func changes() async -> AsyncStream<Void>

    /// Stable marker written onto reminders this app creates. It closes the
    /// narrow window where `save` succeeded but the identifier was not yet
    /// recorded, which would otherwise let a retry create a duplicate.
    static func markerURL(for marker: UUID) -> URL?
}

extension RemindersServing {
    static func markerURL(for marker: UUID) -> URL? {
        URL(string: "yuannotch://reminder/\(marker.uuidString)")
    }
}

/// The only type in the project that imports EventKit.
///
/// An `actor` rather than a class because `EKEventStore` is not `Sendable`
/// and the package builds in Swift 6 language mode, where strict concurrency
/// violations are hard errors. The store is actor-isolated state and never
/// crosses an isolation boundary.
actor AppleRemindersService: RemindersServing {
    private let store = EKEventStore()

    private var changeObserver: NSObjectProtocol?
    private var changeDebounceTask: Task<Void, Never>?
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// `EKEventStoreChanged` fires for any calendar or reminder change and can
    /// arrive in bursts while iCloud lands a batch, so emissions are merged.
    private static let changeDebounceInterval = Duration.milliseconds(500)

    // MARK: - Authorization

    nonisolated func authorizationStatus() -> RemindersAuthorization {
        Self.authorization(from: EKEventStore.authorizationStatus(for: .reminder))
    }

    func requestAccess() async throws -> RemindersAuthorization {
        _ = try await store.requestFullAccessToReminders()

        // C1: once the store has been touched before access was granted it
        // keeps serving an empty database until `reset()`. Resetting here is
        // always safe because no EKCalendar or EKReminder reference is cached
        // between calls — every lookup re-resolves from an identifier.
        store.reset()

        return Self.authorization(from: EKEventStore.authorizationStatus(for: .reminder))
    }

    private nonisolated static func authorization(from status: EKAuthorizationStatus) -> RemindersAuthorization {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .writeOnly:
            return .writeOnly
        case .fullAccess:
            return .fullAccess
        @unknown default:
            return .denied
        }
    }

    // MARK: - Lists

    func availableLists() async -> [ReminderList] {
        guard authorizationStatus().canRead else { return [] }

        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier

        return store.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .map { calendar in
                ReminderList(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    isDefault: calendar.calendarIdentifier == defaultID,
                    isLocalOnly: calendar.source?.sourceType == .local,
                    sourceTitle: calendar.source?.title ?? ""
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    func defaultList() async -> ReminderList? {
        await availableLists().first { $0.isDefault }
    }

    // MARK: - Reads

    func snapshot(in listID: String) async throws -> [ReminderSnapshot] {
        try requireReadAccess()
        guard let calendar = reminderCalendar(withID: listID) else {
            throw RemindersServiceError.listNotFound
        }

        // D5: completed reminders never render, so they are excluded at the
        // query rather than filtered afterwards — otherwise refresh cost grows
        // with the user's completed history.
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: [calendar]
        )

        return try await fetchSnapshots(matching: predicate)
    }

    func resolve(id: String, externalID: String?, in listID: String) async -> ReminderSnapshot? {
        // Local identifier first: it is an O(1) lookup and is the handle this
        // device wrote the reminder with.
        if let reminder = reminder(withIdentifier: id) {
            return ReminderSnapshot(reminder)
        }

        // Fallback: scan the list for the server-side identity. Restricted to
        // one list because duplicate copies of an item can exist in others.
        guard let externalID, let calendar = reminderCalendar(withID: listID) else { return nil }
        let predicate = store.predicateForReminders(in: [calendar])
        let candidates = (try? await fetchSnapshots(matching: predicate)) ?? []
        return candidates.first { $0.externalID == externalID }
    }

    // MARK: - Writes

    func create(
        title: String,
        dueDate: Date,
        in listID: String,
        marker: UUID
    ) async throws -> ReminderSnapshot {
        try requireReadAccess()
        guard let calendar = reminderCalendar(withID: listID) else {
            throw RemindersServiceError.listNotFound
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        applyDueDate(dueDate, to: reminder)
        reminder.url = Self.markerURL(for: marker)

        try save(reminder)
        return ReminderSnapshot(reminder) ?? {
            // The reminder was written; a projection failure must not be
            // reported as a failed write, or the retry would duplicate it.
            ReminderSnapshot(
                id: reminder.calendarItemIdentifier,
                externalID: reminder.calendarItemExternalIdentifier,
                title: title,
                dueDate: dueDate,
                isCompleted: false,
                hasAlarm: true,
                listID: listID,
                lastModified: Date()
            )
        }()
    }

    /// Mutations address a reminder by its **local** identifier only.
    ///
    /// Resolving a stale identifier is the caller's job (`resolve(id:externalID:in:)`),
    /// which is what keeps these paths from degenerating into a full-database
    /// scan whenever an identifier has gone stale.
    func update(id: String, title: String?, dueDate: Date?) async throws {
        try requireReadAccess()
        guard let reminder = reminder(withIdentifier: id) else {
            throw RemindersServiceError.reminderNotFound
        }

        if let title { reminder.title = title }
        if let dueDate { applyDueDate(dueDate, to: reminder) }

        try save(reminder)
    }

    func setCompleted(id: String, isCompleted: Bool) async throws {
        try requireReadAccess()
        guard let reminder = reminder(withIdentifier: id) else {
            throw RemindersServiceError.reminderNotFound
        }

        reminder.isCompleted = isCompleted
        // `completionDate` is what Reminders.app uses for ordering and for its
        // completed section, so it has to move together with the flag.
        reminder.completionDate = isCompleted ? Date() : nil

        try save(reminder)
    }

    func delete(id: String) async throws {
        try requireReadAccess()
        guard let reminder = reminder(withIdentifier: id) else {
            throw RemindersServiceError.reminderNotFound
        }

        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw RemindersServiceError.operationFailed(error.localizedDescription)
        }
    }

    // MARK: - Change notification

    func changes() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let token = UUID()
        changeContinuations[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeContinuation(token) }
        }
        startObservingChangesIfNeeded()
        return stream
    }

    private func removeChangeContinuation(_ token: UUID) {
        changeContinuations[token] = nil
    }

    private func startObservingChangesIfNeeded() {
        guard changeObserver == nil else { return }
        // `object: nil` rather than `object: store` on purpose. Filtering by the
        // store instance is the pattern Apple's samples use, but if EventKit
        // ever posts this notification with a different object the filter simply
        // never matches and refreshes stop happening with no error anywhere —
        // a silent failure mode. This process holds exactly one store, so
        // accepting every change notification costs nothing and cannot miss.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Fires on an arbitrary queue; hop onto the actor to debounce.
            Task { await self?.scheduleChangeEmission() }
        }
    }

    private func scheduleChangeEmission() {
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.changeDebounceInterval)
            } catch {
                return
            }
            // The task body is not actor-isolated (it captures `self` weakly),
            // so the emission has to hop back onto the actor.
            await self?.emitChange()
        }
    }

    private func emitChange() {
        for continuation in changeContinuations.values {
            continuation.yield()
        }
    }

    // MARK: - Helpers

    private func requireReadAccess() throws {
        guard authorizationStatus().canRead else {
            throw RemindersServiceError.notAuthorized
        }
    }

    /// Resolved on demand and never cached: `reset()` invalidates every
    /// previously vended `EKCalendar`, so holding one across calls would be a
    /// use-after-invalidation bug waiting to happen.
    private func reminderCalendar(withID listID: String) -> EKCalendar? {
        store.calendar(withIdentifier: listID)
    }

    private func reminder(withIdentifier id: String) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }

    private func save(_ reminder: EKReminder) throws {
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersServiceError.operationFailed(error.localizedDescription)
        }
    }

    private func fetchSnapshots(matching predicate: NSPredicate) async throws -> [ReminderSnapshot] {
        try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: RemindersServiceError.fetchFailed)
                    return
                }
                // Projection happens inside the callback: `EKReminder` is not
                // `Sendable` and must not cross the continuation boundary.
                continuation.resume(returning: reminders.compactMap(ReminderSnapshot.init))
            }
        }
    }

    /// C4 + C5: the due date must carry an explicit time zone, and an absolute
    /// alarm must be written on every path — relying on the list's default
    /// alarm means a rescheduled reminder silently stops firing.
    private func applyDueDate(_ dueDate: Date, to reminder: EKReminder) {
        var components = Calendar.current.dateComponents(in: .current, from: dueDate)
        components.timeZone = .current
        reminder.dueDateComponents = components
        reminder.alarms = [EKAlarm(absoluteDate: dueDate)]
    }
}

extension ReminderSnapshot {
    init?(_ reminder: EKReminder) {
        guard let listID = reminder.calendar?.calendarIdentifier else { return nil }

        self.init(
            id: reminder.calendarItemIdentifier,
            externalID: reminder.calendarItemExternalIdentifier,
            title: reminder.title ?? "",
            dueDate: Self.date(from: reminder.dueDateComponents),
            isCompleted: reminder.isCompleted,
            hasAlarm: !(reminder.alarms ?? []).isEmpty,
            listID: listID,
            lastModified: reminder.lastModifiedDate
        )
    }

    /// `EKReminder` carries `dueDateComponents`, not a `Date`. Components
    /// written by other clients may have no time zone, in which case they are
    /// interpreted in the current one — the same rule used when writing.
    static func date(from components: DateComponents?) -> Date? {
        guard let components else { return nil }
        var calendar = Calendar.current
        if let timeZone = components.timeZone {
            calendar.timeZone = timeZone
        }
        return calendar.date(from: components)
    }
}

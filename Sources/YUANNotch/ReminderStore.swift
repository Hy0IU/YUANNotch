import AppKit
import Combine
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
///
/// The placeholder is what keeps the failed-write state honest. With EventKit
/// as the source of truth, a reminder that failed to save does not exist on the
/// system side, so without a local stand-in the row would silently vanish.
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
    let syncState: ReminderSyncState

    /// A placeholder has no system-side existence, so completing it is
    /// meaningless — these rows have their checkbox disabled.
    var isCompletable: Bool { remoteID != nil }

    var remoteID: String? {
        if case .remote(let id) = origin { return id }
        return nil
    }

    var localID: UUID? {
        if case .pendingLocal(let id) = origin { return id }
        return nil
    }
}

/// A placeholder plus the list it was created for. S1: a failed create must
/// not follow the user to another list, so the list is part of the payload
/// rather than inferred at render time.
private struct PendingPlaceholder {
    var item: ReminderPanelItem
    let listID: String
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
}

// MARK: - Retry queue

/// One write that has not reached the local EventKit store yet.
///
/// Both identifiers are carried. They cannot be reduced to one: the external
/// identifier is server-provided, can be absent for a list that lives only on
/// this Mac, differs between devices for Exchange reminders, and is not unique.
enum PendingOperation: Codable, Equatable {
    case create(localID: UUID, title: String, due: ReminderDue?, listID: String)
    case update(reminderID: String, externalID: String?, listID: String, title: String?, due: ReminderDue?)
    case setCompleted(reminderID: String, externalID: String?, listID: String, isCompleted: Bool)
    case delete(reminderID: String, externalID: String?, listID: String)
}

/// Owns the reminders integration state shared by the settings page and the
/// drawer's reminders panel.
@MainActor
final class ReminderStore: ObservableObject {
    @Published private(set) var authorization: RemindersAuthorization = .notDetermined
    @Published private(set) var lists: [ReminderList] = []
    @Published private(set) var items: [ReminderPanelItem] = []
    /// Which list the rows on screen were read from; `nil` before the first
    /// read. Paired with `selectedList` by `content`, so the panel can tell
    /// "not read yet" and "still showing the previous list's rows" apart from
    /// "read, and it is empty" — a distinction `items.isEmpty` cannot make.
    @Published private(set) var displayedListID: String?
    /// True while the integration is doing work the panel should show.
    ///
    /// Held for a minimum period once raised (see `minimumBusyDuration`), which
    /// is why this is stored state rather than something the view computes from
    /// its sources.
    @Published private(set) var isBusy = false
    /// Operations that did not land and are still waiting in the retry queue.
    ///
    /// This is the failure count, and it is the opposite of `inFlightCount`.
    /// They used to share one number, so a create reported itself as "not
    /// written" for the milliseconds before it landed.
    @Published private(set) var failedWriteCount = 0
    @Published private(set) var lastError: String?
    /// What the undo bar describes: the most recent deferred write.
    @Published private(set) var pendingUndo: PendingUndo?

    private let settingsStore: AppSettingsStore
    private let service: RemindersServing
    private let queueStore: ReminderQueueStore

    /// What the store has read for `displayedListID`, unfiltered — the truth
    /// behind the panel. Suppression is applied once, when the rows are built.
    private var snapshot: [ReminderSnapshot] = []
    private var placeholders: [PendingPlaceholder] = []
    /// Rows hidden from the panel while their write waits out the undo window
    /// — a delete or a completion. This is the `− {待删除}` term of the panel's
    /// union: a refresh arriving inside the window must not resurrect the row.
    ///
    /// Display only. A hidden row stays in `snapshot` on purpose, so undo can
    /// put it back without a round trip; the filter lives in `rebuildItems`
    /// alone and is lifted together with the local copy (`releaseSuppression`).
    private var suppressedIDs: Set<String> = []
    private var queuedOperations: [PendingOperation] = []

    /// A source of `isBusy` with neither a row nor a snapshot behind it, so it
    /// is tracked on its own rather than inferred.
    private var isRequestingAccess = false
    /// Raised by a refresh the user just caused, and cleared when the pass it
    /// asked for ends. Reading the list is not itself a reason to show
    /// progress — the five-second tick reads it too.
    private var userRefreshPending = false
    /// When `isBusy` was last raised, for `minimumBusyDuration`.
    private var busyBeganAt: Date?
    private var busyReleaseTask: Task<Void, Never>?

    /// One row that has left the panel while its write waits out the undo window.
    private struct DeferredWrite {
        enum Operation {
            case delete
            case complete
        }
        let remoteID: String
        let externalID: String?
        let listID: String
        let title: String
        let operation: Operation
    }

    /// What the undo bar describes: the most recent deferred write.
    struct PendingUndo: Equatable {
        enum Verb: Equatable {
            case deleted
            case completed
        }
        let title: String
        let verb: Verb
    }

    private var deferredWrites: [DeferredWrite] = []
    /// Keyed by `remoteID`: each row's window runs on its own task, so taking
    /// back one write never touches another's clock.
    private var deferredWriteTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Activity indication

    /// How long `isBusy` stays raised once it has been.
    ///
    /// A create lands in tens of milliseconds, so without a floor the spinner
    /// would blink — which reads as a glitch, not as progress. The floor is
    /// also what makes a single turn of the glyph enough: it guarantees the
    /// turn can be seen.
    private static let minimumBusyDuration: TimeInterval = 0.4

    /// Decides whether the integration is busy, from all of its sources.
    ///
    /// One place decides, so the panel never has to combine an in-flight write,
    /// a user-caused refresh and an access request on its own — and so the
    /// minimum duration applies to the union rather than to each source
    /// separately.
    private func updateBusyState() {
        let wantsBusy = userRefreshPending
            || inFlightCount > 0
            || isRequestingAccess

        if wantsBusy {
            busyReleaseTask?.cancel()
            busyReleaseTask = nil
            if !isBusy {
                isBusy = true
                busyBeganAt = Date()
            }
            return
        }

        guard isBusy else { return }

        busyReleaseTask?.cancel()
        busyReleaseTask = nil

        let held = Date().timeIntervalSince(busyBeganAt ?? .distantPast)
        let remaining = Self.minimumBusyDuration - held

        guard remaining > 0 else {
            isBusy = false
            busyBeganAt = nil
            return
        }

        busyReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.isBusy = false
            self?.busyBeganAt = nil
        }
    }

    // MARK: - Refresh pipeline

    // Every trigger that can make the panel stale funnels through
    // `requestRefresh`: the panel appearing, a store-change notification, the
    // visible-lifetime tick, a list switch, and the completion of a write.
    // There is deliberately no per-trigger "drain, then read" sequence — adding
    // a sixth trigger means calling `requestRefresh`, not writing a sixth
    // sequence beside the existing five.
    private var refreshLoopTask: Task<Void, Never>?
    private var needsRefresh = false
    private var needsListReload = false

    private var isPanelVisible = false
    private var panelVisibilityTask: Task<Void, Never>?
    private var changeObservationTask: Task<Void, Never>?

    /// How often the list is re-read while the panel is on screen.
    ///
    /// `.EKEventStoreChanged` is not a dependable clock. Measured on this
    /// machine (probe, 2026-09-16): one notification arrived **5.29 s** after a
    /// same-process write, and a burst of four writes produced **no**
    /// notification at all within 10 s. The notification is the fast path when
    /// it fires; this tick is what actually bounds staleness.
    private static let visiblePollInterval = Duration.seconds(5)

    /// How long a delete or a completion can be taken back. Deferred commit
    /// rather than delete-then-recreate: recreating would hand out a new
    /// `calendarItemIdentifier`, flash the row on the user's phone, and discard
    /// any concurrent edit made on another device. A process that exits inside
    /// the window drops the write entirely, so the row comes back — the safer
    /// failure direction for both operations.
    private static let undoWindow = Duration.seconds(5)

    init(
        settingsStore: AppSettingsStore,
        service: RemindersServing = AppleRemindersService(),
        queueStore: ReminderQueueStore = ReminderQueueStore()
    ) {
        self.settingsStore = settingsStore
        self.service = service
        self.queueStore = queueStore
        authorization = service.authorizationStatus()
        queuedOperations = queueStore.load()
        failedWriteCount = queuedOperations.count
    }

    // MARK: - Derived state

    var isEnabled: Bool { settingsStore.isAppleRemindersSyncEnabled }

    var selectedList: ReminderList? {
        guard let stored = settingsStore.remindersCalendarIdentifier else { return lists.first }
        return lists.first { $0.id == stored } ?? lists.first
    }

    var selectedListIsLocalOnly: Bool { selectedList?.isLocalOnly ?? false }

    /// What the panel's content area should show.
    ///
    /// One decision, made here: the view switches on this instead of combining
    /// emptiness, the list the rows came from and a loading flag of its own.
    enum ListContent: Equatable {
        /// Nothing read for this list yet, and no earlier list to fall back on.
        case loading
        /// Rows are on screen, but they belong to another list: a switch is in
        /// flight. They are shown dimmed and inert.
        case stale
        /// Read, and there is nothing in it. The only honest way to say this —
        /// which is why it is its own case rather than "no rows".
        case empty
        case rows
    }

    var content: ListContent {
        Self.listContent(
            displayedListID: displayedListID,
            selectedListID: selectedList?.id,
            isEmpty: items.isEmpty
        )
    }

    /// The rule behind `content`, with its inputs spelled out.
    ///
    /// Pure on purpose: this is the decision that dictates whether the panel
    /// says "nothing here", says nothing yet, or shows another list's rows, and
    /// the project has no test target to pin it down — so it takes what it
    /// needs instead of reaching for it.
    static func listContent(
        displayedListID: String?,
        selectedListID: String?,
        isEmpty: Bool
    ) -> ListContent {
        // Nothing selected: nothing can be asserted about any list.
        guard let selectedListID else { return .loading }

        if displayedListID == selectedListID {
            // Read, and the answer is known: empty is only ever said here.
            return isEmpty ? .empty : .rows
        }

        // No read has ever landed, so the rows can only be placeholders for
        // this very list — the one case where rows without a read behind them
        // are current rather than stale.
        if displayedListID == nil { return isEmpty ? .loading : .rows }

        // A committed read of a different list: a switch is in flight.
        return isEmpty ? .loading : .stale
    }

    /// Rows whose write has not landed yet — work in progress, not failure.
    var inFlightCount: Int {
        items.filter { $0.syncState == .writing }.count
    }

    /// Items grouped for display; empty groups are dropped.
    func groupedItems(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(group: ReminderGroup, items: [ReminderPanelItem])] {
        let bucketed = Dictionary(grouping: items) { item in
            Self.group(
                for: item.dueDate,
                isAllDay: item.isDueDateAllDay,
                now: now,
                calendar: calendar
            )
        }

        return ReminderGroup.allCases.compactMap { group in
            guard let bucket = bucketed[group], !bucket.isEmpty else { return nil }
            return (group, bucket.sorted(by: Self.ordersBefore))
        }
    }

    static func group(
        for dueDate: Date?,
        isAllDay: Bool = false,
        now: Date,
        calendar: Calendar
    ) -> ReminderGroup {
        guard let dueDate else { return .undated }
        if isAllDay {
            // A day-level due date is overdue only once its day has passed:
            // "today, no time" stays in Today until midnight, the way
            // Reminders.app reads it.
            if dueDate < calendar.startOfDay(for: now) { return .overdue }
            if calendar.isDateInToday(dueDate) { return .today }
            if calendar.isDateInTomorrow(dueDate) { return .tomorrow }
            return .later
        }
        // Overdue is `dueDate < now`, not `< start of today`: a 15-minute
        // reminder created this morning is overdue by the afternoon, and
        // leaving it under "Today" contradicts how Reminders.app reads it.
        if dueDate < now { return .overdue }
        if calendar.isDateInToday(dueDate) { return .today }
        if calendar.isDateInTomorrow(dueDate) { return .tomorrow }
        return .later
    }

    private static func ordersBefore(_ lhs: ReminderPanelItem, _ rhs: ReminderPanelItem) -> Bool {
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

    // MARK: - Lifecycle

    /// Marks the panel stale and makes sure a refresh pass is running.
    ///
    /// Requests that arrive while a pass is in flight collapse into a single
    /// follow-up pass, which is what keeps a burst of notifications from
    /// flickering the list. Callers never sequence the refresh themselves.
    ///
    /// `showingProgress` is opt-in and belongs only to triggers the user just
    /// caused — opening the panel, pressing reload, switching list. The
    /// background ones (the visible tick, a store-change notification) must not
    /// claim the glyph: they fire on their own schedule, so it would turn every
    /// five seconds regardless of anything the user did, which is exactly the
    /// loss of meaning that made the text it replaced useless.
    func requestRefresh(reloadLists: Bool = false, showingProgress: Bool = false) {
        if showingProgress {
            userRefreshPending = true
            updateBusyState()
        }

        needsRefresh = true
        needsListReload = needsListReload || reloadLists

        guard refreshLoopTask == nil else { return }
        refreshLoopTask = Task { [weak self] in
            await self?.runRefreshLoop()
        }
    }

    private func runRefreshLoop() async {
        defer { refreshLoopTask = nil }

        while needsRefresh {
            let reloadLists = needsListReload
            needsRefresh = false
            needsListReload = false
            await performRefresh(reloadLists: reloadLists)
        }
    }

    private func performRefresh(reloadLists: Bool) async {
        // Compared before assigning: `@Published` publishes on every write, and
        // the visible tick runs this pass every five seconds, so an unchanged
        // value would cost a full panel rebuild each time for nothing.
        let status = service.authorizationStatus()
        if status != authorization {
            authorization = status
        }

        // Whatever the user asked for is answered by this pass, so the
        // user-caused part of the busy state ends with it — including on the
        // early return below, or the glyph would keep turning with nothing
        // behind it.
        defer {
            userRefreshPending = false
            updateBusyState()
        }

        // The same condition that decides whether there is anything to read also
        // decides whether the background tasks should exist. Driving both from
        // one place is what keeps "off" from leaving work behind.
        updateBackgroundWork()

        guard isEnabled, authorization.canRead else {
            lists = []
            commit(snapshot: [], for: nil)
            return
        }

        if reloadLists || lists.isEmpty {
            let refreshed = await service.availableLists()
            if refreshed != lists {
                lists = refreshed
            }
            reconcileSelectedList()
        }

        // Queue before read (plan §8.5): an operation still waiting to be
        // written must not be mistaken for a reminder that was deleted
        // elsewhere.
        await drainQueue()
        await reloadSnapshot()
    }

    /// Reports the panel's visible lifetime.
    ///
    /// The view says whether it is on screen; the store owns the schedule, the
    /// interval, the trigger set **and the lifetime of the tasks behind them**.
    /// Nothing about refresh policy lives in the view layer.
    func setPanelVisible(_ isVisible: Bool) {
        guard isVisible != isPanelVisible else { return }
        isPanelVisible = isVisible

        if isVisible {
            // Opening the panel is a user action, so the read it triggers is
            // acknowledged. The tick that follows is not.
            requestRefresh(reloadLists: lists.isEmpty, showingProgress: true)
        }
        updateBackgroundWork()
    }

    // MARK: - Background work

    /// The only place that starts or stops the integration's background work.
    ///
    /// Two long-lived tasks exist — the store-change subscription and the
    /// visible-lifetime tick — and each must exist exactly while it has a
    /// reason to: the subscription while the integration is live, the tick
    /// while it is live *and* the panel is on screen.
    ///
    /// Previously these were started from two different places and neither was
    /// stopped on disable, so turning the integration off left the subscription
    /// registered and kept the tick running for as long as the panel stayed
    /// open. Owning both here makes "off" symmetric with "on".
    private func updateBackgroundWork() {
        guard isEnabled, authorization.canRead else {
            changeObservationTask?.cancel()
            changeObservationTask = nil
            stopVisibleTick()
            return
        }

        startObservingChangesIfNeeded()

        if isPanelVisible {
            startVisibleTickIfNeeded()
        } else {
            stopVisibleTick()
        }
    }

    /// Subscribes to the store's change stream while the integration is live.
    ///
    /// The service is what debounces — it emits at most once per 500 ms window —
    /// so a burst (iCloud landing a batch, or our own write echoing back)
    /// collapses before it reaches this side, and the pipeline collapses again
    /// on top of that.
    ///
    /// Cancelling the consuming task ends the stream's iteration, which fires
    /// the service's `onTermination` and drops its continuation; a later enable
    /// therefore subscribes with a fresh stream rather than piling one up.
    private func startObservingChangesIfNeeded() {
        guard changeObservationTask == nil else { return }

        // Captured outside the task so the closure never reaches back into
        // main-actor state to obtain it; `RemindersServing` is Sendable.
        let service = self.service

        changeObservationTask = Task { @MainActor [weak self] in
            let stream = await service.changes()
            for await _ in stream {
                guard !Task.isCancelled else { return }
                self?.requestRefresh()
            }
        }
    }

    /// Re-reads the list on a timer while the panel is on screen.
    ///
    /// `.EKEventStoreChanged` is not a dependable clock: measured 5.29 s for a
    /// same-process write, and a burst of four writes produced no notification
    /// at all within 10 s. The notification is the fast path when it fires; this
    /// tick is what actually bounds staleness.
    private func startVisibleTickIfNeeded() {
        guard panelVisibilityTask == nil else { return }

        panelVisibilityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.visiblePollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.requestRefresh()
            }
        }
    }

    private func stopVisibleTick() {
        panelVisibilityTask?.cancel()
        panelVisibilityTask = nil
    }

    func setEnabled(_ enabled: Bool) async {
        settingsStore.isAppleRemindersSyncEnabled = enabled

        guard enabled else {
            lists = []
            placeholders = []
            commit(snapshot: [], for: nil)
            lastError = nil
            // Disabling does not go through the refresh pipeline, so the
            // background work is stopped explicitly here.
            updateBackgroundWork()
            return
        }

        if authorization == .notDetermined {
            await requestAccess()
        } else {
            // Enabling is a user action; its first read is acknowledged.
            requestRefresh(reloadLists: true, showingProgress: true)
        }
    }

    func select(listID: String?) {
        guard settingsStore.remindersCalendarIdentifier != listID else { return }
        settingsStore.remindersCalendarIdentifier = listID
        // Placeholders belong to the list they were created for, so they are
        // filtered per list rather than cleared here — and the snapshot is not
        // cleared either. The rows on screen stay put until the read for the
        // new list lands, which is what keeps a switch from passing through a
        // blank panel; `content` reports them as stale and the view dims them.
        //
        // The selection lives in the settings store, which this store does not
        // observe, so the change is announced here. Clearing the snapshot used
        // to do that by accident — the picker label and `content` both read the
        // selection, and neither would notice on its own.
        objectWillChange.send()
        // Switching list is a user action, so the read is acknowledged.
        requestRefresh(showingProgress: true)
    }

    // MARK: - Writes

    func create(title: String, due: ReminderDue?) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let list = selectedList else { return }

        let localID = UUID()
        placeholders.append(
            PendingPlaceholder(
                item: ReminderPanelItem(
                    id: localID.uuidString,
                    origin: .pendingLocal(id: localID),
                    title: trimmed,
                    dueDate: due?.date,
                    isDueDateAllDay: due?.isAllDay ?? false,
                    syncState: .writing
                ),
                listID: list.id
            )
        )
        rebuildItems()

        do {
            _ = try await service.create(
                title: trimmed,
                due: due,
                in: list.id,
                marker: localID
            )
            placeholders.removeAll { $0.item.localID == localID }
            requestRefresh()
        } catch {
            // Keep the row visible and honest: it is not in the store, so it
            // must not look like it is.
            updatePlaceholder(localID, syncState: .failed(error.localizedDescription))
            enqueue(.create(localID: localID, title: trimmed, due: due, listID: list.id))
        }
    }

    /// Marks a reminder complete. The write is deferred past the undo window
    /// through the same mechanism a delete goes through: the row leaves the
    /// panel at once, stays take-back-able for `undoWindow`, and only then
    /// reaches the store.
    func complete(_ item: ReminderPanelItem) {
        // The suppression guard covers the race where the row is deleted while
        // its completion animation is still playing.
        guard let remoteID = item.remoteID, !suppressedIDs.contains(remoteID) else { return }
        suppressAndDefer(deferredWrite(remoteID: remoteID, title: item.title, operation: .complete))
    }

    /// Starts the undo window. Nothing reaches the store until it expires, so
    /// the row is genuinely safe to take back.
    func delete(_ item: ReminderPanelItem) {
        if let localID = item.localID {
            // A placeholder has no store-side existence: drop it and its queued
            // create outright.
            placeholders.removeAll { $0.item.localID == localID }
            setQueue(queuedOperations.filter { operation in
                guard case .create(let id, _, _, _) = operation else { return true }
                return id != localID
            })
            rebuildItems()
            return
        }

        guard let remoteID = item.remoteID else { return }
        suppressAndDefer(deferredWrite(remoteID: remoteID, title: item.title, operation: .delete))
    }

    /// The store-side identity of one deferred write, read from the row it
    /// refers to rather than from the current selection.
    ///
    /// The two can disagree for a moment while a list switch is in flight, and
    /// a queued write has to follow its own row: `ReminderSnapshot` carries the
    /// list it was read from, so nothing here has to assume.
    private func deferredWrite(
        remoteID: String,
        title: String,
        operation: DeferredWrite.Operation
    ) -> DeferredWrite {
        let entry = snapshot.first { $0.id == remoteID }
        return DeferredWrite(
            remoteID: remoteID,
            externalID: entry?.externalID,
            listID: entry?.listID ?? selectedList?.id ?? "",
            title: title,
            operation: operation
        )
    }

    /// The one sequence behind both a delete and a completion: the row leaves
    /// the panel immediately, the store write waits out the undo window, and
    /// undo brings the row back with nothing having happened.
    ///
    /// The row deliberately stays in `snapshot` — suppression is a display
    /// concern and hides it in `rebuildItems` alone. Dropping the local copy
    /// here would leave undo with nothing to restore, so the row could only
    /// come back on the next round trip to the store (measured: the visible
    /// tick, up to five seconds).
    private func suppressAndDefer(_ write: DeferredWrite) {
        suppressedIDs.insert(write.remoteID)

        // Defensive: an older entry for the same row must not survive being
        // superseded by a newer write — its window task would commit stale work.
        if deferredWrites.contains(where: { $0.remoteID == write.remoteID }) {
            deferredWriteTasks[write.remoteID]?.cancel()
            deferredWriteTasks[write.remoteID] = nil
            deferredWrites.removeAll { $0.remoteID == write.remoteID }
        }

        deferredWrites.append(write)
        updatePendingUndo()
        rebuildItems()
        startUndoWindow(for: write)
    }

    private func updatePendingUndo() {
        guard let write = deferredWrites.last else {
            pendingUndo = nil
            return
        }
        pendingUndo = PendingUndo(
            title: write.title,
            verb: write.operation == .delete ? .deleted : .completed
        )
    }

    private func startUndoWindow(for write: DeferredWrite) {
        deferredWriteTasks[write.remoteID]?.cancel()
        deferredWriteTasks[write.remoteID] = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.undoWindow)
            } catch {
                return
            }
            await self?.commitDeferredWrite(for: write.remoteID)
        }
    }

    /// Takes back the most recent deferred write. Suppression is lifted but the
    /// local copy is deliberately kept — that copy is what lets the row return
    /// at once, with no round trip to the store.
    func undoLatestPendingWrite() {
        guard let write = deferredWrites.last else { return }
        deferredWriteTasks[write.remoteID]?.cancel()
        deferredWriteTasks[write.remoteID] = nil
        deferredWrites.removeLast()
        updatePendingUndo()
        suppressedIDs.remove(write.remoteID)
        rebuildItems()
    }

    /// The counterpart of `suppressAndDefer` for a write that has landed (or
    /// whose reminder is gone): the row stops being hidden *and* leaves the
    /// local snapshot.
    ///
    /// Both halves go together. A snapshot that keeps a suppressed row is what
    /// makes undo instant, so once the row is no longer suppressed any stale
    /// copy has to go — otherwise a `rebuildItems` in the same queue drain
    /// would flash a deleted row back on screen before the refresh catches up.
    private func releaseSuppression(_ remoteID: String) {
        suppressedIDs.remove(remoteID)
        snapshot.removeAll { $0.id == remoteID }
    }

    /// Runs when a row's undo window expires. A process that exits inside the
    /// window cancels the write instead — the reminder survives unchanged,
    /// which is the safer failure direction.
    private func commitDeferredWrite(for remoteID: String) async {
        // The write may have been undone in the meantime.
        guard let write = deferredWrites.first(where: { $0.remoteID == remoteID }) else { return }
        deferredWrites.removeAll { $0.remoteID == remoteID }
        deferredWriteTasks[remoteID] = nil
        updatePendingUndo()

        do {
            switch write.operation {
            case .delete:
                try await service.delete(id: write.remoteID)
            case .complete:
                try await service.setCompleted(id: write.remoteID, isCompleted: true)
            }
            releaseSuppression(write.remoteID)
            requestRefresh()
        } catch {
            lastError = error.localizedDescription
            switch write.operation {
            case .delete:
                enqueue(.delete(
                    reminderID: write.remoteID,
                    externalID: write.externalID,
                    listID: write.listID
                ))
            case .complete:
                enqueue(.setCompleted(
                    reminderID: write.remoteID,
                    externalID: write.externalID,
                    listID: write.listID,
                    isCompleted: true
                ))
            }
            // Stay suppressed: the user asked for it and the queue still owes
            // the store the write. The failed operation shows up as an
            // unwritten count, so a refresh is requested rather than assumed.
            requestRefresh()
        }
    }

    // MARK: - Authorization

    /// Requests access, foregrounding the app first.
    ///
    /// The app runs as an accessory with `.nonactivatingPanel` windows, and the
    /// TCC dialog needs a frontmost app: requested from a non-activated
    /// context, the prompt commonly never appears and the status silently stays
    /// `.notDetermined`. Both the settings window and the panel go through
    /// here rather than calling the service directly.
    func requestAccess() async {
        isRequestingAccess = true
        updateBusyState()
        defer {
            isRequestingAccess = false
            updateBusyState()
        }

        let didForeground = foregroundIfNeeded()
        defer { restoreAccessoryIfNeeded(didForeground) }

        do {
            authorization = try await service.requestAccess()
        } catch {
            lastError = error.localizedDescription
            authorization = service.authorizationStatus()
        }

        guard authorization.canRead else { return }
        // The access request has ended by now, so the first read after it is
        // what keeps the glyph turning across the handover.
        requestRefresh(reloadLists: true, showingProgress: true)
    }

    func openPrivacySettings() {
        // The Reminders anchor is not documented; if it is rejected, System
        // Settings still opens on Privacy & Security.
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openRemindersApp() {
        guard let url = URL(string: "x-apple-reminderkit://") else { return }
        NSWorkspace.shared.open(url)
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Snapshot

    private func reloadSnapshot() async {
        guard isEnabled, authorization.canRead, let listID = selectedList?.id else {
            commit(snapshot: [], for: nil)
            return
        }

        do {
            let fetched = try await service.snapshot(in: listID)
            // A read that lands after the user moved on belongs to a list that
            // is no longer selected. Committing it would put one list's rows
            // under another list's title for as long as the follow-up pass
            // takes — and the switch already queued that pass, so the result is
            // dropped instead of shown.
            guard listID == selectedList?.id else { return }
            // The store's truth, unfiltered. Suppression is display-only and is
            // applied once, in `rebuildItems`: filtering here would throw away
            // the copy a pending undo needs, so a refresh landing inside the
            // window would make undo wait for the next round trip.
            commit(snapshot: fetched, for: listID)
        } catch {
            lastError = error.localizedDescription
            rebuildItems()
        }
    }

    /// The only place the panel's rows are swapped in: the snapshot, the list
    /// it was read from and the rebuilt rows move together, so `content` never
    /// observes a half-applied state.
    private func commit(snapshot newSnapshot: [ReminderSnapshot], for listID: String?) {
        snapshot = newSnapshot
        displayedListID = listID
        rebuildItems()
    }

    /// `EventKit(selected list, incomplete) ∪ {placeholders for this list} − {suppressed}`
    private func rebuildItems() {
        let currentListID = selectedList?.id

        // The single place suppression is applied. It has to be here rather
        // than at fetch time: a row enters the undo window long after the
        // fetch, and a stale snapshot entry would otherwise put it straight
        // back on screen.
        let remote = snapshot
            .filter { !suppressedIDs.contains($0.id) }
            .map { entry in
                ReminderPanelItem(
                    id: entry.id,
                    origin: .remote(id: entry.id),
                    title: entry.title,
                    dueDate: entry.dueDate,
                    isDueDateAllDay: entry.isDueDateAllDay,
                    syncState: .idle
                )
            }

        let visiblePlaceholders = placeholders
            .filter { $0.listID == currentListID }
            .map(\.item)

        items = remote + visiblePlaceholders
        // `inFlightCount` reads `items`, so this is where a write starting or
        // landing changes the answer.
        updateBusyState()
    }

    private func updatePlaceholder(_ localID: UUID, syncState: ReminderSyncState) {
        guard let index = placeholders.firstIndex(where: { $0.item.localID == localID }) else { return }
        placeholders[index].item = ReminderPanelItem(
            id: placeholders[index].item.id,
            origin: placeholders[index].item.origin,
            title: placeholders[index].item.title,
            dueDate: placeholders[index].item.dueDate,
            isDueDateAllDay: placeholders[index].item.isDueDateAllDay,
            syncState: syncState
        )
        rebuildItems()
    }

    // MARK: - Queue

    /// The queue's only mutation point.
    ///
    /// The array, its persisted form and the failure count the panel shows must
    /// not be able to disagree, so nothing assigns `queuedOperations` directly.
    private func setQueue(_ operations: [PendingOperation]) {
        queuedOperations = operations
        queueStore.save(operations)
        failedWriteCount = operations.count
    }

    private func enqueue(_ operation: PendingOperation) {
        setQueue(queuedOperations + [operation])
    }

    /// Serial, in insertion order. Every mutation resolves the reminder first:
    /// if it is gone, the operation is dropped rather than re-created, so a
    /// stale retry can never overwrite newer work done on another device.
    private func drainQueue() async {
        guard isEnabled, authorization.canRead, !queuedOperations.isEmpty else { return }

        var remaining: [PendingOperation] = []
        for operation in queuedOperations {
            do {
                try await perform(operation)
            } catch {
                lastError = error.localizedDescription
                remaining.append(operation)
            }
        }

        if remaining.count != queuedOperations.count {
            setQueue(remaining)
        }
    }

    private func perform(_ operation: PendingOperation) async throws {
        switch operation {
        case .create(let localID, let title, let due, let listID):
            _ = try await service.create(title: title, due: due, in: listID, marker: localID)
            placeholders.removeAll { $0.item.localID == localID }
            rebuildItems()

        case .update(let reminderID, let externalID, let listID, let title, let due):
            guard await isResolvable(reminderID, externalID: externalID, listID: listID) else { return }
            try await service.update(id: reminderID, title: title, due: due)

        case .setCompleted(let reminderID, let externalID, let listID, let isCompleted):
            // Both exits release the suppression a failed completion left
            // behind: the row is out of the panel for good either way, so
            // nothing may keep hiding a reminder the store still has.
            guard await isResolvable(reminderID, externalID: externalID, listID: listID) else {
                releaseSuppression(reminderID)
                return
            }
            try await service.setCompleted(id: reminderID, isCompleted: isCompleted)
            releaseSuppression(reminderID)

        case .delete(let reminderID, let externalID, let listID):
            // Already gone is the outcome we wanted.
            guard await isResolvable(reminderID, externalID: externalID, listID: listID) else {
                releaseSuppression(reminderID)
                return
            }
            try await service.delete(id: reminderID)
            releaseSuppression(reminderID)
        }
    }

    private func isResolvable(_ id: String, externalID: String?, listID: String) async -> Bool {
        await service.resolve(id: id, externalID: externalID, in: listID) != nil
    }

    // MARK: - Helpers

    /// Clears a dangling selection (the remembered list may have been deleted)
    /// and falls back to the system default list.
    private func reconcileSelectedList() {
        if let stored = settingsStore.remindersCalendarIdentifier,
           lists.contains(where: { $0.id == stored }) {
            return
        }

        let fallback = lists.first(where: \.isDefault) ?? lists.first
        settingsStore.remindersCalendarIdentifier = fallback?.id
    }

    private func foregroundIfNeeded() -> Bool {
        guard NSApp.activationPolicy() == .accessory else { return false }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func restoreAccessoryIfNeeded(_ didForeground: Bool) {
        guard didForeground else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Queue persistence

/// Persists the pending-write queue at
/// `Application Support/YUANNotch/reminder-queue.json`.
///
/// Atomic write plus corruption isolation, the way the notes are written. There
/// is no rotating backup on purpose: this file holds only operations that have
/// not reached the local store yet, so losing it costs a retry the user can
/// repeat — unlike a note, where a lost file is lost writing.
struct ReminderQueueStore {
    /// 2: `PendingOperation.create` now carries a `ReminderDue?` instead of a
    /// non-optional `Date`, which changes the persisted JSON shape. A v1 file
    /// holds only writes that already failed to land, so dropping it costs a
    /// retry the user can repeat — the same trade the corruption path makes.
    private static let currentVersion = 2

    private struct QueueFile: Codable {
        let schemaVersion: Int
        var operations: [PendingOperation]
    }

    private let fileManager = FileManager.default
    private let queueURL: URL

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        queueURL = applicationSupport
            .appendingPathComponent("YUANNotch", isDirectory: true)
            .appendingPathComponent("reminder-queue.json")
    }

    func load() -> [PendingOperation] {
        guard fileManager.fileExists(atPath: queueURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: queueURL)
            let file = try JSONDecoder().decode(QueueFile.self, from: data)
            guard file.schemaVersion == Self.currentVersion else {
                NSLog("YUANNotch: reminder queue has unsupported version \(file.schemaVersion); ignoring it")
                return []
            }
            return file.operations
        } catch {
            NSLog("YUANNotch: unreadable reminder queue at \(queueURL.path): \(error)")
            isolateUnreadableQueue()
            return []
        }
    }

    func save(_ operations: [PendingOperation]) {
        let file = QueueFile(schemaVersion: Self.currentVersion, operations: operations)

        do {
            let data = try JSONEncoder().encode(file)
            try fileManager.createDirectory(
                at: queueURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: queueURL, options: [.atomic])
        } catch {
            NSLog("YUANNotch: failed to save reminder queue: \(error)")
        }
    }

    private func isolateUnreadableQueue() {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let corruptURL = queueURL
            .deletingLastPathComponent()
            .appendingPathComponent("reminder-queue.corrupt-\(timestamp).json")

        do {
            try fileManager.moveItem(at: queueURL, to: corruptURL)
            NSLog("YUANNotch: isolated unreadable reminder queue at \(corruptURL.path)")
        } catch {
            NSLog("YUANNotch: could not isolate unreadable reminder queue: \(error)")
        }
    }
}

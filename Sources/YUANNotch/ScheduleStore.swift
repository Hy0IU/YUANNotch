import AppKit
import Combine
import Foundation

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var sources: [ScheduleSource] = []
    @Published private(set) var entries: [ScheduleEntry] = []
    @Published private(set) var calendarAuthorization: ScheduleAuthorization
    @Published private(set) var reminderAuthorization: ScheduleAuthorization
    @Published private(set) var isLoading = false
    @Published private(set) var errors: [String] = []
    @Published private(set) var requestingAccess: ScheduleSourceKind?

    let calendar: Calendar
    private(set) var range: DateInterval

    private let service: any ScheduleServing
    private let defaults: UserDefaults
    /// Absence means all sources, while an explicitly stored empty set means
    /// none. Each provider keeps its own default/explicit selection state.
    private var selections: [ScheduleSourceKind: Set<String>] = [:]
    private var providerErrors: [ScheduleSourceKind: String] = [:]
    private var accessErrors: [ScheduleSourceKind: String] = [:]
    private var isRequestingAccess: Bool { requestingAccess != nil }
    private var isVisible = false
    private var refreshGeneration = UUID()
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var changeObservationTask: Task<Void, Never>?
    private var lifecycleObservations: [ScheduleNotificationObservation] = []

    private struct ProviderSnapshot: Sendable {
        let kind: ScheduleSourceKind
        let authorization: ScheduleAuthorization
        let sources: [ScheduleSource]
        /// Nil is a failed read, never a successful empty result.
        let entries: [ScheduleEntry]?
        let error: String?
    }

    init(
        service: any ScheduleServing,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.service = service
        self.defaults = defaults
        self.calendar = calendar
        calendarAuthorization = service.authorization(for: .calendar)
        reminderAuthorization = service.authorization(for: .reminders)
        let today = calendar.startOfDay(for: Date())
        range = DateInterval(
            start: calendar.date(byAdding: .day, value: -30, to: today) ?? today,
            end: calendar.date(byAdding: .day, value: 31, to: today) ?? today
        )
        for kind in ScheduleSourceKind.allCases {
            if let stored = defaults.array(forKey: Self.selectionKey(for: kind)) as? [String] {
                selections[kind] = Set(stored)
            }
        }
        observeLifecycle()
        observeEventKitChanges()
        // Discovery never requests access. This also populates the settings
        // source picker when the Schedule tab has not been opened yet.
        requestRefresh()
    }

    deinit {
        refreshTask?.cancel()
        pollTask?.cancel()
        changeObservationTask?.cancel()
    }

    func isSelected(_ source: ScheduleSource) -> Bool {
        selections[source.kind]?.contains(source.key) ?? true
    }

    func setSelected(_ source: ScheduleSource, isSelected: Bool) {
        guard self.isSelected(source) != isSelected else { return }
        var selected = selections[source.kind]
            ?? Set(sources.filter { $0.kind == source.kind }.map(\.key))
        if isSelected { selected.insert(source.key) }
        else { selected.remove(source.key) }
        objectWillChange.send()
        selections[source.kind] = selected
        defaults.set(selected.sorted(), forKey: Self.selectionKey(for: source.kind))
        entries.removeAll { !isSourceSelected(kind: $0.kind, id: $0.sourceID) }
        requestRefresh()
    }

    /// The caller may query any day range, independently of panel visibility.
    /// A newer range or selection invalidates every older in-flight response.
    func refresh(in range: DateInterval) async {
        guard !Task.isCancelled else { return }
        self.range = range
        entries.removeAll { !Self.intersects($0, range: range) }
        let task = startRefresh()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func requestRefresh() {
        _ = startRefresh()
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        pollTask?.cancel()
        pollTask = nil
        if visible {
            requestRefresh()
            pollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                    guard !Task.isCancelled, let self else { return }
                    // The binding's lifetime ends at this loop iteration; the
                    // store is not kept alive across the next sleep.
                    if self.refreshTask == nil { self.requestRefresh() }
                }
            }
        } else {
            invalidateRefresh()
        }
    }

    /// Only an explicit UI action reaches this method. Init, discovery,
    /// refresh, notifications and polling never activate the app or ask TCC.
    func requestAccess(for kind: ScheduleSourceKind) async {
        guard !isRequestingAccess, !Task.isCancelled else { return }
        let currentAuthorization = service.authorization(for: kind)
        if currentAuthorization.canRead {
            updateAuthorization(kind, status: currentAuthorization)
            accessErrors[kind] = nil
            rebuildErrors()
            requestRefresh()
            return
        }
        requestingAccess = kind
        invalidateRefresh()
        isLoading = true
        defer {
            requestingAccess = nil
            isLoading = refreshTask != nil
        }
        do {
            let authorization = try await service.requestAccess(for: kind)
            guard !Task.isCancelled else { return }
            updateAuthorization(kind, status: authorization)
            accessErrors[kind] = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            accessErrors[kind] = error.localizedDescription
            updateAuthorization(kind, status: service.authorization(for: kind))
        }
        rebuildErrors()
        requestRefresh()
    }

    func openPrivacySettings(for kind: ScheduleSourceKind) {
        let anchor = kind == .calendar ? "Privacy_Calendars" : "Privacy_Reminders"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Snapshot refresh

    @discardableResult
    private func startRefresh() -> Task<Void, Never> {
        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation
        let range = range
        let selections = selections
        let service = service
        isLoading = true
        let task = Task { @MainActor [weak self] in
            async let events = Self.readProvider(.calendar, service: service, range: range, selections: selections)
            async let reminders = Self.readProvider(.reminders, service: service, range: range, selections: selections)
            let (eventSnapshot, reminderSnapshot) = await (events, reminders)
            guard !Task.isCancelled else {
                self?.finishCanceledRefresh(generation: generation)
                return
            }
            self?.apply([eventSnapshot, reminderSnapshot], generation: generation, range: range)
        }
        refreshTask = task
        return task
    }

    private nonisolated static func readProvider(
        _ kind: ScheduleSourceKind,
        service: any ScheduleServing,
        range: DateInterval,
        selections: [ScheduleSourceKind: Set<String>]
    ) async -> ProviderSnapshot {
        let authorization = service.authorization(for: kind)
        guard authorization.canRead else {
            return ProviderSnapshot(
                kind: kind, authorization: authorization, sources: [], entries: nil, error: nil
            )
        }
        let sources = await service.sources(for: kind)
        let selected = sources.filter { selections[kind]?.contains($0.key) ?? true }
        do {
            try Task.checkCancellation()
            // Never pass an empty calendar list to EventKit: depending on the
            // predicate it can mean all calendars, not an explicit selection of none.
            let entries: [ScheduleEntry]
            if selected.isEmpty {
                entries = []
            } else {
                entries = try await service.entries(in: range, sources: selected)
            }
            try Task.checkCancellation()
            let currentAuthorization = service.authorization(for: kind)
            guard currentAuthorization.canRead else {
                return ProviderSnapshot(
                    kind: kind, authorization: currentAuthorization, sources: [], entries: nil, error: nil
                )
            }
            let selectedIDs = Set(selected.map(\.id))
            return ProviderSnapshot(
                kind: kind, authorization: currentAuthorization, sources: sources,
                entries: entries.filter {
                    $0.kind == kind && selectedIDs.contains($0.sourceID) && intersects($0, range: range)
                },
                error: nil
            )
        } catch {
            let currentAuthorization = service.authorization(for: kind)
            return ProviderSnapshot(
                kind: kind, authorization: currentAuthorization,
                sources: currentAuthorization.canRead ? sources : [], entries: nil,
                error: currentAuthorization.canRead
                    ? "\(kind == .calendar ? "Calendar" : "Reminders"): \(error.localizedDescription)"
                    : nil
            )
        }
    }

    private func apply(_ snapshots: [ProviderSnapshot], generation: UUID, range: DateInterval) {
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        var nextSources: [ScheduleSource] = []
        var nextEntries: [ScheduleEntry] = []
        for snapshot in snapshots {
            let kind = snapshot.kind
            updateAuthorization(kind, status: snapshot.authorization)
            providerErrors[kind] = snapshot.error
            guard snapshot.authorization.canRead else { continue }
            nextSources.append(contentsOf: snapshot.sources)
            if let fresh = snapshot.entries {
                nextEntries.append(contentsOf: fresh)
                accessErrors[kind] = nil
            } else {
                // A failed provider read is not a successful empty snapshot.
                // Keep its still-relevant previous rows while showing its error;
                // the other provider's successful result still lands normally.
                let availableIDs = Set(snapshot.sources.map(\.id))
                nextEntries.append(contentsOf: entries.filter {
                    $0.kind == kind && availableIDs.contains($0.sourceID)
                        && isSourceSelected(kind: kind, id: $0.sourceID)
                        && Self.intersects($0, range: range)
                })
            }
        }
        sources = nextSources.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.account != $1.account {
                return $0.account.localizedStandardCompare($1.account) == .orderedAscending
            }
            if $0.title != $1.title {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.id < $1.id
        }
        entries = nextEntries.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
        refreshTask = nil
        isLoading = isRequestingAccess
        rebuildErrors()
    }

    private func finishCanceledRefresh(generation: UUID) {
        guard generation == refreshGeneration else { return }
        // Cancellation may end a caller-owned .task without replacing it. Only
        // clear its loading state; no canceled data, authorization or error lands.
        refreshTask = nil
        isLoading = isRequestingAccess
    }

    private func invalidateRefresh() {
        refreshGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isLoading = isRequestingAccess
    }

    private func isSourceSelected(kind: ScheduleSourceKind, id: String) -> Bool {
        selections[kind]?.contains("\(kind.rawValue):\(id)") ?? true
    }

    private static func selectionKey(for kind: ScheduleSourceKind) -> String {
        "schedule.selectedSourceKeys.\(kind.rawValue)"
    }

    private nonisolated static func intersects(_ entry: ScheduleEntry, range: DateInterval) -> Bool {
        if entry.kind == .calendar, let end = entry.end, end > entry.start {
            return entry.start < range.end && end > range.start
        }
        return entry.start >= range.start && entry.start < range.end
    }

    private func updateAuthorization(_ kind: ScheduleSourceKind, status: ScheduleAuthorization) {
        switch kind {
        case .calendar: calendarAuthorization = status
        case .reminders: reminderAuthorization = status
        }
    }

    private func rebuildErrors() {
        errors = ScheduleSourceKind.allCases.compactMap { accessErrors[$0] ?? providerErrors[$0] }
    }

    // MARK: - Observation lifetimes

    private func observeEventKitChanges() {
        let service = service
        changeObservationTask = Task { @MainActor [weak self] in
            let changes = await service.changes()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                self?.requestRefresh()
            }
        }
    }

    private func observeLifecycle() {
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestRefresh() }
        }
        lifecycleObservations = [
            ScheduleNotificationObservation(name: NSApplication.didBecomeActiveNotification, handler: handler),
            ScheduleNotificationObservation(name: .NSCalendarDayChanged, handler: handler),
            ScheduleNotificationObservation(name: .NSSystemTimeZoneDidChange, handler: handler),
            ScheduleNotificationObservation(name: Notification.Name("NSSystemClockDidChangeNotification"), handler: handler),
            ScheduleNotificationObservation(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification, handler: handler)
        ]
    }
}

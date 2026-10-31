import Foundation
import os

private actor AuthorizationDecision {
    private var decision: CheckedContinuation<ScheduleAuthorization, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func request() async -> ScheduleAuthorization {
        await withCheckedContinuation { continuation in
            decision = continuation
            for waiter in startedWaiters { waiter.resume() }
            startedWaiters.removeAll()
        }
    }

    func waitUntilRequested() async {
        if decision != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func resolve(_ status: ScheduleAuthorization) {
        let continuation = decision
        decision = nil
        continuation?.resume(returning: status)
    }
}

private actor SourceDiscoveryGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class AuthorizationService: ScheduleServing, Sendable {
    private struct State {
        var status: ScheduleAuthorization = .notDetermined
        var requestCount = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let decision = AuthorizationDecision()
    let discovery: SourceDiscoveryGate?
    let source: ScheduleSource
    let event: ScheduleEntry

    init(day: Date, blocksDiscovery: Bool = false) {
        discovery = blocksDiscovery ? SourceDiscoveryGate() : nil
        source = ScheduleSource(id: "calendar", title: "Meetings", account: "Fixture", kind: .calendar,
                                color: ScheduleColor(red: 0.3, green: 0.6, blue: 1))
        event = ScheduleEntry(id: "meeting", sourceID: "calendar", kind: .calendar,
                              title: "Meeting", start: day.addingTimeInterval(3600),
                              end: day.addingTimeInterval(7200), isAllDay: false, location: nil)
    }

    func authorization(for kind: ScheduleSourceKind) -> ScheduleAuthorization {
        kind == .calendar ? state.withLock { $0.status } : .denied
    }

    func setAuthorization(_ status: ScheduleAuthorization) { state.withLock { $0.status = status } }
    var requestCount: Int { state.withLock { $0.requestCount } }

    func requestAccess(for kind: ScheduleSourceKind) async throws -> ScheduleAuthorization {
        precondition(kind == .calendar)
        state.withLock { $0.requestCount += 1 }
        let result = await decision.request()
        setAuthorization(result)
        return result
    }

    func sources(for kind: ScheduleSourceKind) async -> [ScheduleSource] {
        guard kind == .calendar, authorization(for: kind).canRead else { return [] }
        await discovery?.wait()
        return [source]
    }

    func entries(in range: DateInterval, sources: [ScheduleSource]) async throws -> [ScheduleEntry] {
        sources.contains(where: { $0.key == source.key }) ? [event] : []
    }

    func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

@MainActor
enum ScheduleAuthorizationScenarios {
    static func run() async {
        let suite = "schedule-authorization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let day = Calendar.current.startOfDay(for: Date())
        let range = DateInterval(start: day, end: day.addingTimeInterval(24 * 3600))

        let granting = AuthorizationService(day: day)
        let store = ScheduleStore(service: granting, defaults: defaults)
        await store.refresh(in: range)
        precondition(store.calendarAuthorization == .notDetermined && store.entries.isEmpty)
        let request = Task { await store.requestAccess(for: .calendar) }
        await granting.decision.waitUntilRequested()
        precondition(store.requestingAccess == .calendar)
        await store.requestAccess(for: .calendar)
        precondition(granting.requestCount == 1, "A pending permission decision must not start a second request")
        await granting.decision.resolve(.fullAccess)
        await request.value
        precondition(store.calendarAuthorization == .fullAccess && store.requestingAccess == nil,
                     "A successful permission callback must immediately publish connected state")
        await store.refresh(in: range)
        precondition(store.sources.contains { $0.key == granting.source.key })
        precondition(store.entries == [granting.event], "Granting access must load actual provider results")
        granting.setAuthorization(.denied)
        await store.refresh(in: range)
        precondition(store.calendarAuthorization == .denied && store.entries.isEmpty,
                     "Revocation must clear previously readable calendar rows")
        print("PASS permission grant publishes connected state, loads meetings, coalesces pending requests, and honors revocation")

        // Simulate permission granted elsewhere while the published view still
        // says not connected. Discovery deliberately cannot finish yet.
        let externallyGranted = AuthorizationService(day: day, blocksDiscovery: true)
        let externalStore = ScheduleStore(service: externallyGranted, defaults: defaults)
        await externalStore.refresh(in: range)
        externallyGranted.setAuthorization(.fullAccess)
        await externalStore.requestAccess(for: .calendar)
        precondition(externalStore.calendarAuthorization == .fullAccess,
                     "Already-granted access must update the UI before source discovery finishes")
        precondition(externallyGranted.requestCount == 0, "An existing grant must not prompt again")
        await externallyGranted.discovery?.release()
        await externalStore.refresh(in: range)
        precondition(externalStore.entries == [externallyGranted.event])
        print("PASS an existing grant reconnects immediately without waiting on discovery or requesting permission again")

        let declining = AuthorizationService(day: day)
        let declinedStore = ScheduleStore(service: declining, defaults: defaults)
        await declinedStore.refresh(in: range)
        let declinedRequest = Task { await declinedStore.requestAccess(for: .calendar) }
        await declining.decision.waitUntilRequested()
        await declining.decision.resolve(.denied)
        await declinedRequest.value
        await declinedStore.refresh(in: range)
        precondition(declinedStore.calendarAuthorization == .denied && declinedStore.requestingAccess == nil)
        precondition(declinedStore.entries.isEmpty)
        print("PASS a declined request stays denied and leaves no pending permission state")
    }
}

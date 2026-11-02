import Foundation
import os

private actor ScheduleReadGate {
    private var isClosed = false
    private var readStarted = false
    private var readers: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    func close() {
        isClosed = true
        readStarted = false
    }

    func wait() async {
        guard isClosed else { return }
        readStarted = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        await withCheckedContinuation { readers.append($0) }
    }

    func waitUntilReading() async {
        if readStarted { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func open() {
        isClosed = false
        for reader in readers { reader.resume() }
        readers.removeAll()
    }
}

private final class RefreshService: ScheduleServing, Sendable {
    let gate = ScheduleReadGate()
    let source = ScheduleSource(id: "events", title: "Work", account: "Fixture", kind: .calendar,
                                color: ScheduleColor(red: 0.3, green: 0.6, blue: 1))
    private let values: OSAllocatedUnfairLock<[ScheduleEntry]>

    init(entries: [ScheduleEntry]) { values = OSAllocatedUnfairLock(initialState: entries) }
    func replaceEntries(_ entries: [ScheduleEntry]) { values.withLock { $0 = entries } }
    func authorization(for kind: ScheduleSourceKind) -> ScheduleAuthorization { .fullAccess }
    func requestAccess(for kind: ScheduleSourceKind) async throws -> ScheduleAuthorization {
        preconditionFailure("Refresh must not request permission")
    }
    func sources(for kind: ScheduleSourceKind) async -> [ScheduleSource] { kind == .calendar ? [source] : [] }
    func entries(in range: DateInterval, sources: [ScheduleSource]) async throws -> [ScheduleEntry] {
        let snapshot = values.withLock { $0 }
        await gate.wait()
        return snapshot
    }
    func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

@MainActor
enum ScheduleRefreshScenarios {
    static func run() async {
        let suite = "schedule-refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let end = calendar.date(byAdding: .day, value: 3, to: today)!
        let range = DateInterval(start: today, end: end)
        let original = ScheduleEntry(id: "meeting", sourceID: "events", kind: .calendar,
                                     title: "Original meeting", start: today.addingTimeInterval(3600),
                                     end: today.addingTimeInterval(7200), isAllDay: false, location: nil)
        let updated = ScheduleEntry(id: original.id, sourceID: original.sourceID, kind: .calendar,
                                    title: "Updated meeting", start: original.start, end: original.end,
                                    isAllDay: false, location: nil)
        let service = RefreshService(entries: [original])
        let store = ScheduleStore(service: service, defaults: defaults, calendar: calendar)
        await store.refresh(in: range)
        precondition(store.loadedRange == range && store.entries == [original])
        await service.gate.close()
        service.replaceEntries([updated])
        let manual = Task { await store.refreshManually() }
        await service.gate.waitUntilReading()
        precondition(store.isLoading && store.isRefreshing)
        precondition(store.entries == [original] && store.sources == [service.source],
                     "Existing cards and source names must remain on screen while a reload is pending")
        precondition(!store.isLoadingDay(today) && !store.isLoadingDay(tomorrow),
                     "A known empty day must not switch to Loading during manual reload")
        await service.gate.open()
        await manual.value
        precondition(store.entries == [updated] && !store.isRefreshing)
        print("PASS manual refresh preserves cards, source names and known-empty days until replacement data is ready")

        await service.gate.close()
        let background = Task { await store.refresh(in: range) }
        await service.gate.waitUntilReading()
        precondition(store.isLoading && !store.isRefreshing,
                     "Automatic refresh must not animate the manual refresh control")
        precondition(!store.isLoadingDay(tomorrow))
        await service.gate.open()
        await background.value
        print("PASS background refresh remains quiet and keeps empty-day presentation stable")

        await service.gate.close()
        let extendedEnd = calendar.date(byAdding: .day, value: 2, to: end)!
        let extended = Task { await store.refresh(in: DateInterval(start: today, end: extendedEnd)) }
        await service.gate.waitUntilReading()
        precondition(!store.isLoadingDay(today) && store.isLoadingDay(end),
                     "Newly exposed dates must still show an unanswered query, unlike previously loaded dates")
        await service.gate.open()
        await extended.value
        precondition(!store.isLoadingDay(end) && store.loadedRange?.end == extendedEnd)
        print("PASS extending the date window preserves known days while marking only new dates as loading")
    }
}

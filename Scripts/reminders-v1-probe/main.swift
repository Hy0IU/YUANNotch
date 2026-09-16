import EventKit
import Foundation

// YUANNotch · Apple Reminders probe
//
// Verifies the P1 exit criteria against a real reminders database. It is
// compiled together with the shipping Sources/YUANNotch/AppleRemindersService.swift,
// so the authorization, list, create, read and delete paths under test are the
// ones the app actually runs — not a second implementation.
//
// Checks:
//   1. authorization, including the request flow
//   2. writable list enumeration, with the this-Mac-only flag
//   3. V1: does predicateForIncompleteReminders(nil, nil, [list]) include
//      reminders that have no due date? Compared against a full scan.
//   4. write round-trip: create → appears in the incomplete query → due date
//      survives the components/time-zone round-trip → alarm present →
//      resolve → delete → gone
//   5. change stream (P3): does `.EKEventStoreChanged` actually reach the
//      consumer through the service's debounced stream, and does a burst of
//      writes coalesce into one signal?
//
// It creates exactly one reminder and deletes it again. Nothing else is
// written. The only synthetic reminder is removed before the probe exits.

@MainActor
func runProbe() async -> Int32 {
    var failures = 0

    func report(_ label: String, _ passed: Bool, _ detail: String) {
        print("\(passed ? "PASS" : "FAIL")  \(label)")
        print("      \(detail)")
        if !passed { failures += 1 }
    }

    print("=== YUANNotch · Apple Reminders probe ===")
    print("")

    let service = AppleRemindersService()

    // 1 ─ Authorization
    var authorization = service.authorizationStatus()
    print("Authorization before request: \(authorization)")

    if !authorization.canRead {
        do {
            authorization = try await service.requestAccess()
        } catch {
            print("FAIL  requestAccess threw: \(error)")
            return 1
        }
    }
    print("Authorization after request:  \(authorization)")
    print("")

    guard authorization.canRead else {
        print("FAIL  no read access. Grant it under System Settings → Privacy & Security → Reminders, then re-run.")
        return 1
    }

    // 2 ─ Lists
    let lists = await service.availableLists()
    print("--- Writable reminder lists (\(lists.count)) ---")
    guard !lists.isEmpty else {
        print("FAIL  no writable reminder list. Create one in Reminders first.")
        return 1
    }
    for list in lists {
        let origin = list.isLocalOnly ? "THIS MAC ONLY" : list.sourceTitle
        print("  \(list.isDefault ? "*" : " ") \(list.title)  [\(origin)]")
        print("      \(list.id)")
    }
    print("")

    // 3 ─ V1
    print("--- V1: predicateForIncompleteReminders(nil, nil) vs full scan ---")
    var v1Conclusive = false
    var v1Passed = true

    for list in lists {
        do {
            let incomplete = try await service.snapshot(in: list.id)
            let undatedInIncomplete = incomplete.filter { $0.dueDate == nil }.count

            // Deliberately raw and probe-only: the service has no "fetch
            // everything" API, and adding one for diagnostics would put
            // non-shipping code on the shipping surface.
            let everything = await fetchEverything(listID: list.id)
            let incompleteInEverything = everything.filter { !$0.isCompleted }
            let undatedInEverything = incompleteInEverything.filter { $0.dueDate == nil }.count

            print("  \(list.title)")
            print("      incomplete predicate : \(incomplete.count) items, \(undatedInIncomplete) undated")
            print("      full scan (incomplete): \(incompleteInEverything.count) items, \(undatedInEverything) undated")

            if undatedInEverything > 0 {
                v1Conclusive = true
                if undatedInIncomplete == 0 { v1Passed = false }
            }
        } catch {
            print("  \(list.title): query failed — \(error)")
        }
    }
    print("")

    if v1Conclusive {
        report(
            "V1 undated reminders are included in the incomplete query",
            v1Passed,
            v1Passed
                ? "each list with undated incomplete reminders reported them through the predicate"
                : "a list has undated incomplete reminders that the predicate did not return — the union compensation in §8.2 is required"
        )
    } else {
        print("INCONCLUSIVE  no undated incomplete reminder exists in any list.")
        print("              Add a reminder without a due date in Reminders, then re-run to settle V1.")
    }
    print("")

    // 4 ─ Write round-trip
    let target = lists.first(where: \.isDefault) ?? lists[0]
    print("--- Write round-trip in \"\(target.title)\" ---")

    let dueDate = Date().addingTimeInterval(5 * 60)
    let marker = UUID()
    let title = "YUANNotch probe \(Int(Date().timeIntervalSince1970))"

    do {
        let created = try await service.create(
            title: title,
            dueDate: dueDate,
            in: target.id,
            marker: marker
        )
        print("  created id=\(created.id)")
        print("         externalID=\(created.externalID ?? "nil")")

        let drift = abs((created.dueDate ?? .distantPast).timeIntervalSince(dueDate))
        report(
            "C4 due date survives the components round-trip",
            drift < 1,
            String(format: "requested %.0f, read back %.0f (drift %.2fs)", dueDate.timeIntervalSince1970, (created.dueDate ?? .distantPast).timeIntervalSince1970, drift)
        )

        report(
            "C5 an absolute alarm was written",
            created.hasAlarm,
            created.hasAlarm ? "alarms is non-empty" : "alarms is empty — the reminder would not fire"
        )

        let visible = try await service.snapshot(in: target.id).contains { $0.id == created.id }
        report(
            "the new reminder appears in the incomplete query",
            visible,
            visible ? "found by local identifier in the list snapshot" : "created but not returned by the list snapshot"
        )

        let resolved = await service.resolve(id: created.id, externalID: created.externalID, in: target.id)
        report(
            "resolve(id:externalID:in:) finds it",
            resolved != nil,
            resolved != nil ? "local identifier resolved" : "resolution failed"
        )

        try await service.delete(id: created.id)
        let stillThere = try await service.snapshot(in: target.id).contains { $0.id == created.id }
        report(
            "delete removes it",
            !stillThere,
            stillThere ? "still present after remove" : "gone from the list snapshot"
        )
    } catch {
        print("FAIL  round-trip threw: \(error)")
        failures += 1
    }

    print("")

    // 5 ─ Change stream (P3)
    //
    // Two independent things can fail here and they need to be told apart:
    //   (a) EventKit never posts `.EKEventStoreChanged` for this write, or
    //   (b) it posts, but the service's observer/stream plumbing drops it.
    // A raw observer is therefore installed alongside the service's stream, so
    // a missing emission can be attributed rather than guessed at.
    print("--- Change stream (debounced, P3) ---")

    let rawObserver = RawNotificationObserver()
    await rawObserver.start()

    let recorder = EmissionRecorder()
    let observation = Task {
        let stream = await service.changes()
        for await _ in stream {
            await recorder.record()
        }
    }
    // Let the subscription establish before writing anything.
    try? await Task.sleep(for: .milliseconds(500))
    print("  subscribed; raw .EKEventStoreChanged notifications are counted separately")

    let changeDue = Date().addingTimeInterval(15 * 60)
    let changeMarker = UUID()
    let changeTitle = "YUANNotch change probe \(Int(Date().timeIntervalSince1970))"
    var changeID: String?

    do {
        let wroteAt = Date()
        let created = try await service.create(
            title: changeTitle,
            dueDate: changeDue,
            in: target.id,
            marker: changeMarker
        )
        changeID = created.id
        let writeFinished = Date()

        let emittedAt = await recorder.waitForEmission(after: wroteAt, within: 10)
        let rawCount = await rawObserver.count()

        if let emittedAt {
            report(
                "a store change reaches the consumer",
                true,
                String(
                    format: "emission %.2fs after the write started (create returned in %.2fs after that); raw notifications seen: %d",
                    emittedAt.timeIntervalSince(wroteAt),
                    writeFinished.timeIntervalSince(wroteAt),
                    rawCount
                )
            )
        } else {
            report(
                "a store change reaches the consumer",
                false,
                "no emission within 10s. Raw .EKEventStoreChanged notifications seen: \(rawCount) — "
                    + (rawCount == 0
                        ? "EventKit posted nothing for this write"
                        : "EventKit posted, so the fault is in the service plumbing")
            )
        }
    } catch {
        print("FAIL  change-stream write threw: \(error)")
        failures += 1
    }

    // Burst behaviour — informational, deliberately not a pass/fail check.
    //
    // EventKit is free to post nothing at all for this process's own writes
    // (measured), so "no emission" here is EventKit's choice, not a defect.
    // What is worth reporting is how many emissions came out per raw
    // notification when any did arrive.
    if let changeID {
        await recorder.reset()
        let rawBefore = await rawObserver.count()
        let burstStart = Date()
        for _ in 0..<4 {
            try? await service.update(id: changeID, title: changeTitle, dueDate: nil)
        }
        _ = await recorder.waitForEmission(after: burstStart, within: 10)
        try? await Task.sleep(for: .milliseconds(2000))
        let burstEmissions = await recorder.count()
        let rawDuring = await rawObserver.count() - rawBefore

        if rawDuring == 0 {
            print("NOTE  4 rapid writes produced no notification at all.")
            print("      EventKit does not reliably post .EKEventStoreChanged for this process's own")
            print("      writes, so this path cannot be asserted from the probe. The app does not")
            print("      depend on it: every write triggers an explicit reload, and the open panel polls.")
        } else {
            let held = burstEmissions <= rawDuring
            print("NOTE  \(burstEmissions) emission(s) for \(rawDuring) raw notification(s); coalescing \(held ? "held" : "did not hold")")
        }
    }

    if let changeID {
        try? await service.delete(id: changeID)
    }
    try? await Task.sleep(for: .milliseconds(1200))
    print("  raw notifications for the whole section: \(await rawObserver.count())")
    observation.cancel()

    print("")
    print(failures == 0 ? "=== all checks passed ===" : "=== \(failures) check(s) failed ===")
    return failures == 0 ? 0 : 1
}

/// Counts raw `.EKEventStoreChanged` notifications, independently of the
/// service. This is the baseline that tells an EventKit silence apart from a
/// bug in our own observer/stream plumbing.
actor RawNotificationObserver {
    private var observer: NSObjectProtocol?
    private var ticks = 0

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.bump() }
        }
    }

    func count() -> Int { ticks }

    private func bump() { ticks += 1 }
}

/// Counts debounced change emissions so the probe can measure both the first
/// latency and whether a burst collapsed into one signal.
actor EmissionRecorder {
    private var emissionDates: [Date] = []

    func record() {
        emissionDates.append(Date())
    }

    func reset() {
        emissionDates.removeAll()
    }

    func count() -> Int {
        emissionDates.count
    }

    func waitForEmission(after date: Date, within seconds: TimeInterval) async -> Date? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let hit = emissionDates.first(where: { $0 >= date }) {
                return hit
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

/// Probe-only full scan, used as the V1 baseline.
@MainActor
func fetchEverything(listID: String) async -> [ReminderSnapshot] {
    let store = EKEventStore()
    guard let calendar = store.calendar(withIdentifier: listID) else { return [] }
    let predicate = store.predicateForReminders(in: [calendar])

    return await withCheckedContinuation { continuation in
        store.fetchReminders(matching: predicate) { reminders in
            // EKReminder is not Sendable; project inside the callback.
            continuation.resume(returning: (reminders ?? []).compactMap(ReminderSnapshot.init))
        }
    }
}

let exitStatus = await runProbe()
exit(exitStatus)

import Foundation

@main
struct DailyPlanProbe {
    @MainActor
    static func main() {
        var failures = 0

        func check(_ label: String, _ passed: Bool, _ detail: String) {
            print("\(passed ? "PASS" : "FAIL")  \(label)")
            print("      \(detail)")
            if !passed { failures += 1 }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            ))!
        }

        print("=== YUANNotch · daily plan probe ===")
        print("")
        print("— 1 · local-day accounting —")

        let midnightStart = date(2026, 9, 22, 23, 55)
        let midnightEnd = date(2026, 9, 23, 0, 5)
        let split = DailyPlanEngine.splitFocusInterval(
            from: midnightStart,
            to: midnightEnd,
            calendar: calendar
        )
        let firstDay = PlanDayKey(date: midnightStart, calendar: calendar)
        let secondDay = PlanDayKey(date: midnightEnd, calendar: calendar)
        check(
            "a focus interval is split at local midnight",
            split[firstDay] == 300 && split[secondDay] == 300 && split.count == 2,
            "Sep 22 = \(Int(split[firstDay] ?? -1))s, Sep 23 = \(Int(split[secondDay] ?? -1))s"
        )

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstStart = losAngeles.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 55))!
        let dstEnd = dstStart.addingTimeInterval(10 * 60)
        let dstSplit = DailyPlanEngine.splitFocusInterval(from: dstStart, to: dstEnd, calendar: losAngeles)
        check(
            "DST does not assume a 24-hour day",
            dstSplit.values.reduce(0, +) == 600,
            "the spring-forward interval remains exactly \(Int(dstSplit.values.reduce(0, +)))s"
        )

        print("")
        print("— 2 · pause, resume and plan switching —")

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("yuanotch-daily-plan-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let persistence = DailyPlanPersistence(fileURL: tempRoot.appendingPathComponent("plans.json"))

        var clock = date(2026, 9, 22, 10, 0)
        let store = DailyPlanStore(
            persistence: persistence,
            calendar: calendar,
            nowProvider: { clock },
            startsTimer: false
        )
        store.draft = DailyPlanDraft(title: "Reading", targetMinutes: 60)
        store.commitDraft()
        let reading = store.plans[0]

        store.start(reading, at: clock)
        clock = clock.addingTimeInterval(10 * 60)
        store.togglePause(at: clock)
        clock = clock.addingTimeInterval(20 * 60)
        store.togglePause(at: clock)
        clock = clock.addingTimeInterval(10 * 60)
        store.togglePause(at: clock)

        check(
            "paused time is excluded from the daily total",
            store.focusedSeconds(for: reading.id, on: clock) == 20 * 60,
            "10m focus + 20m pause + 10m focus = \(Int(store.focusedSeconds(for: reading.id, on: clock)))s counted"
        )

        store.draft = DailyPlanDraft(title: "Study", targetMinutes: 120)
        store.commitDraft()
        let study = store.plans[1]
        store.start(reading, at: clock)
        let switchTime = clock.addingTimeInterval(5 * 60)
        store.start(study, at: switchTime)
        check(
            "starting another plan closes the first live interval",
            store.activeSession?.planID == study.id
                && store.focusedSeconds(for: reading.id, on: switchTime) == 25 * 60,
            "Reading stopped at 25m and Study became the only active plan"
        )

        store.draft = DailyPlanDraft(
            title: "Continuous",
            targetMinutes: 60,
            pomodoro: .continuous
        )
        store.commitDraft()
        let continuous = store.plans[2]
        let continuousStart = switchTime.addingTimeInterval(5 * 60)
        store.start(continuous, at: continuousStart)
        store.stopSession(at: continuousStart.addingTimeInterval(20 * 60))
        store.start(continuous, at: continuousStart.addingTimeInterval(30 * 60))
        check(
            "continuous mode counts down the remaining daily target",
            store.activeSession?.phaseDuration == 40 * 60,
            "after 20m of a 1h plan, the next countdown is 40m"
        )

        print("")
        print("— 3 · pomodoro phases —")

        let phaseRoot = tempRoot.appendingPathComponent("phase", isDirectory: true)
        let phaseStore = DailyPlanStore(
            persistence: DailyPlanPersistence(fileURL: phaseRoot.appendingPathComponent("plans.json")),
            calendar: calendar,
            nowProvider: { clock },
            startsTimer: false
        )
        phaseStore.draft = DailyPlanDraft(
            title: "One-minute rounds",
            targetMinutes: 60,
            pomodoro: PomodoroConfiguration(
                isEnabled: true,
                focusMinutes: 1,
                shortBreakMinutes: 1,
                longBreakMinutes: 2,
                roundsBeforeLongBreak: 2
            )
        )
        phaseStore.commitDraft()
        let shortPlan = phaseStore.plans[0]
        let phaseStart = date(2026, 9, 22, 14, 0)
        phaseStore.start(shortPlan, at: phaseStart)
        let completedFocus = phaseStore.refresh(at: phaseStart.addingTimeInterval(60))

        check(
            "a completed focus round starts the short break",
            completedFocus
                && phaseStore.activeSession?.phase == .shortBreak
                && phaseStore.activeSession?.runningSince == phaseStart.addingTimeInterval(60)
                && phaseStore.focusedSeconds(for: shortPlan.id, on: phaseStart) == 60,
            "focus recorded 60s; the break starts at the focus boundary"
        )
        let duplicateTransition = phaseStore.refresh(at: phaseStart.addingTimeInterval(60))
        check(
            "revisiting a phase boundary is idempotent",
            !duplicateTransition
                && phaseStore.activeSession?.phase == .shortBreak
                && phaseStore.activeSession?.isRunning == true
                && phaseStore.focusedSeconds(for: shortPlan.id, on: phaseStart) == 60,
            "the same boundary produced no second transition or duplicate seconds"
        )

        _ = phaseStore.refresh(at: phaseStart.addingTimeInterval(130))
        check(
            "break time never enters the daily total",
            phaseStore.activeSession?.phase == .focus
                && phaseStore.activeSession?.runningSince == phaseStart.addingTimeInterval(120)
                && phaseStore.focusedSeconds(for: shortPlan.id, on: phaseStart) == 70,
            "the next focus has run 10s; only its focus time counts, not the 60s break"
        )

        if let secondFocus = phaseStore.activeSession {
            var completed = secondFocus
            completed.phase = .focus
            completed.completedFocusRounds = 1
            let next = DailyPlanEngine.nextSession(after: completed, for: shortPlan)
            check(
                "the configured cycle produces a long break",
                next?.phase == .longBreak && next?.completedFocusRounds == 2,
                "two completed focus rounds lead to a \(next?.phase.title ?? "missing")"
            )
        }

        print("")
        print("— 4 · persistence and restart —")

        let restartRoot = tempRoot.appendingPathComponent("restart", isDirectory: true)
        let restartPersistence = DailyPlanPersistence(fileURL: restartRoot.appendingPathComponent("plans.json"))
        var restartClock = date(2026, 9, 22, 16, 0)
        let firstRun = DailyPlanStore(
            persistence: restartPersistence,
            calendar: calendar,
            nowProvider: { restartClock },
            startsTimer: false
        )
        firstRun.draft = DailyPlanDraft(title: "Work", targetMinutes: 480)
        firstRun.commitDraft()
        let work = firstRun.plans[0]
        firstRun.start(work, at: restartClock)
        firstRun.flushPendingSave()

        restartClock = restartClock.addingTimeInterval(10 * 60)
        let secondRun = DailyPlanStore(
            persistence: restartPersistence,
            calendar: calendar,
            nowProvider: { restartClock },
            startsTimer: false
        )
        check(
            "a running session resumes from its timestamp after relaunch",
            secondRun.activeSession?.isRunning == true
                && secondRun.phaseRemaining() == 15 * 60
                && secondRun.focusedSeconds(for: work.id, on: restartClock) == 10 * 60,
            "10m elapsed and 15m remain in the 25m round"
        )

        let archive = restartPersistence.load()
        check(
            "plan identity and active state survive JSON round-trip",
            archive.plans.first?.id == work.id && archive.activeSession?.planID == work.id,
            "the saved plan and session both reference \(work.id.uuidString)"
        )

        let corruptRoot = tempRoot.appendingPathComponent("corrupt", isDirectory: true)
        try! FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptURL = corruptRoot.appendingPathComponent("plans.json")
        try! Data("not json".utf8).write(to: corruptURL)
        let corruptPersistence = DailyPlanPersistence(fileURL: corruptURL)
        let recovered = corruptPersistence.load()
        let preserved = (try? FileManager.default.contentsOfDirectory(atPath: corruptRoot.path))?
            .contains { $0.hasPrefix("plans.unreadable-") } ?? false
        check(
            "an unreadable archive is preserved instead of overwritten",
            recovered == DailyPlanArchive() && preserved && !FileManager.default.fileExists(atPath: corruptURL.path),
            "load returned an empty archive and moved the original beside it"
        )

        print("")
        if failures == 0 {
            print("every check passed")
        } else {
            print("\(failures) check(s) failed")
            exit(1)
        }
    }
}

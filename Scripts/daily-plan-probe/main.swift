import Combine
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
        let switchTime = clock.addingTimeInterval(3 * 60)
        store.start(study, at: switchTime)
        check(
            "switching plans pauses the first live interval",
            store.activeSession?.planID == study.id
                && store.activeSession?.isRunning == true
                && store.focusedSeconds(for: reading.id, on: switchTime) == 23 * 60,
            "Reading stopped at 23m and Study became the only active plan"
        )
        let switchedArchive = persistence.load()
        check(
            "a paused phase is persisted per plan",
            switchedArchive.pausedSessions[reading.id]?.phaseElapsed == 23 * 60
                && switchedArchive.pausedSessions[reading.id]?.runningSince == nil,
            "Reading's paused 23m phase survived the archive write"
        )

        let resumeReadingAt = switchTime.addingTimeInterval(5 * 60)
        store.start(reading, at: resumeReadingAt)
        check(
            "switching back resumes the saved phase",
            store.activeSession?.planID == reading.id
                && store.activeSession?.phase == .focus
                && store.activeSession?.phaseElapsed == 23 * 60
                && store.phaseRemaining(at: resumeReadingAt) == 2 * 60,
            "Reading resumed with 23m elapsed and 2m remaining"
        )

        store.draft = DailyPlanDraft(
            title: "Continuous",
            targetMinutes: 60,
            pomodoro: .continuous
        )
        store.commitDraft()
        let continuous = store.plans[2]
        let continuousStart = resumeReadingAt
        store.start(continuous, at: continuousStart)
        store.resetSession(at: continuousStart.addingTimeInterval(20 * 60))
        check(
            "continuous reset keeps a paused countdown for the remaining target",
            store.activeSession?.planID == continuous.id
                && store.activeSession?.isRunning == false
                && store.phaseRemaining() == 40 * 60,
            "after 20m of focus, the selected timer remains available at 40:00"
        )
        store.start(continuous, at: continuousStart.addingTimeInterval(30 * 60))
        check(
            "continuous mode counts down the remaining daily target",
            store.activeSession?.phaseDuration == 40 * 60,
            "after 20m of a 1h plan, the next countdown is 40m"
        )

        let resetReadingAt = continuousStart.addingTimeInterval(40 * 60)
        store.start(reading, at: resetReadingAt)
        let savedReadingElapsed = store.activeSession?.phaseElapsed
        var resetClearedSession = false
        let resetObservation = store.$activeSession.sink { session in
            if session == nil { resetClearedSession = true }
        }
        store.resetSession(at: resetReadingAt)
        resetObservation.cancel()
        check(
            "reset keeps the selected timer available to the floating panel",
            !resetClearedSession
                && store.activeSession?.planID == reading.id
                && store.activeSession?.phase == .focus
                && store.activeSession?.phaseElapsed == 0
                && store.activeSession?.completedFocusRounds == 0
                && store.activeSession?.isRunning == false
                && store.phaseRemaining() == 25 * 60,
            "the countdown returns to 25:00 paused without publishing an empty session"
        )
        check(
            "reset persists the paused timer and preserves daily work",
            persistence.load().activeSession == store.activeSession
                && store.focusedSeconds(for: reading.id, on: resetReadingAt) == 23 * 60
                && persistence.load().pausedSessions[continuous.id]?.phaseElapsed == 10 * 60,
            "Reading's 23m history and Continuous's saved phase remain intact"
        )
        store.start(reading, at: resetReadingAt.addingTimeInterval(1))
        check(
            "manual reset clears only the selected plan's phase",
            savedReadingElapsed == 23 * 60
                && store.activeSession?.planID == reading.id
                && store.activeSession?.phaseElapsed == 0,
            "Reading reset to a fresh focus phase after its saved phase was resumed"
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

        var manualSkipNotifications = 0
        let manualSkipStore = DailyPlanStore(
            persistence: DailyPlanPersistence(
                fileURL: tempRoot.appendingPathComponent("manual-skip/plans.json")
            ),
            calendar: calendar,
            nowProvider: { clock },
            startsTimer: false,
            onPhaseCompleted: { manualSkipNotifications += 1 }
        )
        manualSkipStore.draft = DailyPlanDraft(
            title: "Manual skip",
            targetMinutes: 60,
            pomodoro: PomodoroConfiguration(
                isEnabled: true,
                focusMinutes: 1,
                shortBreakMinutes: 1,
                longBreakMinutes: 2,
                roundsBeforeLongBreak: 2
            )
        )
        manualSkipStore.commitDraft()
        let manualSkipPlan = manualSkipStore.plans[0]
        let manualSkipStart = date(2026, 9, 22, 15, 0)
        manualSkipStore.start(manualSkipPlan, at: manualSkipStart)
        let manualSkipAt = manualSkipStart.addingTimeInterval(12)
        manualSkipStore.finishCurrentPhase(at: manualSkipAt)
        check(
            "skipping a phase emits the completion callback",
            manualSkipNotifications == 1
                && manualSkipStore.activeSession?.phase == .shortBreak
                && manualSkipStore.activeSession?.runningSince == manualSkipAt,
            "manual skip advanced to the break and emitted \(manualSkipNotifications) completion cue"
        )

        let resetBreakAt = manualSkipAt.addingTimeInterval(10)
        manualSkipStore.resetSession(at: resetBreakAt)
        check(
            "reset during a break returns to paused focus without a completion cue",
            manualSkipStore.activeSession?.phase == .focus
                && manualSkipStore.activeSession?.completedFocusRounds == 0
                && manualSkipStore.activeSession?.isRunning == false
                && manualSkipStore.phaseRemaining() == 60
                && manualSkipStore.focusedSeconds(for: manualSkipPlan.id, on: resetBreakAt) == 12
                && manualSkipNotifications == 1,
            "break reset preserves the 12s of focus and returns to the first round"
        )
        manualSkipStore.togglePause(at: resetBreakAt)
        let resetFocusAt = resetBreakAt.addingTimeInterval(15)
        manualSkipStore.resetSession(at: resetFocusAt)
        check(
            "reset settles running focus exactly once and stays paused",
            manualSkipStore.focusedSeconds(for: manualSkipPlan.id, on: resetFocusAt) == 27
                && manualSkipStore.activeSession?.isRunning == false
                && manualSkipStore.phaseRemaining() == 60,
            "the resumed 15s is recorded and the fresh countdown is paused"
        )
        manualSkipStore.resetSession(at: resetFocusAt.addingTimeInterval(30))
        check(
            "repeated reset does not duplicate recorded focus",
            manualSkipStore.focusedSeconds(for: manualSkipPlan.id, on: resetFocusAt) == 27,
            "the paused timer adds no more focus time"
        )
        manualSkipStore.deletePlan(id: manualSkipPlan.id, at: resetFocusAt.addingTimeInterval(30))
        check(
            "deleting the selected plan still clears its timer",
            manualSkipStore.activeSession == nil && manualSkipStore.plans.isEmpty,
            "only reset retains the selected session; deleting the plan ends it"
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

        check(
            "a local backup is written beside the live archive",
            FileManager.default.fileExists(atPath: restartPersistence.backupFileURL.path),
            "backup path = \(restartPersistence.backupFileURL.lastPathComponent)"
        )

        try! FileManager.default.removeItem(at: restartPersistence.fileURL)
        let missingPrimaryPersistence = DailyPlanPersistence(fileURL: restartPersistence.fileURL)
        let recoveredAfterRemoval = missingPrimaryPersistence.load()
        check(
            "a missing primary archive recovers from the local backup",
            recoveredAfterRemoval.plans.first?.id == work.id
                && recoveredAfterRemoval.activeSession?.planID == work.id
                && FileManager.default.fileExists(atPath: restartPersistence.fileURL.path),
            "the plan and active session returned after removing the primary file"
        )

        try! Data("not json".utf8).write(to: restartPersistence.fileURL)
        let corruptPrimaryPersistence = DailyPlanPersistence(fileURL: restartPersistence.fileURL)
        let recoveredAfterCorruption = corruptPrimaryPersistence.load()
        let preservedCorruptPrimary = (try? FileManager.default.contentsOfDirectory(atPath: restartRoot.path))?
            .contains { $0.hasPrefix("plans.unreadable-") } ?? false
        check(
            "a corrupt primary archive recovers without overwriting it",
            recoveredAfterCorruption.plans.first?.id == work.id && preservedCorruptPrimary,
            "the corrupt primary was preserved and the backup became the live archive"
        )

        let historyRoot = tempRoot.appendingPathComponent("deleted-plan-history", isDirectory: true)
        let historyPersistence = DailyPlanPersistence(fileURL: historyRoot.appendingPathComponent("plans.json"))
        var historyClock = date(2026, 9, 23, 9, 0)
        let historyStore = DailyPlanStore(
            persistence: historyPersistence,
            calendar: calendar,
            nowProvider: { historyClock },
            startsTimer: false
        )
        historyStore.draft = DailyPlanDraft(title: "Archived plan", targetMinutes: 60)
        historyStore.commitDraft()
        let archivedPlan = historyStore.plans[0]
        historyStore.start(archivedPlan, at: historyClock)
        historyClock = historyClock.addingTimeInterval(5 * 60)
        historyStore.stopSession(at: historyClock)
        historyStore.deletePlan(id: archivedPlan.id, at: historyClock)
        let reloadedHistory = DailyPlanStore(
            persistence: DailyPlanPersistence(fileURL: historyPersistence.fileURL),
            calendar: calendar,
            nowProvider: { historyClock },
            startsTimer: false
        )
        check(
            "history survives deleting its plan",
            reloadedHistory.plans.isEmpty
                && reloadedHistory.dayRecords.contains {
                    $0.planID == archivedPlan.id && $0.focusedSeconds == 5 * 60
                },
            "the archived plan is gone but its 5m daily record remains"
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
        print("— 5 · editing daily focus time —")

        let editPersistence = DailyPlanPersistence(fileURL: tempRoot.appendingPathComponent("time-edit/plans.json"))
        var editClock = date(2026, 9, 24, 10, 0)
        let editPlan = DailyPlan(title: "Reading", targetMinutes: 60)
        let otherPlan = DailyPlan(title: "Writing", targetMinutes: 60)
        let deletedID = UUID()
        let yesterday = date(2026, 9, 23, 10, 0)
        let yesterdayKey = PlanDayKey(date: yesterday, calendar: calendar)
        try! editPersistence.save(DailyPlanArchive(
            plans: [editPlan, otherPlan],
            dayRecords: [
                DailyPlanDayRecord(planID: deletedID, day: yesterdayKey, focusedSeconds: 620),
                DailyPlanDayRecord(planID: otherPlan.id, day: yesterdayKey, focusedSeconds: 37)
            ]
        ))
        let editStore = DailyPlanStore(
            persistence: editPersistence, calendar: calendar,
            nowProvider: { editClock }, startsTimer: false
        )
        func setMinutes(_ minutes: Int, for id: UUID) {
            let index = editStore.timeDraft!.entries.firstIndex { $0.id == id }!
            editStore.timeDraft!.entries[index].minutes = minutes
        }

        editStore.beginEditingTime(on: yesterday)
        setMinutes(30, for: deletedID)
        editStore.commitTimeDraft()
        check(
            "history edits preserve other plans' exact seconds",
            editStore.focusedSeconds(for: deletedID, on: yesterday) == 1_800
                && editStore.focusedSeconds(for: otherPlan.id, on: yesterday) == 37
                && editStore.timeDraft == nil,
            "archived plan = 30m; untouched Writing = 37s"
        )
        editStore.beginEditingTime(on: yesterday)
        setMinutes(0, for: otherPlan.id)
        editStore.commitTimeDraft()
        check(
            "an explicitly edited sub-minute record can be cleared",
            editStore.focusedSeconds(for: otherPlan.id, on: yesterday) == 0,
            "37s became zero without affecting the archived plan"
        )

        editStore.start(editPlan, at: editClock)
        editClock = editClock.addingTimeInterval(5 * 60)
        editStore.beginEditingTime(on: editClock)
        let unchangedDraft = editStore.timeDraft
        let draftIndex = unchangedDraft!.entries.firstIndex { $0.id == editPlan.id }!
        check(
            "the editor includes live focus and rejects an unchanged save",
            unchangedDraft!.entries[draftIndex].originalSeconds == 300
                && unchangedDraft?.canCommit == false,
            "the running five minutes appear in the initial draft"
        )
        setMinutes(30, for: editPlan.id)
        editClock = editClock.addingTimeInterval(60)
        let countdownBefore = editStore.activeSession!.remaining(at: editClock)
        editStore.commitTimeDraft()
        check(
            "editing a running day replaces the total without resetting its countdown",
            editStore.focusedSeconds(for: editPlan.id, on: editClock) == 1_800
                && editStore.phaseRemaining() == countdownBefore
                && editStore.activeSession?.isRunning == true,
            "total = 30m at save, while the focus round still has 19m remaining"
        )
        editClock = editClock.addingTimeInterval(60)
        _ = editStore.refresh(at: editClock)
        check(
            "focus continues exactly once after a correction",
            editStore.todayFocusedSeconds == 31 * 60
                && editStore.progress(for: editPlan) == 31.0 / 60.0,
            "one more minute produces 31m and the matching plan progress"
        )

        editStore.beginEditingTime(on: yesterday)
        setMinutes(45, for: deletedID)
        editClock = editClock.addingTimeInterval(60)
        editStore.commitTimeDraft()
        check(
            "editing history leaves the running day's work intact",
            editStore.focusedSeconds(on: yesterday) == 45 * 60
                && editStore.todayFocusedSeconds == 32 * 60,
            "yesterday = 45m, today = 32m, with no cross-day duplication"
        )

        editStore.beginEditingTime(on: editClock)
        setMinutes(10, for: editPlan.id)
        editStore.cancelEditingTime()
        check(
            "cancelling discards only the draft",
            editStore.timeDraft == nil && editStore.todayFocusedSeconds == 32 * 60,
            "the stored 32m and running session are unchanged"
        )
        editStore.beginEditingTime(on: editClock.addingTimeInterval(86_400))
        check("future days cannot be edited", editStore.timeDraft == nil, "no draft was opened")

        editStore.beginEditingTime(on: editClock)
        setMinutes(24 * 60, for: otherPlan.id)
        editStore.commitTimeDraft()
        check(
            "over-24-hour totals cannot be saved",
            editStore.timeDraft?.canCommit == false
                && editStore.focusedSeconds(for: otherPlan.id, on: editClock) == 0,
            "the invalid draft stays open and records are unchanged"
        )
        editStore.cancelEditingTime()
        editStore.togglePause(at: editClock)
        let pausedSession = editStore.activeSession
        editStore.beginEditingTime(on: editClock)
        setMinutes(0, for: editPlan.id)
        setMinutes(15, for: DailyPlanTimeDraft.unassignedPlanID)
        editStore.commitTimeDraft()
        check(
            "clearing a plan and logging other focus preserve the paused timer",
            editStore.activeSession == pausedSession
                && editStore.focusedSeconds(for: editPlan.id, on: editClock) == 0
                && editStore.todayFocusedSeconds == 15 * 60,
            "Reading = 0m; Other focus = 15m; the paused round is untouched"
        )
        let editReload = DailyPlanStore(
            persistence: DailyPlanPersistence(fileURL: editPersistence.fileURL), calendar: calendar,
            nowProvider: { editClock }, startsTimer: false
        )
        check(
            "corrected history and today's totals survive relaunch",
            editReload.focusedSeconds(on: yesterday) == 45 * 60
                && editReload.todayFocusedSeconds == 15 * 60
                && editReload.activeSession == pausedSession,
            "the archive restores corrected records and the original paused round"
        )

        // A file used as the parent directory reliably prevents writes without
        // permissions changes and without touching the user's data.
        let blockedParent = tempRoot.appendingPathComponent("blocked-edit")
        try! Data("not a folder".utf8).write(to: blockedParent)
        let blockedStore = DailyPlanStore(
            persistence: DailyPlanPersistence(fileURL: blockedParent.appendingPathComponent("plans.json")),
            calendar: calendar, nowProvider: { editClock }, startsTimer: false
        )
        blockedStore.beginEditingTime(on: editClock)
        blockedStore.timeDraft!.entries[0].minutes = 20
        blockedStore.commitTimeDraft()
        check(
            "a failed save keeps the draft and rolls back the correction",
            blockedStore.timeDraft != nil && blockedStore.lastError != nil
                && blockedStore.todayFocusedSeconds == 0,
            "the correction is not presented as saved; the draft can be retried"
        )

        var rolloverClock = date(2026, 9, 24, 23, 55)
        let rolloverStore = DailyPlanStore(
            persistence: DailyPlanPersistence(fileURL: tempRoot.appendingPathComponent("edit-midnight/plans.json")),
            calendar: calendar, nowProvider: { rolloverClock }, startsTimer: false
        )
        rolloverStore.draft = DailyPlanDraft(title: "Late reading", targetMinutes: 60)
        rolloverStore.commitDraft()
        let latePlan = rolloverStore.plans[0]
        rolloverStore.start(latePlan, at: rolloverClock)
        rolloverClock = rolloverClock.addingTimeInterval(4 * 60)
        let editedDay = rolloverClock
        rolloverStore.beginEditingTime(on: editedDay)
        rolloverStore.timeDraft!.entries[0].minutes = 20
        rolloverClock = rolloverClock.addingTimeInterval(2 * 60)
        rolloverStore.commitTimeDraft()
        rolloverClock = rolloverClock.addingTimeInterval(60)
        _ = rolloverStore.refresh(at: rolloverClock)
        check(
            "a draft saved across midnight corrects only its original day",
            rolloverStore.focusedSeconds(on: editedDay) == 20 * 60
                && rolloverStore.todayFocusedSeconds == 60
                && rolloverStore.activeSession?.isRunning == true,
            "yesterday = 20m; the new day's restarted session adds only its own minute"
        )
        rolloverStore.deletePlan(id: latePlan.id, at: rolloverClock)
        check(
            "today's summary includes work from deleted plans",
            rolloverStore.todayFocusedSeconds == rolloverStore.focusedSeconds(on: rolloverClock)
                && rolloverStore.todayFocusedSeconds == 60,
            "today and history share the same retained daily total"
        )

        // Editing while a break is running changes only recorded focus.
        editStore.beginEditing(editPlan)
        editStore.draft.pomodoro.focusMinutes = 1
        editStore.commitDraft()
        editStore.resetSession(at: editClock)
        editStore.togglePause(at: editClock)
        editClock = editClock.addingTimeInterval(60)
        _ = editStore.refresh(at: editClock)
        editStore.beginEditingTime(on: editClock)
        setMinutes(20, for: editPlan.id)
        editClock = editClock.addingTimeInterval(10)
        editStore.commitTimeDraft()
        check(
            "editing during a break preserves the break and excludes its time",
            editStore.activeSession?.phase == .shortBreak
                && editStore.phaseRemaining() == 5 * 60 - 10
                && editStore.focusedSeconds(for: editPlan.id, on: editClock) == 20 * 60,
            "the corrected focus is 20m and the short break has 4m50s left"
        )

        var continuousClock = date(2026, 9, 26, 10, 0)
        let continuousEditStore = DailyPlanStore(
            persistence: DailyPlanPersistence(fileURL: tempRoot.appendingPathComponent("edit-continuous/plans.json")),
            calendar: calendar, nowProvider: { continuousClock }, startsTimer: false
        )
        continuousEditStore.draft = DailyPlanDraft(title: "Continuous", targetMinutes: 60, pomodoro: .continuous)
        continuousEditStore.commitDraft()
        let continuousEditPlan = continuousEditStore.plans[0]
        continuousEditStore.draft = DailyPlanDraft(title: "Another plan", targetMinutes: 60)
        continuousEditStore.commitDraft()
        continuousEditStore.start(continuousEditPlan, at: continuousClock)
        continuousClock = continuousClock.addingTimeInterval(10 * 60)
        continuousEditStore.start(continuousEditStore.plans[1], at: continuousClock)
        continuousEditStore.beginEditingTime(on: continuousClock)
        continuousEditStore.timeDraft!.entries[0].minutes = 50
        continuousEditStore.commitTimeDraft()
        continuousEditStore.start(continuousEditPlan, at: continuousClock)
        check(
            "a corrected continuous plan resumes with its new remaining target",
            continuousEditStore.phaseRemaining() == 10 * 60
                && continuousEditStore.activeSession?.isRunning == true,
            "the previously paused 60m plan resumes at 10m after correcting its total to 50m"
        )
        continuousEditStore.beginEditingTime(on: continuousClock)
        continuousEditStore.timeDraft!.entries[0].minutes = 40
        continuousEditStore.commitTimeDraft()
        check(
            "reducing continuous focus extends the running countdown",
            continuousEditStore.phaseRemaining() == 20 * 60
                && continuousEditStore.todayFocusedSeconds == 40 * 60,
            "correcting focus from 50m to 40m leaves 20m to the target"
        )
        continuousEditStore.beginEditingTime(on: continuousClock)
        continuousEditStore.timeDraft!.entries[0].minutes = 60
        continuousEditStore.commitTimeDraft()
        check(
            "reaching a continuous target through correction finishes the timer",
            continuousEditStore.activeSession == nil
                && continuousEditStore.progress(for: continuousEditPlan) == 1,
            "the daily target is complete and no obsolete countdown remains"
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

import Combine
import Foundation

@MainActor
final class DailyPlanStore: NSObject, ObservableObject {
    @Published private(set) var plans: [DailyPlan]
    @Published private(set) var dayRecords: [DailyPlanDayRecord]
    @Published private(set) var activeSession: FocusSession?
    @Published private(set) var now: Date
    @Published private(set) var lastError: String?

    @Published var isEditorPresented = false
    @Published var editingPlanID: UUID?
    @Published var draft = DailyPlanDraft()

    private let persistence: DailyPlanPersistence
    private var calendar: Calendar
    private let nowProvider: () -> Date
    private let onPhaseCompleted: () -> Void
    private var pausedSessions: [UUID: FocusSession]
    private var timer: Timer?

    init(
        persistence: DailyPlanPersistence = DailyPlanPersistence(),
        calendar: Calendar = .autoupdatingCurrent,
        nowProvider: @escaping () -> Date = Date.init,
        startsTimer: Bool = true,
        onPhaseCompleted: @escaping () -> Void = {}
    ) {
        let archive = persistence.load()
        self.persistence = persistence
        self.calendar = calendar
        self.nowProvider = nowProvider
        self.onPhaseCompleted = onPhaseCompleted
        plans = archive.plans
        dayRecords = archive.dayRecords
        activeSession = archive.activeSession
        pausedSessions = archive.pausedSessions
        now = nowProvider()
        lastError = persistence.loadErrorDescription
        super.init()

        normalizeLoadedState()
        _ = reconcile(at: now, notifies: false)
        if startsTimer {
            startTimer()
        }
    }

    var activePlan: DailyPlan? {
        guard let planID = activeSession?.planID else { return nil }
        return plans.first { $0.id == planID }
    }

    var plansForToday: [DailyPlan] {
        let weekday = calendar.component(.weekday, from: now)
        guard let day = DailyPlanWeekday(rawValue: weekday) else { return plans }
        return plans.filter {
            $0.activeWeekdays.contains(day)
                || $0.id == activeSession?.planID
                || focusedSeconds(for: $0.id, on: now) > 0
        }
    }

    var todayTargetSeconds: TimeInterval {
        plansForToday.reduce(0) { $0 + TimeInterval($1.targetMinutes * 60) }
    }

    var todayFocusedSeconds: TimeInterval {
        plans.reduce(0) { $0 + focusedSeconds(for: $1.id, on: now) }
    }

    func isScheduledToday(_ plan: DailyPlan) -> Bool {
        let weekday = calendar.component(.weekday, from: now)
        guard let day = DailyPlanWeekday(rawValue: weekday) else { return true }
        return plan.activeWeekdays.contains(day)
    }

    func focusedSeconds(for planID: UUID, on date: Date) -> TimeInterval {
        let day = PlanDayKey(date: date, calendar: calendar)
        let recorded = dayRecords.first {
            $0.planID == planID && $0.day == day
        }?.focusedSeconds ?? 0
        return recorded + liveFocusedSeconds(for: planID, dayContaining: date)
    }

    func focusedSeconds(on date: Date) -> TimeInterval {
        let day = PlanDayKey(date: date, calendar: calendar)
        let recorded = dayRecords
            .filter { $0.day == day }
            .reduce(0) { $0 + $1.focusedSeconds }
        let live = activeSession.map {
            liveFocusedSeconds(for: $0.planID, dayContaining: date)
        } ?? 0
        return recorded + live
    }

    func progress(for plan: DailyPlan, on date: Date? = nil) -> Double {
        let date = date ?? now
        let target = TimeInterval(plan.targetMinutes * 60)
        guard target > 0 else { return 0 }
        return focusedSeconds(for: plan.id, on: date) / target
    }

    func phaseElapsed(at date: Date? = nil) -> TimeInterval {
        activeSession?.elapsed(at: date ?? now) ?? 0
    }

    func phaseRemaining(at date: Date? = nil) -> TimeInterval {
        activeSession?.remaining(at: date ?? now) ?? 0
    }

    func start(_ plan: DailyPlan, at date: Date? = nil) {
        let date = date ?? nowProvider()
        now = date
        _ = reconcile(at: date, notifies: true)

        if var session = activeSession, session.planID == plan.id {
            guard !session.isRunning else { return }
            session.runningSince = date
            activeSession = session
            save()
            return
        }

        pauseActiveSession(at: date)

        if var session = pausedSessions.removeValue(forKey: plan.id) {
            session.runningSince = date
            activeSession = session
        } else {
            activeSession = FocusSession(
                planID: plan.id,
                phase: .focus,
                phaseDuration: startingFocusDuration(for: plan, on: date),
                phaseElapsed: 0,
                runningSince: date,
                completedFocusRounds: 0
            )
        }
        save()
    }

    func togglePause(at date: Date? = nil) {
        let date = date ?? nowProvider()
        now = date
        _ = reconcile(at: date, notifies: true)
        guard var session = activeSession else { return }

        if session.isRunning {
            settleRunningInterval(at: date)
        } else {
            session.runningSince = date
            activeSession = session
        }
        save()
    }

    func finishCurrentPhase(at date: Date? = nil) {
        let date = date ?? nowProvider()
        now = date
        guard let session = activeSession,
              let plan = plans.first(where: { $0.id == session.planID }) else { return }

        settleRunningInterval(at: date)
        guard let settled = activeSession else { return }
        activeSession = DailyPlanEngine.nextSession(after: settled, for: plan, startingAt: date)
        save()
        onPhaseCompleted()
    }

    func stopSession(at date: Date? = nil) {
        let date = date ?? nowProvider()
        now = date
        settleRunningInterval(at: date)
        if let planID = activeSession?.planID {
            pausedSessions.removeValue(forKey: planID)
        }
        activeSession = nil
        save()
    }

    func beginCreatingPlan() {
        editingPlanID = nil
        draft = DailyPlanDraft()
        isEditorPresented = true
    }

    func beginEditing(_ plan: DailyPlan) {
        editingPlanID = plan.id
        draft = DailyPlanDraft(
            title: plan.title,
            targetMinutes: plan.targetMinutes,
            activeWeekdays: plan.activeWeekdays,
            pomodoro: plan.pomodoro
        )
        isEditorPresented = true
    }

    func cancelEditing() {
        isEditorPresented = false
        editingPlanID = nil
        draft = DailyPlanDraft()
    }

    func commitDraft() {
        guard draft.canCommit else { return }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let editingPlanID,
           let index = plans.firstIndex(where: { $0.id == editingPlanID }) {
            let existing = plans[index]
            plans[index] = DailyPlan(
                id: existing.id,
                title: title,
                targetMinutes: draft.targetMinutes,
                activeWeekdays: draft.activeWeekdays,
                pomodoro: draft.pomodoro,
                createdAt: existing.createdAt
            )
            refreshActiveSessionConfiguration(for: plans[index])
            refreshPausedSessionConfiguration(for: plans[index])
        } else {
            plans.append(
                DailyPlan(
                    title: title,
                    targetMinutes: draft.targetMinutes,
                    activeWeekdays: draft.activeWeekdays,
                    pomodoro: draft.pomodoro
                )
            )
        }

        cancelEditing()
        save()
    }

    func deleteEditingPlan(at date: Date? = nil) {
        guard let editingPlanID else { return }
        deletePlan(id: editingPlanID, at: date)
        cancelEditing()
    }

    func deletePlan(id: UUID, at date: Date? = nil) {
        if activeSession?.planID == id {
            stopSession(at: date)
        }
        pausedSessions.removeValue(forKey: id)
        plans.removeAll { $0.id == id }
        dayRecords.removeAll { $0.planID == id }
        save()
    }

    func flushPendingSave() {
        save()
    }

    /// Public to the standalone probe: production calls it from the one-second timer.
    @discardableResult
    func refresh(at date: Date) -> Bool {
        now = date
        return reconcile(at: date, notifies: true)
    }

    private func startTimer() {
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func timerFired() {
        now = nowProvider()
        _ = reconcile(at: now, notifies: true)
    }

    @discardableResult
    private func reconcile(at date: Date, notifies: Bool) -> Bool {
        var didTransition = false
        var shouldNotify = false

        while let session = activeSession,
              session.isRunning,
              session.remaining(at: date) <= 0.001,
              let plan = plans.first(where: { $0.id == session.planID }),
              let runningSince = session.runningSince {
            let unelapsed = max(session.phaseDuration - session.phaseElapsed, 0)
            let exactEnd = runningSince.addingTimeInterval(unelapsed)
            settleRunningInterval(at: exactEnd)
            guard let completed = activeSession else { break }

            activeSession = DailyPlanEngine.nextSession(
                after: completed,
                for: plan,
                startingAt: exactEnd
            )
            didTransition = true
            shouldNotify = shouldNotify || date.timeIntervalSince(exactEnd) <= 2
        }

        guard didTransition else { return false }
        save()
        if notifies && shouldNotify { onPhaseCompleted() }
        return true
    }

    private func settleRunningInterval(at date: Date) {
        guard var session = activeSession, let startedAt = session.runningSince else { return }

        let available = max(session.phaseDuration - session.phaseElapsed, 0)
        let elapsed = min(max(date.timeIntervalSince(startedAt), 0), available)
        let end = startedAt.addingTimeInterval(elapsed)

        if session.phase == .focus, elapsed > 0 {
            addFocusedInterval(planID: session.planID, from: startedAt, to: end)
        }

        session.phaseElapsed = min(session.phaseElapsed + elapsed, session.phaseDuration)
        session.runningSince = nil
        activeSession = session
    }

    private func pauseActiveSession(at date: Date) {
        settleRunningInterval(at: date)
        guard let session = activeSession else { return }
        pausedSessions[session.planID] = session
        activeSession = nil
    }

    private func addFocusedInterval(planID: UUID, from start: Date, to end: Date) {
        for (day, seconds) in DailyPlanEngine.splitFocusInterval(from: start, to: end, calendar: calendar) {
            if let index = dayRecords.firstIndex(where: { $0.planID == planID && $0.day == day }) {
                dayRecords[index].focusedSeconds += seconds
            } else {
                dayRecords.append(
                    DailyPlanDayRecord(planID: planID, day: day, focusedSeconds: seconds)
                )
            }
        }
    }

    /// `date` selects the local day being queried; the interval itself ends at
    /// the store's live clock (`now`), so a session spanning midnight can report
    /// both yesterday and today without pretending either day is the current time.
    private func liveFocusedSeconds(for planID: UUID, dayContaining date: Date) -> TimeInterval {
        guard let session = activeSession,
              session.planID == planID,
              session.phase == .focus,
              let startedAt = session.runningSince else { return 0 }

        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        let available = max(session.phaseDuration - session.phaseElapsed, 0)
        let sessionEnd = min(now, startedAt.addingTimeInterval(available))
        let overlapStart = max(startedAt, dayStart)
        let overlapEnd = min(sessionEnd, dayEnd)
        return max(overlapEnd.timeIntervalSince(overlapStart), 0)
    }

    private func refreshActiveSessionConfiguration(for plan: DailyPlan) {
        guard var session = activeSession, session.planID == plan.id, !session.isRunning else { return }
        session.phaseDuration = max(
            DailyPlanEngine.phaseDuration(for: plan, phase: session.phase),
            session.phaseElapsed
        )
        activeSession = session
    }

    private func refreshPausedSessionConfiguration(for plan: DailyPlan) {
        guard var session = pausedSessions[plan.id] else { return }
        session.phaseDuration = max(
            DailyPlanEngine.phaseDuration(for: plan, phase: session.phase),
            session.phaseElapsed
        )
        pausedSessions[plan.id] = session
    }

    private func startingFocusDuration(for plan: DailyPlan, on date: Date) -> TimeInterval {
        guard !plan.pomodoro.isEnabled else {
            return DailyPlanEngine.phaseDuration(for: plan, phase: .focus)
        }

        let target = TimeInterval(plan.targetMinutes * 60)
        let remaining = target - focusedSeconds(for: plan.id, on: date)
        return remaining > 0 ? remaining : target
    }

    private func normalizeLoadedState() {
        var seen = Set<UUID>()
        plans = plans.compactMap { plan in
            guard seen.insert(plan.id).inserted else { return nil }
            let title = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return DailyPlan(
                id: plan.id,
                title: title,
                targetMinutes: plan.targetMinutes,
                activeWeekdays: plan.activeWeekdays,
                pomodoro: plan.pomodoro,
                createdAt: plan.createdAt
            )
        }

        let validIDs = Set(plans.map(\.id))
        dayRecords = dayRecords.filter {
            validIDs.contains($0.planID) && $0.focusedSeconds.isFinite && $0.focusedSeconds >= 0
        }
        pausedSessions = pausedSessions.compactMapValues { session in
            guard validIDs.contains(session.planID),
                  session.runningSince == nil,
                  session.phaseDuration.isFinite,
                  session.phaseDuration > 0,
                  session.phaseElapsed.isFinite,
                  session.phaseElapsed >= 0,
                  session.phaseElapsed <= session.phaseDuration else { return nil }
            return session
        }
        if let session = activeSession,
           !validIDs.contains(session.planID)
            || !session.phaseDuration.isFinite
            || session.phaseDuration <= 0
            || !session.phaseElapsed.isFinite
            || session.phaseElapsed < 0 {
            activeSession = nil
        }
        if let activePlanID = activeSession?.planID {
            pausedSessions.removeValue(forKey: activePlanID)
        }
    }

    private func save() {
        do {
            try persistence.save(
                DailyPlanArchive(
                    plans: plans,
                    dayRecords: dayRecords,
                    activeSession: activeSession,
                    pausedSessions: pausedSessions
                )
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

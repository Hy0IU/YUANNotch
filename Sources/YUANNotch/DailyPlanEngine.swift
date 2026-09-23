import Foundation

enum DailyPlanEngine {
    static func splitFocusInterval(
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> [PlanDayKey: TimeInterval] {
        guard end > start else { return [:] }

        var result: [PlanDayKey: TimeInterval] = [:]
        var cursor = start

        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let sliceEnd = min(end, nextDay)
            let key = PlanDayKey(date: cursor, calendar: calendar)
            result[key, default: 0] += sliceEnd.timeIntervalSince(cursor)
            cursor = sliceEnd
        }

        return result
    }

    static func phaseDuration(for plan: DailyPlan, phase: FocusPhase) -> TimeInterval {
        let configuration = plan.pomodoro.normalized
        switch phase {
        case .focus:
            let minutes = configuration.isEnabled ? configuration.focusMinutes : plan.targetMinutes
            return TimeInterval(minutes * 60)
        case .shortBreak:
            return TimeInterval(configuration.shortBreakMinutes * 60)
        case .longBreak:
            return TimeInterval(configuration.longBreakMinutes * 60)
        }
    }

    static func nextSession(
        after completed: FocusSession,
        for plan: DailyPlan,
        startingAt date: Date? = nil
    ) -> FocusSession? {
        let configuration = plan.pomodoro.normalized
        guard configuration.isEnabled else { return nil }

        let nextPhase: FocusPhase
        var completedRounds = completed.completedFocusRounds

        switch completed.phase {
        case .focus:
            completedRounds += 1
            nextPhase = completedRounds.isMultiple(of: configuration.roundsBeforeLongBreak)
                ? .longBreak
                : .shortBreak
        case .shortBreak, .longBreak:
            nextPhase = .focus
        }

        return FocusSession(
            planID: completed.planID,
            phase: nextPhase,
            phaseDuration: phaseDuration(for: plan, phase: nextPhase),
            phaseElapsed: 0,
            runningSince: date,
            completedFocusRounds: completedRounds
        )
    }
}

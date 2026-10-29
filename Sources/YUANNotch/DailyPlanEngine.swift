import Foundation

enum DailyPlanEngine {
    /// A plan day is labelled by the date on which its local 04:00 boundary falls.
    static func dayStart(on date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 4, minute: 0, second: 0, of: date)!
    }

    static func dayStart(containing date: Date, calendar: Calendar) -> Date {
        let boundary = dayStart(on: date, calendar: calendar)
        if date >= boundary { return boundary }
        let previousDate = calendar.date(byAdding: .day, value: -1, to: date)!
        return dayStart(on: previousDate, calendar: calendar)
    }

    static func splitFocusInterval(
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> [PlanDayKey: TimeInterval] {
        guard end > start else { return [:] }

        var result: [PlanDayKey: TimeInterval] = [:]
        var cursor = start

        while cursor < end {
            let dayStart = dayStart(containing: cursor, calendar: calendar)
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let nextDay = self.dayStart(on: nextDate, calendar: calendar)
            let sliceEnd = min(end, nextDay)
            let key = PlanDayKey(date: dayStart, calendar: calendar)
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
            completedFocusRounds: completedRounds,
            sessionDay: completed.sessionDay
        )
    }
}

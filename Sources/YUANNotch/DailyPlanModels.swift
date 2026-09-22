import Foundation

enum DailyPlanWeekday: Int, Codable, CaseIterable, Hashable, Identifiable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: Int { rawValue }

    var shortTitle: String {
        switch self {
        case .sunday: return "S"
        case .monday: return "M"
        case .tuesday: return "T"
        case .wednesday: return "W"
        case .thursday: return "T"
        case .friday: return "F"
        case .saturday: return "S"
        }
    }
}

struct PomodoroConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var focusMinutes: Int
    var shortBreakMinutes: Int
    var longBreakMinutes: Int
    var roundsBeforeLongBreak: Int

    static let standard = PomodoroConfiguration(
        isEnabled: true,
        focusMinutes: 25,
        shortBreakMinutes: 5,
        longBreakMinutes: 15,
        roundsBeforeLongBreak: 4
    )

    static let continuous = PomodoroConfiguration(
        isEnabled: false,
        focusMinutes: 25,
        shortBreakMinutes: 5,
        longBreakMinutes: 15,
        roundsBeforeLongBreak: 4
    )

    var normalized: PomodoroConfiguration {
        PomodoroConfiguration(
            isEnabled: isEnabled,
            focusMinutes: min(max(focusMinutes, 1), 180),
            shortBreakMinutes: min(max(shortBreakMinutes, 1), 60),
            longBreakMinutes: min(max(longBreakMinutes, 1), 120),
            roundsBeforeLongBreak: min(max(roundsBeforeLongBreak, 1), 12)
        )
    }
}

struct DailyPlan: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var targetMinutes: Int
    var activeWeekdays: Set<DailyPlanWeekday>
    var pomodoro: PomodoroConfiguration
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        targetMinutes: Int,
        activeWeekdays: Set<DailyPlanWeekday> = Set(DailyPlanWeekday.allCases),
        pomodoro: PomodoroConfiguration = .standard,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.targetMinutes = min(max(targetMinutes, 1), 24 * 60)
        self.activeWeekdays = activeWeekdays.isEmpty ? Set(DailyPlanWeekday.allCases) : activeWeekdays
        self.pomodoro = pomodoro.normalized
        self.createdAt = createdAt
    }
}

enum FocusPhase: String, Codable, Equatable {
    case focus
    case shortBreak
    case longBreak

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }
}

struct FocusSession: Codable, Equatable {
    let planID: UUID
    var phase: FocusPhase
    var phaseDuration: TimeInterval
    var phaseElapsed: TimeInterval
    var runningSince: Date?
    var completedFocusRounds: Int

    var isRunning: Bool { runningSince != nil }

    func elapsed(at date: Date) -> TimeInterval {
        let live = runningSince.map { max(date.timeIntervalSince($0), 0) } ?? 0
        return min(max(phaseElapsed + live, 0), phaseDuration)
    }

    func remaining(at date: Date) -> TimeInterval {
        max(phaseDuration - elapsed(at: date), 0)
    }
}

struct DailyPlanDraft: Equatable {
    var title = ""
    var targetMinutes = 60
    var activeWeekdays = Set(DailyPlanWeekday.allCases)
    var pomodoro = PomodoroConfiguration.standard

    var canCommit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && targetMinutes > 0
            && !activeWeekdays.isEmpty
    }
}

struct PlanDayKey: Codable, Equatable, Hashable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
    }

    static func < (lhs: PlanDayKey, rhs: PlanDayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

struct DailyPlanDayRecord: Codable, Equatable {
    let planID: UUID
    let day: PlanDayKey
    var focusedSeconds: TimeInterval
}

struct DailyPlanArchive: Codable, Equatable {
    var version = 1
    var plans: [DailyPlan] = []
    var dayRecords: [DailyPlanDayRecord] = []
    var activeSession: FocusSession?
}

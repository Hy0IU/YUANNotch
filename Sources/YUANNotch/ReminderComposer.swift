import SwiftUI

/// A time of day with no day attached — the unit the time half speaks in until
/// the date half says which day it belongs to.
struct TimeOfDay: Equatable {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    var dateComponents: DateComponents { DateComponents(hour: hour, minute: minute) }

    /// Read through the system locale, so a 24-hour region renders `21:00` and a
    /// 12-hour one `9:00 PM`. No time anywhere in this panel is written with a
    /// fixed format — the list rows read theirs the same way.
    func formatted(calendar: Calendar = .current) -> String {
        let anchor = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
        return (anchor ?? Date()).formatted(.dateTime.hour().minute())
    }
}

/// The date half, as a shortcut rather than a value.
enum DueDateOption {
    case none
    case today
    case tomorrow
    case thisWeekend
    case nextWeek
    case custom

    var title: String {
        switch self {
        case .none: return "No Date"
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .thisWeekend: return "This Weekend"
        case .nextWeek: return "Next Week"
        case .custom: return "Custom…"
        }
    }
}

/// The time half. `custom` reads its value from the composer; every other case
/// is a fixed clock time.
enum DueTimeOption: CaseIterable, Hashable {
    case none
    case morning9
    case noon12
    case evening18
    case night21
    case custom

    /// The clock time this shortcut stands for, or `nil` for "no time" and for
    /// "custom", which takes its value from the row.
    var preset: TimeOfDay? {
        switch self {
        case .morning9: return TimeOfDay(hour: 9, minute: 0)
        case .noon12: return TimeOfDay(hour: 12, minute: 0)
        case .evening18: return TimeOfDay(hour: 18, minute: 0)
        case .night21: return TimeOfDay(hour: 21, minute: 0)
        case .none, .custom: return nil
        }
    }

    /// The shortcuts that carry a clock time, derived from the cases so a new one
    /// cannot be declared without also being offered in the menu.
    static var presets: [DueTimeOption] { allCases.filter { $0.preset != nil } }

    var title: String {
        switch self {
        case .none: return "No Time"
        case .custom: return "Custom…"
        case .morning9, .noon12, .evening18, .night21: return preset?.formatted() ?? ""
        }
    }
}

/// What the two menus add up to.
///
/// One derivation, read by the button labels and by the write alike: a label
/// computed separately from the value it describes is a label that can lie.
struct DueResolution {
    /// Start of the day the reminder lands on, or `nil` when it carries no due
    /// date at all.
    let day: Date?
    /// The exact moment, or `nil` for a day-level reminder — the shape that
    /// carries a date but no time of day.
    let instant: Date?

    var due: ReminderDue? {
        guard let day else { return nil }
        guard let instant else { return ReminderDue(date: day, isAllDay: true) }
        return ReminderDue(date: instant, isAllDay: false)
    }
}

/// What the two menus hold, and the one rule that combines them.
///
/// | Date | Time | Result |
/// | --- | --- | --- |
/// | none | none | no due date |
/// | any | none | that day, day-level — no alarm |
/// | none | any | today at that time, or tomorrow once the moment has passed |
/// | any | any | that day and time, precise — absolute alarm |
struct DueSelection {
    var date: DueDateOption = .none
    var time: DueTimeOption = .none
    /// Read only when `date` is `.custom`.
    var customDate = Date()
    /// Read only when `time` is `.custom`.
    var customTime = Date()

    func resolution(now: Date, calendar: Calendar = .current) -> DueResolution {
        let today = calendar.startOfDay(for: now)
        let clock = time == .custom ? TimeOfDay(customTime, calendar: calendar) : time.preset

        let chosenDay: Date?
        switch date {
        case .none: chosenDay = nil
        case .today: chosenDay = today
        case .tomorrow: chosenDay = calendar.date(byAdding: .day, value: 1, to: today)
        case .thisWeekend:
            // The weekend already under way counts: on a Saturday or
            // Sunday "this weekend" is today, not the next one.
            chosenDay = calendar.isDateInWeekend(today)
                ? today
                : Self.nextWeekday(Self.saturday, after: today, calendar: calendar)
        case .nextWeek: chosenDay = Self.nextWeekday(Self.monday, after: today, calendar: calendar)
        case .custom: chosenDay = calendar.startOfDay(for: customDate)
        }

        switch (chosenDay, clock) {
        case (nil, nil):
            return DueResolution(day: nil, instant: nil)

        case let (day?, nil):
            return DueResolution(day: day, instant: nil)

        case let (nil, clock?):
            // A time with no date means "today at that time", which becomes
            // tomorrow once the moment has passed — and lands on tomorrow
            // outright when the time belongs to the day after today.
            let todayInstant = calendar.date(byAdding: clock.dateComponents, to: today) ?? today
            let day = todayInstant > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
            let instant = calendar.date(byAdding: clock.dateComponents, to: day) ?? todayInstant
            return DueResolution(day: day, instant: instant)

        case let (day?, clock?):
            let instant = calendar.date(byAdding: clock.dateComponents, to: day) ?? day
            return DueResolution(day: day, instant: instant)
        }
    }

    /// `Calendar`'s weekday numbering, where 1 is Sunday.
    private static let monday = 2
    private static let saturday = 7

    /// The next such weekday strictly after `day`: "next week" is the coming
    /// Monday and is never today. ("This weekend" no longer goes through here —
    /// an under-way weekend is today, see `resolution`.)
    private static func nextWeekday(_ weekday: Int, after day: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(
            after: day,
            matching: DateComponents(hour: 0, minute: 0, weekday: weekday),
            matchingPolicy: .nextTime
        )
    }

    /// An offset from now — "in 15 minutes", "in 1 hour" — expressed in the two
    /// dimensions. A shortcut is not a third state: it resolves to the concrete
    /// day it lands on rather than being carried as "today", so that one taken
    /// just before midnight lands on tomorrow instead of on a moment that has
    /// already passed.
    static func relative(minutes: Int, now: Date, calendar: Calendar = .current) -> DueSelection {
        let target = now.addingTimeInterval(TimeInterval(minutes) * 60)
        // The day is decided against `now`, not against the wall clock:
        // `isDateInTomorrow(target)` answers about today's date on this machine,
        // which made the rule unimplementable against a fixed clock even though it
        // takes one — and wrong for any caller whose `now` is not the system time.
        let landsTomorrow = calendar.startOfDay(for: target) > calendar.startOfDay(for: now)
        return DueSelection(
            date: landsTomorrow ? .tomorrow : .today,
            time: .custom,
            customTime: target
        )
    }
}

/// The reminder the user is composing: the one line of text, the two halves of a
/// due date, and the custom inputs' own values.
///
/// A store rather than view state, because the panel is not the only thing whose
/// lifetime matters here. The drawer swaps the whole reminders surface out for
/// the notes one on every mode switch, and this state used to be `@State` inside
/// the panel: half-typed text and a chosen due date went with the view. Held by
/// `ReminderStore`, it outlives the panel, so the surface can be rebuilt as often
/// as the drawer likes.
///
/// The rules live here too, not just the values. The resolution table, the label
/// each menu shows, the two-way sync between the custom time's field and its
/// wheel, and the order in which a commit empties the row are all things the view
/// could only re-derive — and the one that was re-derived in the view, "the field
/// and the wheel are two views onto one value", is exactly the kind that drifts.
/// So every writer goes through a method here (`setCustomTime`, `setCustomTimeText`),
/// never through a settable property.
@MainActor
final class ReminderComposer: ObservableObject {
    @Published var draft = ""

    @Published private(set) var dateOption: DueDateOption = .none
    @Published private(set) var timeOption: DueTimeOption = .none

    /// One value behind the custom time, written by the text field and by the
    /// wheel alike, so the row can never show two different times. Only the time
    /// of day inside it is ever read; the day it is anchored to is noise.
    @Published private(set) var customTime = Date()
    @Published private(set) var customTimeText = ""
    @Published private(set) var customTimeParseFailed = false
    /// The day the custom date picker shows. Separate from `customTime`: the two
    /// custom inputs are independent, as the date and time menus are.
    @Published private(set) var customDate = Date()
    @Published private(set) var isTimeWheelShown = false

    /// A commit's payload: what to write, with the row already emptied.
    struct PendingReminder: Equatable {
        let title: String
        let due: ReminderDue?
    }

    /// Every change to the due row animates the row's own shape — the custom
    /// inputs appearing, the wheel unrolling. Held here rather than wrapped
    /// around fifteen call sites in the panel, where the same duration was
    /// written out six times.
    private static let rowAnimation = Animation.easeOut(duration: 0.15)

    // MARK: - Derivation

    var canCommit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The custom inputs appear only when a half has actually been set to custom.
    /// A control that is on screen while its value is being ignored is worse than
    /// no control at all.
    var showsCustomRow: Bool {
        dateOption == .custom || timeOption == .custom
    }

    /// The two choices as one value. Held as a value so the rule that combines
    /// them is a pure function of its inputs — "now" among them, which is what
    /// makes the roll past a given time of day checkable against a fixed clock
    /// instead of only against the wall clock.
    func resolution(now: Date = Date()) -> DueResolution {
        DueSelection(
            date: dateOption,
            time: timeOption,
            customDate: customDate,
            customTime: customTime
        )
        .resolution(now: now)
    }

    /// Today and tomorrow are named, anything further out is written as its date
    /// — the same reading the list rows give a day-level due date.
    func dateButtonTitle(now: Date = Date()) -> String {
        guard let day = resolution(now: now).day else { return DueDateOption.none.title }
        return Self.dayLabel(day)
    }

    func timeButtonTitle(now: Date = Date()) -> String {
        guard let instant = resolution(now: now).instant else { return DueTimeOption.none.title }
        return Self.clockText(instant)
    }

    private static func dayLabel(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Choosing

    func select(dateOption option: DueDateOption) {
        // Entering Custom starts from today rather than from whatever was left
        // over last time; picking Custom again keeps the day already chosen.
        if option == .custom, dateOption != .custom {
            customDate = Date()
        }
        withAnimation(Self.rowAnimation) { dateOption = option }
    }

    func select(timeOption option: DueTimeOption) {
        // The wheel belongs to the custom field and does not survive leaving it.
        isTimeWheelShown = false
        if option == .custom, timeOption != .custom {
            setCustomTime(Date())
        }
        withAnimation(Self.rowAnimation) { timeOption = option }
    }

    /// "In 15 Minutes" and "In 1 Hour" are shortcuts, not a state of their own:
    /// the meaning of the offset lives in `DueSelection.relative`, and this only
    /// lays its result onto the row. Both buttons then read the concrete day and
    /// time, and either half can still be adjusted.
    func applyRelative(minutes: Int, now: Date = Date()) {
        let shortcut = DueSelection.relative(minutes: minutes, now: now)
        setCustomTime(shortcut.customTime)
        withAnimation(Self.rowAnimation) {
            dateOption = shortcut.date
            timeOption = shortcut.time
            isTimeWheelShown = false
        }
    }

    func setCustomDate(_ date: Date) {
        customDate = date
    }

    /// Writes the custom time and refreshes the text from it. Called by the
    /// wheel, by the shortcuts and by the reset — every writer goes through here
    /// so the two inputs cannot drift apart.
    func setCustomTime(_ date: Date) {
        customTime = date
        customTimeText = Self.clockText(date)
        customTimeParseFailed = false
    }

    /// The field's only path into the value.
    func setCustomTimeText(_ text: String) {
        customTimeText = text
        guard let clock = Self.parseClockTime(text) else {
            // Deliberately not a rejection: the last value that parsed stays in
            // force, the field only says that what is typed is not being read.
            customTimeParseFailed = !text.isEmpty
            return
        }
        customTimeParseFailed = false
        customTime = Self.date(setting: clock)
    }

    func toggleTimeWheel() {
        withAnimation(Self.rowAnimation) { isTimeWheelShown.toggle() }
    }

    /// Every reminder starts from a blank due row, the way Reminders.app does.
    /// The chip row this replaced carried the previous choice into the next
    /// reminder.
    func resetDueSelection() {
        customDate = Date()
        setCustomTime(Date())
        withAnimation(Self.rowAnimation) {
            dateOption = .none
            timeOption = .none
            isTimeWheelShown = false
        }
    }

    /// Empties the row and hands back what to write, so the panel's commit does
    /// not have to spell the order out — reading the title, reading the due date,
    /// clearing the draft and resetting the row is one sequence, and a second
    /// caller that got it wrong would leave a stale due date on the next
    /// reminder.
    func consume(now: Date = Date()) -> PendingReminder? {
        guard canCommit else { return nil }
        let pending = PendingReminder(title: draft, due: resolution(now: now).due)
        draft = ""
        resetDueSelection()
        return pending
    }

    // MARK: - Parsing

    private static func clockText(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// Anchors a bare clock time to today. The day it lands on is discarded when
    /// the due date is composed, so this is only where the two inputs agree on a
    /// single representation.
    private static func date(setting clock: TimeOfDay, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: Date()) ?? Date()
    }

    private enum DayHalf {
        case am
        case pm
    }

    /// Parses the loose forms a person types into the custom-time field.
    ///
    /// Accepted: `21:00`, `21.00`, `2130`, `930`, `21`, `9`, `9pm`, `9 pm`,
    /// `9:30pm`. Anything else — including an hour or minute out of range —
    /// returns `nil`, which the field shows as a warning rather than as a refusal
    /// to submit.
    static func parseClockTime(_ raw: String) -> TimeOfDay? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        // The meridiem comes off first, so what is left is digits and
        // separators.
        var half: DayHalf?
        for (suffix, value) in [("a.m.", DayHalf.am), ("p.m.", DayHalf.pm), ("am", .am), ("pm", .pm)] {
            guard half == nil, text.hasSuffix(suffix) else { continue }
            half = value
            text.removeLast(suffix.count)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // `9:30`, `9.30` and `9 30` are two fields; `930` and `2130` are one run
        // of digits, split at the hundreds.
        let fields = text.split(whereSeparator: { ":.： ".contains($0) })
        var hour: Int
        var minute: Int
        switch fields.count {
        case 1:
            guard let digits = Int(fields[0]) else { return nil }
            switch fields[0].count {
            case 1, 2:
                hour = digits
                minute = 0
            case 3, 4:
                hour = digits / 100
                minute = digits % 100
            default:
                return nil
            }
        case 2:
            guard let first = Int(fields[0]), let second = Int(fields[1]) else { return nil }
            hour = first
            minute = second
        default:
            return nil
        }

        if let half {
            guard (1...12).contains(hour) else { return nil }
            switch half {
            case .am: hour = hour == 12 ? 0 : hour
            case .pm: hour = hour == 12 ? 12 : hour + 12
            }
        }

        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return TimeOfDay(hour: hour, minute: minute)
    }
}

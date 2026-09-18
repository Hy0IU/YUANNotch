import SwiftUI

/// The drawer's reminders surface: list picker, a one-line compose row, and
/// the grouped list of incomplete reminders for the selected list.
///
/// Completed reminders are never rendered — they are excluded at the query, so
/// there is no "completed" section and no clear-completed affordance.
struct RemindersPanelView: View {
    @ObservedObject var store: ReminderStore
    let size: CGSize
    let onOpenSettings: () -> Void

    @State private var draft = ""

    /// The two halves of a due date, held independently and always both
    /// meaningful.
    ///
    /// They are not one list of intervals because the combinations that matter
    /// are not intervals: "tomorrow" with no time is a day-level reminder,
    /// "tomorrow" at 09:00 is a timed one, and a time with no date is "today at
    /// that time". A single axis can only offer "in fifteen minutes" or a full
    /// date and time, and has no word for the cases in between — which is what
    /// the chip row this replaces could not express.
    @State private var dueDateOption: DueDateOption = .none
    @State private var dueTimeOption: DueTimeOption = .none

    /// One value behind the custom time, written by the text field and by the
    /// wheel alike, so the row can never show two different times. Only the
    /// time of day inside it is ever read; the day it is anchored to is noise.
    @State private var customTime = Date()
    @State private var customTimeText = ""
    @State private var customTimeParseFailed = false
    /// The day the custom date picker shows. Separate from `customTime`: the
    /// two custom inputs are independent, as the date and time menus are.
    @State private var customDate = Date()
    @State private var isTimeWheelShown = false

    @State private var hoveredItemID: String?

    /// Rows currently playing the completion animation, keyed by item id.
    /// Pure presentation state: it drives the tick and the strikethrough until
    /// the row is handed to the store, which removes it from the list.
    @State private var completingItemIDs: Set<String> = []
    private static let completionAnimationDuration: TimeInterval = 0.45

    /// The drawer's surface colour. Shared with the scrim that dims the list
    /// while another list is being read, so the two can never drift apart.
    private static let panelBackground = Color(red: 0.06, green: 0.06, blue: 0.07)

    /// How dark the list goes while it is still showing the previous list's
    /// rows, and how long it takes to get there and back.
    private static let staleScrimOpacity = 0.62
    private static let staleScrimDuration: TimeInterval = 0.15

    /// The dim itself, as a value the view can animate on its own schedule.
    ///
    /// Deliberately not `.animation(_:value:)` on the scrim: that would put the
    /// animation into the same update as the store's commit, and an animated
    /// update plays the row transitions too — which belong to a delete or a
    /// completion, never to a list switch. Driving it from `onChange` lands the
    /// fade in the update *after* the rows have been swapped, so the swap
    /// happens behind a full-strength scrim and the new rows fade up.
    @State private var staleScrim: Double = 0

    @FocusState private var isDraftFocused: Bool

    // MARK: - Due date model

    /// The date half, as a shortcut rather than a value.
    private enum DueDateOption {
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

    /// The time half. `custom` reads its value from the compose row's state;
    /// every other case is a fixed clock time.
    private enum DueTimeOption: CaseIterable, Hashable {
        case none
        case morning9
        case noon12
        case evening18
        case night21
        case custom

        /// The clock time this shortcut stands for, or `nil` for "no time" and
        /// for "custom", which takes its value from the row.
        var preset: TimeOfDay? {
            switch self {
            case .morning9: return TimeOfDay(hour: 9, minute: 0)
            case .noon12: return TimeOfDay(hour: 12, minute: 0)
            case .evening18: return TimeOfDay(hour: 18, minute: 0)
            case .night21: return TimeOfDay(hour: 21, minute: 0)
            case .none, .custom: return nil
            }
        }

        /// The shortcuts that carry a clock time, derived from the cases so a
        /// new one cannot be declared without also being offered in the menu.
        static var presets: [DueTimeOption] { allCases.filter { $0.preset != nil } }

        var title: String {
            switch self {
            case .none: return "No Time"
            case .custom: return "Custom…"
            case .morning9, .noon12, .evening18, .night21: return preset?.formatted() ?? ""
            }
        }
    }

    /// A time of day with no day attached — the unit the time half speaks in
    /// until the date half says which day it belongs to.
    private struct TimeOfDay: Equatable {
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

        /// Read through the system locale, so a 24-hour region renders `21:00`
        /// and a 12-hour one `9:00 PM`. No time anywhere in this panel is
        /// written with a fixed format — the list rows read theirs the same way.
        func formatted(calendar: Calendar = .current) -> String {
            let anchor = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
            return (anchor ?? Date()).formatted(.dateTime.hour().minute())
        }
    }

    /// What the two menus add up to.
    ///
    /// One derivation, read by the button labels and by the write alike: a
    /// label computed separately from the value it describes is a label that
    /// can lie.
    private struct DueResolution {
        /// Start of the day the reminder lands on, or `nil` when it carries no
        /// due date at all.
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
    private struct DueSelection {
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

        /// The next such weekday strictly after `day`: "next week" is the
        /// coming Monday and is never today. ("This weekend" no longer goes
        /// through here — an under-way weekend is today, see `resolution`.)
        private static func nextWeekday(_ weekday: Int, after day: Date, calendar: Calendar) -> Date? {
            calendar.nextDate(
                after: day,
                matching: DateComponents(hour: 0, minute: 0, weekday: weekday),
                matchingPolicy: .nextTime
            )
        }

        /// An offset from now — "in 15 minutes", "in 1 hour" — expressed in the
        /// two dimensions. A shortcut is not a third state: it resolves to the
        /// concrete day it lands on rather than being carried as "today", so
        /// that one taken just before midnight lands on tomorrow instead of on
        /// a moment that has already passed.
        static func relative(minutes: Int, now: Date, calendar: Calendar = .current) -> DueSelection {
            let target = now.addingTimeInterval(TimeInterval(minutes) * 60)
            return DueSelection(
                date: calendar.isDateInTomorrow(target) ? .tomorrow : .today,
                time: .custom,
                customTime: target
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.isEnabled && store.authorization.canRead {
                header
                divider
                compose
                divider
                content
            } else {
                guidance
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Self.panelBackground)
        // The view reports only its visible lifetime. The refresh schedule,
        // interval and trigger set live in ReminderStore, so there is one place
        // to reason about staleness rather than one per surface.
        .task { store.setPanelVisible(true) }
        .onDisappear { store.setPanelVisible(false) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            listPicker

            Spacer(minLength: 8)

            if store.failedWriteCount > 0 {
                Text("\(store.failedWriteCount) not written")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.85))
            }

            Button {
                store.requestRefresh(reloadLists: true, showingProgress: true)
            } label: {
                RefreshGlyph(isSpinning: store.isBusy)
            }
            .buttonStyle(MarkdownToolbarButtonStyle())
            .help("Reload from Reminders")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var listPicker: some View {
        Menu {
            ForEach(store.lists) { list in
                Button {
                    store.select(listID: list.id)
                } label: {
                    if list.id == store.selectedList?.id {
                        Label(listMenuTitle(list), systemImage: "checkmark")
                    } else {
                        Text(listMenuTitle(list))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.selectedList?.title ?? "No list")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if store.selectedListIsLocalOnly {
                    Text("this Mac only")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange.opacity(0.85))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch list")
    }

    private func listMenuTitle(_ list: ReminderList) -> String {
        var parts = [list.title]
        if list.isLocalOnly {
            parts.append("this Mac only")
        } else if !list.sourceTitle.isEmpty {
            parts.append(list.sourceTitle)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Compose

    private var compose: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                draftField
                addButton
            }

            HStack(spacing: 6) {
                dateMenu
                timeMenu
                Spacer(minLength: 0)
            }

            if showsCustomRow {
                customRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var draftField: some View {
        TextField("New reminder", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.9))
            .focused($isDraftFocused)
            .onSubmit(commit)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.045))
            )
    }

    private var addButton: some View {
        Button(action: commit) {
            Text("Add")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 11)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(MarkdownToolbarButtonStyle())
        .disabled(!canCommit)
        .help("Add to Apple Reminders")
    }

    // MARK: - Due date menus

    /// The due-date menu. Its label is read back off the resolution rather than
    /// off the option, so a time chosen with no date names the day it will land
    /// on instead of claiming there is none.
    private var dateMenu: some View {
        Menu {
            menuEntry(DueDateOption.none.title, isSelected: dueDateOption == .none) {
                selectDateOption(.none)
            }
            Divider()
            menuEntry(DueDateOption.today.title, isSelected: dueDateOption == .today) {
                selectDateOption(.today)
            }
            menuEntry(DueDateOption.tomorrow.title, isSelected: dueDateOption == .tomorrow) {
                selectDateOption(.tomorrow)
            }
            menuEntry(DueDateOption.thisWeekend.title, isSelected: dueDateOption == .thisWeekend) {
                selectDateOption(.thisWeekend)
            }
            menuEntry(DueDateOption.nextWeek.title, isSelected: dueDateOption == .nextWeek) {
                selectDateOption(.nextWeek)
            }
            Divider()
            menuEntry(DueDateOption.custom.title, isSelected: dueDateOption == .custom) {
                selectDateOption(.custom)
            }
        } label: {
            menuLabel(symbol: "calendar", title: dateButtonTitle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Due date")
    }

    /// The due-time menu. The relative shortcuts sit here rather than under the
    /// date menu because they are about the time half — they leave the date
    /// half naming the day the offset lands on.
    private var timeMenu: some View {
        Menu {
            menuEntry(DueTimeOption.none.title, isSelected: dueTimeOption == .none) {
                selectTimeOption(.none)
            }
            Divider()
            ForEach(DueTimeOption.presets, id: \.self) { option in
                menuEntry(option.title, isSelected: dueTimeOption == option) {
                    selectTimeOption(option)
                }
            }
            Divider()
            menuEntry("In 15 Minutes", isSelected: false) { applyRelative(minutes: 15) }
            menuEntry("In 1 Hour", isSelected: false) { applyRelative(minutes: 60) }
            Divider()
            menuEntry(DueTimeOption.custom.title, isSelected: dueTimeOption == .custom) {
                selectTimeOption(.custom)
            }
        } label: {
            menuLabel(symbol: "clock", title: timeButtonTitle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Due time")
    }

    /// One menu entry, ticked while it is the active choice. Written out per
    /// entry rather than with `ForEach` because both menus group their entries
    /// with dividers that do not follow the case order.
    @ViewBuilder
    private func menuEntry(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func menuLabel(symbol: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.05))
        )
        .contentShape(Rectangle())
    }

    // MARK: - Due date selection

    private func selectDateOption(_ option: DueDateOption) {
        // Entering Custom starts from today rather than from whatever was left
        // over last time; picking Custom again keeps the day already chosen.
        if option == .custom, dueDateOption != .custom {
            customDate = Date()
        }
        withAnimation(.easeOut(duration: 0.15)) { dueDateOption = option }
    }

    private func selectTimeOption(_ option: DueTimeOption) {
        // The wheel belongs to the custom field and does not survive leaving it.
        isTimeWheelShown = false
        if option == .custom, dueTimeOption != .custom {
            setCustomTime(Date())
        }
        withAnimation(.easeOut(duration: 0.15)) { dueTimeOption = option }
    }

    /// "In 15 Minutes" and "In 1 Hour" are shortcuts, not a state of their own:
    /// the meaning of the offset lives in `DueSelection.relative`, and this only
    /// lays its result onto the row. Both buttons then read the concrete day and
    /// time, and either half can still be adjusted.
    private func applyRelative(minutes: Int) {
        let shortcut = DueSelection.relative(minutes: minutes, now: Date())
        setCustomTime(shortcut.customTime)
        withAnimation(.easeOut(duration: 0.15)) {
            dueDateOption = shortcut.date
            dueTimeOption = shortcut.time
            isTimeWheelShown = false
        }
    }

    // MARK: - Custom date and time

    /// The custom inputs appear only when a half has actually been set to
    /// custom. A control that is on screen while its value is being ignored is
    /// worse than no control at all.
    private var showsCustomRow: Bool {
        dueDateOption == .custom || dueTimeOption == .custom
    }

    private var customRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dueDateOption == .custom {
                HStack(spacing: 6) {
                    rowLabel("Date")
                    DatePicker("", selection: $customDate, displayedComponents: [.date])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .font(.system(size: 12))
                        // The panel paints itself dark regardless of system
                        // appearance. The menus around it draw their own colors,
                        // but the picker's compact style is system chrome — it
                        // needs to be told, or a light-mode Mac gets a light
                        // control on this dark surface.
                        .environment(\.colorScheme, .dark)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
            }

            if dueTimeOption == .custom {
                HStack(spacing: 6) {
                    rowLabel("Time")
                    timeField
                    wheelToggle
                    Spacer(minLength: 0)
                }

                if isTimeWheelShown {
                    DatePicker("", selection: $customTime, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .font(.system(size: 12))
                        .environment(\.colorScheme, .dark)
                        .fixedSize()
                        .padding(.leading, Self.rowLabelWidth + 6)
                        .onChange(of: customTime) { _, _ in syncTimeTextFromWheel() }
                }
            }
        }
    }

    private static let rowLabelWidth: CGFloat = 34

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .frame(width: Self.rowLabelWidth, alignment: .leading)
    }

    private var timeField: some View {
        TextField(TimeOfDay(hour: 21, minute: 0).formatted(), text: $customTimeText)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.9))
            .onSubmit(commit)
            .padding(.horizontal, 7)
            .frame(width: 78, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.orange.opacity(0.8), lineWidth: 1)
                    .opacity(customTimeParseFailed ? 1 : 0)
            )
            .help("Type a time such as 21:00, 9pm or 2130")
            // The field and the wheel are two views onto one value; this is the
            // only path from typed text into that value.
            .onChange(of: customTimeText) { _, _ in applyCustomTimeText() }
    }

    private var wheelToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isTimeWheelShown.toggle() }
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(isTimeWheelShown ? 0.85 : 0.55))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(isTimeWheelShown ? 0.12 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pick the time with the system picker instead")
    }

    /// Writes the custom time and refreshes the text from it. Called by the
    /// wheel, by the shortcuts and by the reset — every writer goes through
    /// here so the two inputs cannot drift apart.
    private func setCustomTime(_ date: Date) {
        customTime = date
        customTimeText = Self.clockText(date)
        customTimeParseFailed = false
    }

    private func applyCustomTimeText() {
        guard let clock = Self.parseClockTime(customTimeText) else {
            // Deliberately not a rejection: the last value that parsed stays in
            // force, the field only says that what is typed is not being read.
            customTimeParseFailed = !customTimeText.isEmpty
            return
        }
        customTimeParseFailed = false
        customTime = Self.date(setting: clock)
    }

    /// Refreshes the text from the wheel. Skipped when the text already means
    /// the same time, which is what stops the two inputs from echoing.
    private func syncTimeTextFromWheel() {
        guard Self.parseClockTime(customTimeText) != TimeOfDay(customTime) else { return }
        customTimeText = Self.clockText(customTime)
        customTimeParseFailed = false
    }

    private static func clockText(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// Anchors a bare clock time to today. The day it lands on is discarded
    /// when the due date is composed, so this is only where the two inputs
    /// agree on a single representation.
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
    /// returns `nil`, which the field shows as a warning rather than as a
    /// refusal to submit.
    private static func parseClockTime(_ raw: String) -> TimeOfDay? {
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

    // MARK: - Derivation

    private var canCommit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The two choices as one value. Held as a value so the rule that combines
    /// them is a pure function of its inputs — "now" among them, which is what
    /// makes the roll past a given time of day checkable against a fixed clock
    /// instead of only against the wall clock.
    private var selection: DueSelection {
        DueSelection(
            date: dueDateOption,
            time: dueTimeOption,
            customDate: customDate,
            customTime: customTime
        )
    }

    private var resolution: DueResolution {
        selection.resolution(now: Date())
    }

    private var dateButtonTitle: String {
        guard let day = resolution.day else { return DueDateOption.none.title }
        return Self.dayLabel(day)
    }

    private var timeButtonTitle: String {
        guard let instant = resolution.instant else { return DueTimeOption.none.title }
        return Self.clockText(instant)
    }

    /// Today and tomorrow are named, anything further out is written as its
    /// date — the same reading the list rows give a day-level due date.
    private static func dayLabel(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    private func commit() {
        guard canCommit else { return }
        let title = draft
        let due = resolution.due

        draft = ""
        resetDueSelection()
        // Keep the caret in the field: several reminders in a row should not
        // need a trip to the mouse between them.
        isDraftFocused = true

        Task { await store.create(title: title, due: due) }
    }

    /// Every reminder starts from a blank due row, the way Reminders.app does.
    /// The chip row this replaces carried the previous choice into the next
    /// reminder.
    private func resetDueSelection() {
        customDate = Date()
        setCustomTime(Date())
        withAnimation(.easeOut(duration: 0.15)) {
            dueDateOption = .none
            dueTimeOption = .none
            isTimeWheelShown = false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            switch store.content {
            case .loading:
                // Nothing has been read for this list yet. A quiet blank beats
                // the "no reminders in this list" this used to show, which
                // asserted emptiness nothing had verified; the header glyph
                // already says the read is in flight.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)

            case .stale, .rows:
                // The previous list's rows stay on screen while the next one is
                // read, and are dimmed rather than cleared. `staleScrim` carries
                // the dim so the rows themselves are never part of an animated
                // update.
                ZStack {
                    listArea.allowsHitTesting(store.content != .stale)
                    Self.panelBackground
                        .opacity(staleScrim)
                        .allowsHitTesting(false)
                }

            case .empty:
                emptyListState
            }

            if let undo = store.pendingUndo {
                undoBar(undo)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let error = store.lastError {
                errorBar(error)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: store.content) { _, newContent in
            withAnimation(.easeInOut(duration: Self.staleScrimDuration)) {
                staleScrim = newContent == .stale ? Self.staleScrimOpacity : 0
            }
        }
    }

    private var listArea: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.groupedItems(), id: \.group) { section in
                    groupHeader(section.group.title)
                    ForEach(section.items) { item in
                        row(for: item)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func groupHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func row(for item: ReminderPanelItem) -> some View {
        let isCompleting = completingItemIDs.contains(item.id)
        return HStack(spacing: 9) {
            Button {
                beginCompletion(of: item)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white.opacity(item.isCompletable ? 0.5 : 0.18), lineWidth: 1)
                    if isCompleting {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.isCompletable)
            .help(item.isCompletable ? "Mark as completed" : "Not written to Reminders yet")

            // A long reminder wraps instead of being cut off with an ellipsis: this
            // row is the only place its text is ever read, and the ellipsis hides
            // exactly the end that tells one long reminder from another. The ideal
            // height is asked for explicitly, or the text is laid out against the
            // row's height and folds back onto one line.
            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(isCompleting ? 0.45 : (item.syncState == .idle ? 0.88 : 0.55)))
                .strikethrough(isCompleting, pattern: .solid, color: .white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                // A reminder's text is often something to carry elsewhere — an
                // order number, an address, a link. Only the title is selectable
                // rather than the whole row: the due date and the section headers
                // are labels about the reminder, not the reminder, and making them
                // selectable means a drag to the end of the title picks them up
                // too. The checkbox and the delete button are `Button`s, which
                // SwiftUI never makes selectable, so their behaviour is unchanged.
                .textSelection(.enabled)

            Spacer(minLength: 8)

            if let dueDate = item.dueDate {
                Text(Self.dueText(for: dueDate, isAllDay: item.isDueDateAllDay))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .monospacedDigit()
            }

            if case .failed = item.syncState {
                Text("not written")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.85))
            }

            Button {
                withAnimation { store.delete(item) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(hoveredItemID == item.id ? 0.6 : 0))
            .help(item.localID == nil ? "Delete reminder" : "Discard this pending reminder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // A floor, not a height: one line of text still comes out at the 30 points
        // the row has always been, and a wrapped one is allowed to be taller.
        .frame(minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(hoveredItemID == item.id ? 0.045 : 0))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredItemID = isHovering ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
        }
    }

    /// Plays the completion animation, then hands the row to the store. The
    /// tick and the strikethrough come first; the row's exit is driven by the
    /// store's rebuild, animated by the `withAnimation` around `complete`.
    private func beginCompletion(of item: ReminderPanelItem) {
        guard item.isCompletable, !completingItemIDs.contains(item.id) else { return }
        withAnimation(.easeOut(duration: 0.2)) { _ = completingItemIDs.insert(item.id) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.completionAnimationDuration))
            completingItemIDs.remove(item.id)
            withAnimation(.easeInOut(duration: 0.25)) { store.complete(item) }
        }
    }

    private func undoBar(_ undo: ReminderStore.PendingUndo) -> some View {
        HStack(spacing: 8) {
            Text("\"\(undo.title)\" \(undo.verb == .completed ? "completed" : "deleted")")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("Undo") { withAnimation { store.undoLatestPendingWrite() } }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.white.opacity(0.08))
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.9))
                .lineLimit(2)

            Spacer(minLength: 8)

            Button("Dismiss") { store.dismissError() }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12))
    }

    private var emptyListState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No reminders in this list")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            Text("Create one above — it is written to Apple Reminders.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Guidance states

    @ViewBuilder
    private var guidance: some View {
        VStack(spacing: 10) {
            Spacer()

            Image(systemName: "checklist")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))

            Text(guidanceTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)

            Text(guidanceBody)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            HStack(spacing: 8) {
                ForEach(Array(guidanceActions.enumerated()), id: \.offset) { _, action in
                    Button(action.title, action: action.handler)
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.white.opacity(0.09))
                        )
                }
            }
            .padding(.top, 2)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    private var guidanceTitle: String {
        guard store.isEnabled else { return "Apple Reminders is off" }
        switch store.authorization {
        case .notDetermined: return "Reminders access is required"
        case .denied: return "Reminders access was denied"
        case .writeOnly: return "Full access is required"
        case .fullAccess: return "No writable reminder list"
        }
    }

    private var guidanceBody: String {
        guard store.isEnabled else {
            return "Reminders created here are written to Apple Reminders, which syncs them to your other devices."
        }
        switch store.authorization {
        case .notDetermined:
            return "macOS asks once. The dialog only appears while the app is in the foreground."
        case .denied:
            return "Enable access under System Settings → Privacy & Security → Reminders."
        case .writeOnly:
            return "This app needs read access to list your reminders, not just write access."
        case .fullAccess:
            return "Create a list in Reminders first, then reload."
        }
    }

    private var guidanceActions: [(title: String, handler: () -> Void)] {
        guard store.isEnabled else {
            return [
                ("Enable", { Task { await store.setEnabled(true) } }),
                ("Settings…", onOpenSettings),
            ]
        }

        switch store.authorization {
        case .notDetermined:
            return [
                ("Request Access", { Task { await store.requestAccess() } }),
                ("Settings…", onOpenSettings),
            ]
        case .denied, .writeOnly:
            return [
                ("Open System Settings", { store.openPrivacySettings() }),
                ("Settings…", onOpenSettings),
            ]
        case .fullAccess:
            return [
                ("Reload", { store.requestRefresh(reloadLists: true, showingProgress: true) }),
                ("Open Reminders", { store.openRemindersApp() }),
            ]
        }
    }

    // MARK: - Formatting

    /// Compact due label. Deliberately not `DateFormatter` with a fixed format:
    /// the panel shows a *relative* reading for the near term and an absolute
    /// one beyond that. An all-day due date carries no time of day, so it
    /// renders as the bare day.
    static func dueText(
        for date: Date,
        isAllDay: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if isAllDay {
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInTomorrow(date) { return "Tomorrow" }
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(date) && date >= now {
            return time
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow \(time)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.055))
            .frame(height: 0.5)
    }
}

/// The reload button's glyph, which doubles as the panel's activity indicator.
///
/// `.symbolEffect(.rotate)` would be the tidy way to do this, but it needs
/// macOS 15 and this package targets 14. A repeating SwiftUI animation is the
/// replacement, and it has to be re-armed by hand on every flip, so this turns
/// exactly once per raise instead: `ReminderStore.minimumBusyDuration` holds
/// `isSpinning` long enough for one full turn to be legible, and a slower
/// operation simply finishes its turn early.
///
/// Progress is deliberately not proportional to how long the work takes. Being
/// proportional is what made the text it replaced flicker.
private struct RefreshGlyph: View {
    let isSpinning: Bool

    private static let turnDuration: TimeInterval = 0.45

    /// Counts revolutions rather than tracking an angle, so that every raise is
    /// a full turn and an interrupted one carries on from where it stopped
    /// instead of snapping back to the top.
    @State private var turns = 0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .rotationEffect(.degrees(Double(turns) * 360))
            .animation(.linear(duration: Self.turnDuration), value: turns)
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
            .onChange(of: isSpinning) { _, spinning in
                if spinning { turns += 1 }
            }
    }
}

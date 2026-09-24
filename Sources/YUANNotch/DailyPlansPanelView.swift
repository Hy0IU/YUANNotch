import AppKit
import SwiftUI

struct DailyPlansPanelView: View {
    @ObservedObject var store: DailyPlanStore
    let size: CGSize
    let isDrawerExpanded: Bool
    let onShowFloatingPlan: () -> Void

    @State private var page: Page = .today

    private enum Page: String, CaseIterable, Identifiable {
        case today = "Today"
        case history = "History"

        var id: String { rawValue }
    }

    private static let panelBackground = Color(red: 0.06, green: 0.06, blue: 0.07)
    private static let accent = Color.orange

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08))
                pageContent
            }

            if store.isEditorPresented {
                editor
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Self.panelBackground)
        .animation(.easeOut(duration: 0.16), value: store.isEditorPresented)
    }

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(Page.allCases) { candidate in
                Button {
                    page = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 11, weight: candidate == page ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(candidate == page ? 0.88 : 0.46))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.white.opacity(candidate == page ? 0.085 : 0))
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            Text(store.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.42))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .today:
            todayPage
        case .history:
            DailyPlanHistoryView(store: store)
        }
    }

    private var todayPage: some View {
        VStack(spacing: 0) {
            summary

            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.activeSession != nil {
                        activeCard
                    }

                    if store.plans.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.plans.filter { $0.id != store.activeSession?.planID }) { plan in
                            planRow(plan)
                        }
                    }
                }
                .padding(10)
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                Button {
                    store.beginCreatingPlan()
                } label: {
                    Label("Add Daily Plan", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MarkdownToolbarButtonStyle())

                Spacer()

                if let error = store.lastError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange.opacity(0.8))
                        .help(error)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
        }
    }

    private var summary: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Daily progress")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                Spacer()
                Text("\(durationText(store.todayFocusedSeconds)) / \(durationText(store.todayTargetSeconds))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.44))
                    .monospacedDigit()
            }

            PlanProgressBar(
                progress: store.todayTargetSeconds > 0
                    ? store.todayFocusedSeconds / store.todayTargetSeconds
                    : 0,
                color: Self.accent
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.08))
    }

    @ViewBuilder
    private var activeCard: some View {
        DailyPlanActiveCardView(
            store: store,
            isDrawerExpanded: isDrawerExpanded,
            isFloating: false,
            onFloatingAction: onShowFloatingPlan,
            displayDate: nil
        )
    }

    private func planRow(_ plan: DailyPlan) -> some View {
        let progress = store.progress(for: plan)

        return VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(plan.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(store.isScheduledToday(plan) ? planDaysText(plan) : "Not today · \(planDaysText(plan))")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)

                if plan.pomodoro.isEnabled {
                    Text("\(plan.pomodoro.focusMinutes) / \(plan.pomodoro.shortBreakMinutes)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.78))
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.orange.opacity(0.10))
                        )
                }

                Menu {
                    Button("Edit") { store.beginEditing(plan) }
                    Divider()
                    Button("Delete", role: .destructive) { store.deletePlan(id: plan.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button {
                    store.start(plan)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Start \(plan.title)")
            }

            HStack(spacing: 8) {
                PlanProgressBar(progress: progress, color: progress >= 1 ? .green : Self.accent)
                Text("\(durationText(store.focusedSeconds(for: plan.id, on: store.now))) / \(durationText(TimeInterval(plan.targetMinutes * 60)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.025))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("No daily plans yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
            Text("Add a recurring target, then start it whenever you are ready.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.36))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.editingPlanID == nil ? "New Daily Plan" : "Edit Daily Plan")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button("Cancel") { store.cancelEditing() }
                    .buttonStyle(MarkdownToolbarButtonStyle())
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    editorField("Name") {
                        TextField("Reading, Study, Work…", text: $store.draft.title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(editorFieldBackground)
                            .onSubmit {
                                store.commitDraft()
                            }
                    }

                    editorField("Daily target") {
                        HStack(spacing: 10) {
                            IntegerPlanInput(
                                label: "Target hours",
                                value: targetHoursBinding,
                                range: 0 ... 24,
                                step: 1,
                                unit: "h",
                                onSubmit: store.commitDraft
                            )
                            IntegerPlanInput(
                                label: "Target minutes",
                                value: targetMinutesRemainderBinding,
                                range: 0 ... 59,
                                step: 5,
                                unit: "min",
                                onSubmit: store.commitDraft
                            )
                        }
                    }

                    editorField("Active days") {
                        HStack(spacing: 5) {
                            ForEach(DailyPlanWeekday.allCases) { day in
                                let isSelected = store.draft.activeWeekdays.contains(day)
                                Button {
                                    if isSelected {
                                        guard store.draft.activeWeekdays.count > 1 else { return }
                                        store.draft.activeWeekdays.remove(day)
                                    } else {
                                        store.draft.activeWeekdays.insert(day)
                                    }
                                } label: {
                                    Text(day.shortTitle)
                                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? Self.accent : .white.opacity(0.42))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 25)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(isSelected ? Self.accent.opacity(0.16) : .white.opacity(0.035))
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(Self.accent.opacity(isSelected ? 0.28 : 0), lineWidth: 1)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(dayName(day))
                                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                                .help(dayName(day))
                            }
                        }
                        Text("Highlighted days are active.")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.34))
                    }

                    Toggle("Use Pomodoro", isOn: $store.draft.pomodoro.isEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 12, weight: .medium))

                    if store.draft.pomodoro.isEnabled {
                        HStack(spacing: 14) {
                            minuteStepper("Focus", value: $store.draft.pomodoro.focusMinutes, range: 1 ... 180)
                            minuteStepper("Short break", value: $store.draft.pomodoro.shortBreakMinutes, range: 1 ... 60)
                        }
                        HStack(spacing: 14) {
                            minuteStepper("Long break", value: $store.draft.pomodoro.longBreakMinutes, range: 1 ... 120)
                            editorField("Long break every") {
                                IntegerPlanInput(
                                    label: "Rounds before long break",
                                    value: $store.draft.pomodoro.roundsBeforeLongBreak,
                                    range: 1 ... 12,
                                    step: 1,
                                    unit: "rounds",
                                    onSubmit: store.commitDraft
                                )
                            }
                        }
                    }
                }
                .padding(12)
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                if store.editingPlanID != nil {
                    Button("Delete", role: .destructive) { store.deleteEditingPlan() }
                        .buttonStyle(MarkdownToolbarButtonStyle())
                }
                Spacer()
                Button("Save") { store.commitDraft() }
                    .buttonStyle(FocusActionButtonStyle(isPrimary: true, color: Self.accent))
                    .disabled(!store.draft.canCommit)
                    .opacity(store.draft.canCommit ? 1 : 0.35)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
        .background(Self.panelBackground)
    }

    private func editorField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func minuteStepper(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        editorField(label) {
            IntegerPlanInput(
                label: label,
                value: value,
                range: range,
                step: 1,
                unit: "min",
                onSubmit: store.commitDraft
            )
        }
    }

    private var targetHoursBinding: Binding<Int> {
        Binding(
            get: { store.draft.targetMinutes / 60 },
            set: { hours in
                let minutes = store.draft.targetMinutes % 60
                store.draft.targetMinutes = min(max(hours, 0) * 60 + minutes, 24 * 60)
            }
        )
    }

    private var targetMinutesRemainderBinding: Binding<Int> {
        Binding(
            get: { store.draft.targetMinutes % 60 },
            set: { minutes in
                let hours = store.draft.targetMinutes / 60
                store.draft.targetMinutes = min(max(hours * 60 + min(max(minutes, 0), 59), 0), 24 * 60)
            }
        )
    }

    private var editorFieldBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.white.opacity(0.055))
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(Int(seconds) / 60, 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    private func planDaysText(_ plan: DailyPlan) -> String {
        if plan.activeWeekdays.count == DailyPlanWeekday.allCases.count {
            return "Daily"
        }
        return DailyPlanWeekday.allCases
            .filter(plan.activeWeekdays.contains)
            .map(\.shortTitle)
            .joined(separator: " ")
    }

    private func dayName(_ day: DailyPlanWeekday) -> String {
        switch day {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }
}

enum FloatingPlanMetrics {
    static let panelSize = CGSize(width: 430, height: 145)
    static let edgeInset: CGFloat = 6
}

private struct FloatingPlanCountdownLabel: NSViewRepresentable {
    let store: DailyPlanStore
    let date: Date

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: countdownText)
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 25, weight: .medium)
        field.textColor = NSColor.white.withAlphaComponent(0.94)
        field.alignment = .left
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        let text = countdownText
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    private var countdownText: String {
        let seconds = store.phaseRemaining(at: date)
        let total = max(Int(ceil(seconds)), 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

struct FloatingPlanPanelView: View {
    @ObservedObject var store: DailyPlanStore
    let onHide: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            DailyPlanActiveCardView(
                store: store,
                isDrawerExpanded: false,
                isFloating: true,
                onFloatingAction: onHide,
                displayDate: context.date
            )
        }
        .padding(FloatingPlanMetrics.edgeInset)
        .frame(
            width: FloatingPlanMetrics.panelSize.width,
            height: FloatingPlanMetrics.panelSize.height
        )
        .preferredColorScheme(.dark)
    }
}

struct DailyPlanActiveCardView: View {
    @ObservedObject var store: DailyPlanStore
    let isDrawerExpanded: Bool
    let isFloating: Bool
    let onFloatingAction: () -> Void
    let displayDate: Date?

    private static let accent = Color.orange
    private static let cardBackground = Color.white.opacity(0.055)
    private static let floatingCardTint = Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.68)

    @ViewBuilder
    var body: some View {
        if let session = store.activeSession, let plan = store.activePlan {
            let phaseColor: Color = session.phase == .focus ? Self.accent : .green
            let displayNow = displayDate ?? store.now
            let remainingText = countdownText(store.phaseRemaining(at: displayNow))
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    CircularPlanProgress(
                        progress: session.phaseDuration > 0
                            ? store.phaseElapsed(at: displayNow) / session.phaseDuration
                            : 0,
                        color: phaseColor,
                        centerText: roundText(session, plan: plan),
                        size: 58
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(session.phase.title.uppercased()) · \(plan.title.uppercased())")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(phaseColor.opacity(0.9))
                            .lineLimit(1)
                        if isFloating {
                            FloatingPlanCountdownLabel(store: store, date: displayNow)
                                .frame(height: 30, alignment: .leading)
                        } else {
                            Text(remainingText)
                                .font(.system(size: 25, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.94))
                                .monospacedDigit()
                                .contentTransition(isDrawerExpanded ? .numericText() : .identity)
                        }
                        Text(session.isRunning ? "Running" : nextActionLabel(for: session))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 5) {
                        Button {
                            store.togglePause()
                        } label: {
                            Image(systemName: session.isRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.black.opacity(0.72))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(phaseColor))
                        }
                        .buttonStyle(.plain)
                        .help(session.isRunning ? "Pause" : nextActionLabel(for: session))

                        Button {
                            store.finishCurrentPhase()
                        } label: {
                            Image(systemName: session.phase == .focus ? "forward.end.fill" : "forward.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.52))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(.white.opacity(0.055)))
                        }
                        .buttonStyle(.plain)
                        .help(session.phase == .focus ? "Finish Round" : "Skip Break")

                        Button {
                            store.stopSession()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.52))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(.white.opacity(0.055)))
                        }
                        .buttonStyle(.plain)
                        .help("Stop")

                        Button(action: onFloatingAction) {
                            Image(systemName: isFloating ? "pin.slash.fill" : "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.52))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(isFloating ? "Hide floating timer" : "Show floating timer")

                        if !isFloating {
                            Menu {
                                Button("Edit") { store.beginEditing(plan) }
                                Divider()
                                Button("Delete", role: .destructive) { store.deletePlan(id: plan.id) }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 24, height: 24)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Plan options")
                        }
                    }
                }

                VStack(spacing: 6) {
                    HStack {
                        Text("Daily plan progress")
                        Spacer()
                        Text("\(durationText(store.focusedSeconds(for: plan.id, on: displayNow))) / \(durationText(TimeInterval(plan.targetMinutes * 60)))")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
                    .monospacedDigit()

                    PlanProgressBar(
                        progress: store.progress(for: plan, on: displayNow),
                        color: Self.accent
                    )
                }
            }
            .padding(11)
            .background { cardBackgroundView }
            // A one-second store refresh can arrive while the panel mask is
            // shrinking. Keep the timer text and progress ring from animating
            // inside that same reveal transaction; the panel itself still
            // performs its normal collapse animation.
            .transaction { transaction in
                if isFloating || !isDrawerExpanded {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
        }
    }

    @ViewBuilder
    private var cardBackgroundView: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if isFloating {
            shape
                // The material supplies the desktop blur; the tint makes the
                // live card substantially more opaque than the drawer card.
                .fill(.thickMaterial)
                .overlay {
                    shape.fill(Self.floatingCardTint)
                }
                .overlay {
                    shape.stroke(.white.opacity(0.09), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.42), radius: 10, x: 0, y: 4)
        } else {
            shape.fill(Self.cardBackground)
        }
    }

    private func nextActionLabel(for session: FocusSession) -> String {
        switch session.phase {
        case .focus: return "Resume Focus"
        case .shortBreak: return "Start Short Break"
        case .longBreak: return "Start Long Break"
        }
    }

    private func roundText(_ session: FocusSession, plan: DailyPlan) -> String {
        guard plan.pomodoro.isEnabled else { return "Free" }
        let round = session.phase == .focus
            ? session.completedFocusRounds + 1
            : max(session.completedFocusRounds, 1)
        let withinCycle = ((round - 1) % plan.pomodoro.roundsBeforeLongBreak) + 1
        return "\(withinCycle) / \(plan.pomodoro.roundsBeforeLongBreak)"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(Int(seconds) / 60, 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    private func countdownText(_ seconds: TimeInterval) -> String {
        let total = max(Int(ceil(seconds)), 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private struct IntegerPlanInput: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    let onSubmit: () -> Void

    @State private var textValue: String
    @FocusState private var isFieldFocused: Bool

    init(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        unit: String,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.onSubmit = onSubmit
        self._textValue = State(initialValue: String(value.wrappedValue))
    }

    private var clampedValue: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    var body: some View {
        HStack(spacing: 5) {
            TextField(label, text: $textValue)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 40, height: 27)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.055))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(.white.opacity(isFieldFocused ? 0.22 : 0), lineWidth: 1)
                }
                .onChange(of: textValue) { _, typedText in
                    let digits = String(typedText.filter { character in
                        character.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
                    })
                    if digits != typedText {
                        textValue = digits
                        return
                    }
                    guard let typedValue = Int(digits) else { return }
                    value = min(max(typedValue, range.lowerBound), range.upperBound)
                }
                .onChange(of: value) { _, newValue in
                    textValue = String(newValue)
                }
                .focused($isFieldFocused)
                .onSubmit {
                    normalizeTextValue()
                    isFieldFocused = false
                    onSubmit()
                }
                .onChange(of: isFieldFocused) { wasFocused, isFocused in
                    if wasFocused && !isFocused {
                        normalizeTextValue()
                    }
                }
                .accessibilityLabel(label)

            Text(unit)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.48))
                .fixedSize()

            Stepper("", value: clampedValue, in: range, step: step)
                .labelsHidden()
                .fixedSize()
                .help("Adjust \(label.lowercased())")
        }
    }

    private func normalizeTextValue() {
        let normalized = Int(textValue)
            .map { min(max($0, range.lowerBound), range.upperBound) }
            ?? value
        value = normalized
        textValue = String(normalized)
    }
}

private struct PlanProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                Capsule()
                    .fill(color.opacity(0.9))
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

private struct CircularPlanProgress: View {
    let progress: Double
    let color: Color
    let centerText: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.08), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if !centerText.isEmpty {
                Text(centerText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
    }
}

private struct FocusActionButtonStyle: ButtonStyle {
    let isPrimary: Bool
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isPrimary ? Color.black.opacity(0.76) : Color.white.opacity(0.76))
            .padding(.horizontal, 11)
            .frame(height: 29)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isPrimary ? color.opacity(configuration.isPressed ? 0.72 : 0.92) : .white.opacity(configuration.isPressed ? 0.1 : 0.055))
            )
            .pointingHandCursor()
    }
}

import AppKit
import SwiftUI

struct DailyPlansPanelView: View {
    @ObservedObject var store: DailyPlanStore
    @Environment(\.appTypography) private var typography
    let size: CGSize
    let isDrawerExpanded: Bool
    let onToggleFloatingPlan: () -> Void

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

            if store.timeDraft != nil {
                DailyPlanTimeEditor(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Self.panelBackground)
        .animation(.easeOut(duration: 0.16), value: store.isEditorPresented)
        .animation(.easeOut(duration: 0.16), value: store.timeDraft != nil)
    }

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(Page.allCases) { candidate in
                Button {
                    page = candidate
                } label: {
                    Text(candidate.rawValue)
                        .appText(.control, weight: candidate == page ? .semibold : nil)
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

            Text(store.today.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .appText(.secondary)
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
                        .appText(.control)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DailyPlanToolbarButtonStyle())

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
                    .appText(.sectionTitle)
                    .foregroundStyle(.white.opacity(0.86))
                Spacer()
                Text("\(durationText(store.todayFocusedSeconds)) / \(durationText(store.todayTargetSeconds))")
                    .appText(.secondary)
                    .foregroundStyle(.white.opacity(0.44))
                    .monospacedDigit()
                Button {
                    store.beginEditingTime(on: store.today)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.white.opacity(0.055)))
                }
                .buttonStyle(.plain)
                .help("Edit today's focus time")
                .accessibilityLabel("Edit today's focus time")
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
            availableWidth: max(size.width - 20, 0),
            isDrawerExpanded: isDrawerExpanded,
            isFloating: false,
            onFloatingAction: onToggleFloatingPlan,
            displayDate: nil
        )
    }

    private func planRow(_ plan: DailyPlan) -> some View {
        let progress = store.progress(for: plan)

        return VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(plan.title)
                    .appText(.body, weight: .medium)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(store.isScheduledToday(plan) ? planDaysText(plan) : "Not today · \(planDaysText(plan))")
                    .appText(.compact, weight: .regular)
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)

                if plan.pomodoro.isEnabled {
                    Text("\(plan.pomodoro.focusMinutes) / \(plan.pomodoro.shortBreakMinutes)")
                        .appText(.compact)
                        .foregroundStyle(.orange.opacity(0.78))
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.orange.opacity(0.10))
                        )
                }

                Menu {
                    Button { store.beginEditing(plan) } label: { Text("Edit").appText(.control) }
                    Button { store.beginEditingTime(on: store.today) } label: { Text("Edit Focus Time…").appText(.control) }
                    Divider()
                    Button(role: .destructive) { store.deletePlan(id: plan.id) } label: {
                        Text("Delete").appText(.control)
                    }
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
                Text("\(durationText(store.focusedSeconds(for: plan.id, on: store.today))) / \(durationText(TimeInterval(plan.targetMinutes * 60)))")
                    .appText(.compact, weight: .regular)
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
                .appText(.body, weight: .medium)
                .foregroundStyle(.white.opacity(0.62))
            Text("Add a recurring target, then start it whenever you are ready.")
                .appText(.secondary)
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
                    .appText(.sectionTitle)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button("Cancel") { store.cancelEditing() }
                    .buttonStyle(DailyPlanToolbarButtonStyle())
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    editorField("Name") {
                        TextField("Reading, Study, Work…", text: $store.draft.title)
                            .textFieldStyle(.plain)
                            .font(typography.font(.control))
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
                                        .appText(.compact, weight: isSelected ? .semibold : .regular)
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
                            .appText(.compact, weight: .regular)
                            .foregroundStyle(.white.opacity(0.34))
                    }

                    Toggle("Use Pomodoro", isOn: $store.draft.pomodoro.isEnabled)
                        .toggleStyle(.switch)
                        .font(typography.font(.control))

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
                        .buttonStyle(DailyPlanToolbarButtonStyle())
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
                .appText(.compact)
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

private struct FloatingPlanPinButton: View {
    @ObservedObject var presentation: FloatingPlanPresentation
    let action: () -> Void

    private var hidesTimer: Bool { presentation.isVisible }

    var body: some View {
        Button(action: action) {
            Image(systemName: hidesTimer ? "pin.slash.fill" : "pin.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    presentation.isVisible
                        ? Color.orange
                        : Color.white.opacity(0.52)
                )
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(hidesTimer ? "Hide floating timer" : "Show floating timer")
        .accessibilityLabel(hidesTimer ? "Hide floating timer" : "Show floating timer")
    }
}

enum FloatingPlanMetrics {
    static let compactSize = CGSize(width: 64, height: 64)
    static let expandedSize = CGSize(width: 360, height: 125)
    static let edgeInset: CGFloat = 6
    static let collapseDelay: TimeInterval = 0.12
    static let collapseDuration: TimeInterval = 0.22

    static func collapseFrame(from start: CGRect, to end: CGRect, progress: Double) -> CGRect {
        let t = CGFloat(min(max(progress, 0), 1))
        let eased = t * t * (3 - 2 * t)
        return CGRect(
            x: start.minX + (end.minX - start.minX) * eased,
            y: start.minY + (end.minY - start.minY) * eased,
            width: start.width + (end.width - start.width) * eased,
            height: start.height + (end.height - start.height) * eased
        )
    }
}

private struct FloatingPlanCountdownLabel: NSViewRepresentable {
    let store: DailyPlanStore
    let date: Date
    let typography: AppTypography

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: countdownText)
        field.font = .monospacedDigitSystemFont(ofSize: typography.size(.timer), weight: .medium)
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
        nsView.font = .monospacedDigitSystemFont(ofSize: typography.size(.timer), weight: .medium)
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

private struct FloatingPlanCardBackground: View {
    var cornerRadius: CGFloat = 14

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(.thickMaterial)
            .overlay { shape.fill(Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.68)) }
            .overlay { shape.stroke(.white.opacity(0.045), lineWidth: 0.5) }
    }
}

private struct FloatingPlanControlsBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct FloatingPlanDragRegion: NSViewRepresentable {
    let controlsFrame: CGRect

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.controlsFrame = controlsFrame
    }

    final class DragView: NSView {
        var controlsFrame = CGRect.zero

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard !controlsFrame.contains(localPoint) else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

struct FloatingPlanPanelView: View {
    @ObservedObject var store: DailyPlanStore
    let isExpanded: Bool
    let onExpand: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let metrics = FloatingPlanMetrics.self
            let expansion = min(max(
                (geometry.size.width - metrics.compactSize.width)
                    / (metrics.expandedSize.width - metrics.compactSize.width),
                0
            ), 1)
            let width = max(geometry.size.width - metrics.edgeInset * 2, 0)
            let height = max(geometry.size.height - metrics.edgeInset * 2, 0)
            let cornerRadius = 12 + 2 * expansion
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let session = store.activeSession, let plan = store.activePlan {
                    ZStack(alignment: .topLeading) {
                        FloatingPlanCardBackground(cornerRadius: cornerRadius)
                        if expansion > 0 {
                            DailyPlanActiveCardView(
                                store: store,
                                availableWidth: metrics.expandedSize.width - metrics.edgeInset * 2,
                                isDrawerExpanded: false,
                                isFloating: true,
                                displayDate: context.date,
                                showsProgressRing: false,
                                showsBackground: false
                            )
                            .frame(
                                width: metrics.expandedSize.width - metrics.edgeInset * 2,
                                height: metrics.expandedSize.height - metrics.edgeInset * 2,
                                alignment: .topLeading
                            )
                            .opacity(min(max((expansion - 0.65) / 0.35, 0), 1))
                            .accessibilityHidden(expansion < 1)
                            .allowsHitTesting(expansion == 1)
                        }
                        Button {
                            if !isExpanded { onExpand() }
                        } label: {
                            CircularPlanProgress(
                                progress: session.phaseDuration > 0
                                    ? store.phaseElapsed(at: context.date) / session.phaseDuration
                                    : 0,
                                color: session.phase == .focus ? .orange : .green,
                                centerText: expansion > 0 ? focusRoundText(session, plan: plan) : "",
                                size: 32 + 26 * expansion,
                                centerTextOpacity: expansion
                            )
                            .position(x: 26 + 12 * expansion, y: 26 + 12 * expansion)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!isExpanded)
                        .accessibilityHidden(isExpanded)
                        .accessibilityLabel("Expand focus timer")
                        .help("Click to expand the focus timer")
                    }
                    .frame(width: width, height: height, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .padding(metrics.edgeInset)
        }
        .overlayPreferenceValue(FloatingPlanControlsBoundsKey.self) { controls in
            if isExpanded, let controls {
                GeometryReader { geometry in
                    FloatingPlanDragRegion(controlsFrame: geometry[controls])
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct DailyPlanActiveCardView: View {
    @ObservedObject var store: DailyPlanStore
    @Environment(\.appTypography) private var typography
    let availableWidth: CGFloat
    let isDrawerExpanded: Bool
    let isFloating: Bool
    var onFloatingAction: (() -> Void)? = nil
    let displayDate: Date?
    var showsProgressRing = true
    var showsBackground = true

    private static let accent = Color.orange
    private static let cardBackground = Color.white.opacity(0.055)

    @ViewBuilder
    var body: some View {
        if let session = store.activeSession, let plan = store.activePlan {
            let phaseColor: Color = session.phase == .focus ? Self.accent : .green
            let displayNow = displayDate ?? store.now
            let remainingText = countdownText(store.phaseRemaining(at: displayNow))
            VStack(spacing: isFloating ? 5 : 10) {
                if usesCompactControls {
                    HStack(spacing: 12) {
                        progressRing(session, plan: plan, phaseColor: phaseColor, displayNow: displayNow)
                        sessionDetails(
                            session,
                            plan: plan,
                            phaseColor: phaseColor,
                            remainingText: remainingText,
                            displayNow: displayNow
                        )
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Spacer()
                        timerControls(session, plan: plan, phaseColor: phaseColor)
                    }
                } else {
                    HStack(spacing: 12) {
                        progressRing(session, plan: plan, phaseColor: phaseColor, displayNow: displayNow)
                        sessionDetails(
                            session,
                            plan: plan,
                            phaseColor: phaseColor,
                            remainingText: remainingText,
                            displayNow: displayNow
                        )
                        Spacer(minLength: 4)
                        timerControls(session, plan: plan, phaseColor: phaseColor)
                    }
                }

                VStack(spacing: isFloating ? 4 : 6) {
                    HStack {
                        Text("Daily plan progress")
                        Spacer()
                        Text("\(durationText(store.focusedSeconds(for: plan.id, on: store.today))) / \(durationText(TimeInterval(plan.targetMinutes * 60)))")
                    }
                    .appText(.compact, weight: .regular)
                    .foregroundStyle(.white.opacity(0.42))
                    .monospacedDigit()

                    PlanProgressBar(
                        progress: store.progress(for: plan, on: displayNow),
                        color: Self.accent
                    )
                }
            }
            .padding(isFloating ? 9 : 11)
            .background {
                if showsBackground { cardBackgroundView }
            }
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

    private var usesCompactControls: Bool {
        !isFloating && availableWidth < 390
    }

    @ViewBuilder
    private func progressRing(
        _ session: FocusSession,
        plan: DailyPlan,
        phaseColor: Color,
        displayNow: Date
    ) -> some View {
        if showsProgressRing {
            CircularPlanProgress(
                progress: session.phaseDuration > 0
                    ? store.phaseElapsed(at: displayNow) / session.phaseDuration
                    : 0,
                color: phaseColor,
                centerText: focusRoundText(session, plan: plan),
                size: 58
            )
        } else {
            Color.clear.frame(width: 58, height: 58)
        }
    }

    private func sessionDetails(
        _ session: FocusSession,
        plan: DailyPlan,
        phaseColor: Color,
        remainingText: String,
        displayNow: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(session.phase.title.uppercased()) · \(plan.title.uppercased())")
                .appText(.compact, weight: .semibold)
                .foregroundStyle(phaseColor.opacity(0.9))
                .lineLimit(1)
                .help("\(session.phase.title) · \(plan.title)")
            if isFloating {
                FloatingPlanCountdownLabel(store: store, date: displayNow, typography: typography)
                    .frame(height: typography.lineHeight(.timer), alignment: .leading)
            } else {
                Text(remainingText)
                    .appText(.timer)
                    .foregroundStyle(.white.opacity(0.94))
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .contentTransition(isDrawerExpanded ? .numericText() : .identity)
            }
            Text(session.isRunning ? "Running" : nextActionLabel(for: session))
                .appText(.compact, weight: .regular)
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    @ViewBuilder
    private func timerControls(
        _ session: FocusSession,
        plan: DailyPlan,
        phaseColor: Color
    ) -> some View {
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
            .accessibilityLabel(session.isRunning ? "Pause" : nextActionLabel(for: session))

            if usesCompactControls {
                Menu {
                    Button { store.beginEditing(plan) } label: { Text("Edit").appText(.control) }
                    Button { store.beginEditingTime(on: store.today) } label: {
                        Text("Edit Focus Time…").appText(.control)
                    }
                    Divider()
                    Button {
                        store.finishCurrentPhase()
                    } label: {
                        Text(session.phase == .focus ? "Finish Round" : "Skip Break").appText(.control)
                    }
                    Button { store.resetSession() } label: { Text("Reset").appText(.control) }
                    Divider()
                    Button(role: .destructive) { store.deletePlan(id: plan.id) } label: {
                        Text("Delete").appText(.control)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More plan and timer actions")
                .accessibilityLabel("More plan and timer actions")
            } else {
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
                .accessibilityLabel(session.phase == .focus ? "Finish Round" : "Skip Break")

                Button {
                    store.resetSession()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.055)))
                }
                .buttonStyle(.plain)
                .help("Reset")
                .accessibilityLabel("Reset")
            }

            if !isFloating, let onFloatingAction {
                FloatingPlanPinButton(
                    presentation: store.floatingPresentation,
                    action: onFloatingAction
                )
            }

            if !isFloating && !usesCompactControls {
                Menu {
                    Button { store.beginEditing(plan) } label: { Text("Edit").appText(.control) }
                    Button { store.beginEditingTime(on: store.today) } label: {
                        Text("Edit Focus Time…").appText(.control)
                    }
                    Divider()
                    Button(role: .destructive) { store.deletePlan(id: plan.id) } label: {
                        Text("Delete").appText(.control)
                    }
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
        .anchorPreference(key: FloatingPlanControlsBoundsKey.self, value: .bounds) {
            isFloating ? $0 : nil
        }
    }

    @ViewBuilder
    private var cardBackgroundView: some View {
        if isFloating {
            FloatingPlanCardBackground()
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.cardBackground)
        }
    }

    private func nextActionLabel(for session: FocusSession) -> String {
        switch session.phase {
        case .focus: return "Resume Focus"
        case .shortBreak: return "Start Short Break"
        case .longBreak: return "Start Long Break"
        }
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

private func focusRoundText(_ session: FocusSession, plan: DailyPlan) -> String {
    guard plan.pomodoro.isEnabled else { return "Free" }
    let round = session.phase == .focus
        ? session.completedFocusRounds + 1
        : max(session.completedFocusRounds, 1)
    let withinCycle = ((round - 1) % plan.pomodoro.roundsBeforeLongBreak) + 1
    return "\(withinCycle) / \(plan.pomodoro.roundsBeforeLongBreak)"
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
    @Environment(\.appTypography) private var typography

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
                .font(typography.font(.control))
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
                .appText(.compact, weight: .regular)
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
    var centerTextOpacity: Double = 1

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
                    .appText(.compact)
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
                    .opacity(centerTextOpacity)
            }
        }
        .frame(width: size, height: size)
    }
}

struct FocusActionButtonStyle: ButtonStyle {
    let isPrimary: Bool
    let color: Color

    @Environment(\.appTypography) private var typography

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(typography.font(.control))
            .foregroundStyle(isPrimary ? Color.black.opacity(0.76) : Color.white.opacity(0.76))
            .padding(.horizontal, 11)
            .frame(height: typography.controlHeight(base: 29))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isPrimary ? color.opacity(configuration.isPressed ? 0.72 : 0.92) : .white.opacity(configuration.isPressed ? 0.1 : 0.055))
            )
            .pointingHandCursor()
    }
}

struct DailyPlanToolbarButtonStyle: ButtonStyle {
    @Environment(\.appTypography) private var typography
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(typography.font(.control))
            .foregroundStyle(.white.opacity(foregroundOpacity(configuration)))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(backgroundOpacity(configuration)))
            )
            .animation(.easeOut(duration: 0.10), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                isHovering = isEnabled && hovering
            }
            .pointingHandCursor(isEnabled: isEnabled)
    }

    private func backgroundOpacity(_ configuration: Configuration) -> CGFloat {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.10 }
        return isHovering ? 0.065 : 0
    }

    private func foregroundOpacity(_ configuration: Configuration) -> CGFloat {
        guard isEnabled else { return 0.22 }
        if configuration.isPressed { return 0.54 }
        return isHovering ? 0.84 : 0.66
    }
}

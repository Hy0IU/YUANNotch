import SwiftUI

struct DailyPlansPanelView: View {
    @ObservedObject var store: DailyPlanStore
    let size: CGSize

    @State private var page: Page = .today

    private enum Page: String, CaseIterable, Identifiable {
        case today = "Today"
        case focus = "Focus"

        var id: String { rawValue }
    }

    private static let panelBackground = Color(red: 0.06, green: 0.06, blue: 0.07)
    private static let cardBackground = Color.white.opacity(0.055)
    private static let accent = Color.orange

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08))

                switch page {
                case .today:
                    todayPage
                case .focus:
                    focusPage
                }
            }

            if store.isEditorPresented {
                editor
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Self.panelBackground)
        .animation(.easeOut(duration: 0.16), value: store.isEditorPresented)
        .onChange(of: store.activeSession?.planID) { _, planID in
            if planID == nil, page == .focus {
                page = .today
            }
        }
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
                        ForEach(store.plans) { plan in
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
                Text("Today")
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
        if let session = store.activeSession, let plan = store.activePlan {
            let phaseColor: Color = session.phase == .focus ? Self.accent : .green
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    CircularPlanProgress(
                        progress: session.phaseDuration > 0
                            ? store.phaseElapsed() / session.phaseDuration
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
                        Text(countdownText(store.phaseRemaining()))
                            .font(.system(size: 25, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.94))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(session.isRunning ? "Running" : nextActionLabel(for: session))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    Spacer(minLength: 4)

                    VStack(spacing: 5) {
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
                            page = .focus
                        } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.52))
                                .frame(width: 24, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help("Open Focus")
                    }
                }

                VStack(spacing: 6) {
                    HStack {
                        Text("Daily plan progress")
                        Spacer()
                        Text("\(durationText(store.focusedSeconds(for: plan.id, on: store.now))) / \(durationText(TimeInterval(plan.targetMinutes * 60)))")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
                    .monospacedDigit()

                    PlanProgressBar(progress: store.progress(for: plan), color: Self.accent)
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Self.cardBackground)
            )
        }
    }

    private func planRow(_ plan: DailyPlan) -> some View {
        let progress = store.progress(for: plan)
        let isActive = store.activeSession?.planID == plan.id

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
                    if isActive {
                        store.togglePause()
                    } else {
                        store.start(plan)
                    }
                } label: {
                    Image(systemName: isActive && store.activeSession?.isRunning == true ? "pause.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(isActive && store.activeSession?.isRunning == true ? "Pause" : "Start \(plan.title)")
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
                .fill(.white.opacity(isActive ? 0.05 : 0.025))
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

    @ViewBuilder
    private var focusPage: some View {
        if let session = store.activeSession, let plan = store.activePlan {
            let phaseColor: Color = session.phase == .focus ? Self.accent : .green

            VStack(spacing: 14) {
                Spacer(minLength: 8)

                VStack(spacing: 4) {
                    Text(plan.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("\(session.phase.title) · \(roundText(session, plan: plan))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.42))
                }

                ZStack {
                    CircularPlanProgress(
                        progress: session.phaseDuration > 0
                            ? store.phaseElapsed() / session.phaseDuration
                            : 0,
                        color: phaseColor,
                        centerText: "",
                        size: min(max(size.height * 0.34, 88), 132)
                    )

                    VStack(spacing: 3) {
                        Text(countdownText(store.phaseRemaining()))
                            .font(.system(size: 31, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.94))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(session.isRunning ? "Running" : nextActionLabel(for: session))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }

                HStack(spacing: 8) {
                    Button(session.isRunning ? "Pause" : nextActionLabel(for: session)) {
                        store.togglePause()
                    }
                    .buttonStyle(FocusActionButtonStyle(isPrimary: true, color: phaseColor))

                    Button(session.phase == .focus ? "Finish Round" : "Skip Break") {
                        store.finishCurrentPhase()
                    }
                    .buttonStyle(FocusActionButtonStyle(isPrimary: false, color: phaseColor))

                    Button("Stop") { store.stopSession() }
                        .buttonStyle(FocusActionButtonStyle(isPrimary: false, color: phaseColor))
                }

                VStack(spacing: 7) {
                    HStack {
                        Text("Today’s \(plan.title) plan")
                        Spacer()
                        Text("\(durationText(store.focusedSeconds(for: plan.id, on: store.now))) / \(durationText(TimeInterval(plan.targetMinutes * 60)))")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
                    .monospacedDigit()

                    PlanProgressBar(progress: store.progress(for: plan), color: Self.accent)
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 8)
            }
            .padding(.vertical, 10)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "timer")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.28))
                Text("Start a plan to enter Focus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                Button("Back to Today") { page = .today }
                    .buttonStyle(MarkdownToolbarButtonStyle())
                Spacer()
            }
        }
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
                    }

                    editorField("Daily target") {
                        Stepper(value: $store.draft.targetMinutes, in: 5 ... 1_440, step: 5) {
                            Text(durationText(TimeInterval(store.draft.targetMinutes * 60)))
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
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
                                        .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.4))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 25)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(.white.opacity(isSelected ? 0.11 : 0.035))
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(dayName(day))
                                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                                .help(dayName(day))
                            }
                        }
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
                                Stepper(value: $store.draft.pomodoro.roundsBeforeLongBreak, in: 1 ... 12) {
                                    Text("\(store.draft.pomodoro.roundsBeforeLongBreak) rounds")
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                }
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
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue) min")
                    .font(.system(size: 11))
                    .monospacedDigit()
            }
        }
    }

    private var editorFieldBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.white.opacity(0.055))
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

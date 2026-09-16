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
    @State private var selectedMinutes = ReminderTimePreset.fifteen.minutes
    @State private var customMinutes = ""
    @State private var isCustomTime = false
    @State private var hoveredItemID: String?
    @FocusState private var isDraftFocused: Bool

    private enum ReminderTimePreset: Int, CaseIterable, Identifiable {
        case five = 5
        case fifteen = 15
        case thirty = 30
        case hour = 60

        var id: Int { rawValue }
        var minutes: Int { rawValue }
        var title: String { self == .hour ? "1h" : "\(rawValue)m" }
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
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
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
        VStack(spacing: 8) {
            TextField("New reminder", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .focused($isDraftFocused)
                .onSubmit(commit)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(0.045))
                )

            HStack(spacing: 6) {
                ForEach(ReminderTimePreset.allCases) { preset in
                    timeChip(title: preset.title, isSelected: !isCustomTime && selectedMinutes == preset.minutes) {
                        isCustomTime = false
                        selectedMinutes = preset.minutes
                    }
                }

                timeChip(title: "Custom", isSelected: isCustomTime) {
                    isCustomTime = true
                }

                if isCustomTime {
                    TextField("min", text: $customMinutes)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44, height: 22)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                        .onSubmit(commit)
                }

                Spacer(minLength: 8)

                Button(action: commit) {
                    Text("Add")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MarkdownToolbarButtonStyle())
                .disabled(!canCommit)
                .help("Add to Apple Reminders")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func timeChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.55))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(isSelected ? 0.1 : 0.035))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canCommit: Bool {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isCustomTime {
            guard let minutes = Int(customMinutes), minutes > 0 else { return false }
        }
        return true
    }

    private var effectiveMinutes: Int {
        if isCustomTime, let minutes = Int(customMinutes), minutes > 0 {
            return minutes
        }
        return selectedMinutes
    }

    private func commit() {
        guard canCommit else { return }
        let title = draft
        let minutes = effectiveMinutes
        draft = ""
        Task { await store.create(title: title, minutesFromNow: minutes) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                emptyListState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.groupedItems(), id: \.group) { section in
                            groupHeader(section.group.title)
                            ForEach(section.items) { item in
                                row(for: item)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let title = store.pendingDeletionTitle {
                undoBar(title: title)
            }

            if let error = store.lastError {
                errorBar(error)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
        HStack(spacing: 9) {
            Button {
                guard item.isCompletable else { return }
                Task { await store.setCompleted(item, isCompleted: true) }
            } label: {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(item.isCompletable ? 0.5 : 0.18), lineWidth: 1)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.isCompletable)
            .help(item.isCompletable ? "Mark as completed" : "Not written to Reminders yet")

            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(item.syncState == .idle ? 0.88 : 0.55))
                .lineLimit(1)

            Spacer(minLength: 8)

            if let dueDate = item.dueDate {
                Text(Self.dueText(for: dueDate))
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
                store.delete(item)
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
        .frame(height: 30)
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

    private func undoBar(title: String) -> some View {
        HStack(spacing: 8) {
            Text("\"\(title)\" deleted")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("Undo") { store.undoDelete() }
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
    /// one beyond that.
    static func dueText(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
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

import SwiftUI

/// The drawer's reminders surface: list picker, a one-line compose row, and
/// the grouped list of incomplete reminders for the selected list.
///
/// Completed reminders are never rendered — they are excluded at the query, so
/// there is no "completed" section and no clear-completed affordance.
struct RemindersPanelView: View {
    @ObservedObject var store: ReminderStore
    /// The reminder being composed — text, due date and all.
    ///
    /// Observed here but owned by the store, because this view is not the only
    /// thing whose lifetime matters: the drawer swaps the whole reminders surface
    /// for the notes one on every mode switch, and this state used to be `@State`
    /// inside the panel, so it left with the view. Half-typed reminders vanished
    /// when the user glanced at their notes and came back.
    @ObservedObject var composer: ReminderComposer
    let size: CGSize
    let onOpenSettings: () -> Void

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

    /// Raised whenever the caret is wanted in the compose field: after a commit,
    /// and when this surface comes back with a draft still in it. Handled by
    /// `FieldCaretFocus`, which focuses the field with the caret at the end —
    /// not `@FocusState`, whose focus lands with the whole text selected.
    @State private var draftFocusRequest = 0

    /// Same mechanism, for the row being edited. A separate counter on purpose:
    /// the two bridges would otherwise answer each other's requests.
    @State private var editFocusRequest = 0

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
        // This surface is rebuilt from scratch every time the drawer comes back
        // from the notes side, so whatever the composer still holds has to be
        // offered to the caret again here.
        .onAppear { restoreDraftFocus() }
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

            if composer.showsCustomRow {
                customRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var draftField: some View {
        TextField(Self.draftPlaceholder, text: $composer.draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.9))
            .fieldCaretFocus(request: draftFocusRequest, placeholder: Self.draftPlaceholder)
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
        .disabled(!composer.canCommit)
        .help("Add to Apple Reminders")
    }

    // MARK: - Due date menus

    /// The due-date menu. Its label is read back off the resolution rather than
    /// off the option, so a time chosen with no date names the day it will land
    /// on instead of claiming there is none.
    private var dateMenu: some View {
        Menu {
            menuEntry(DueDateOption.none.title, isSelected: composer.dateOption == .none) {
                composer.select(dateOption: .none)
            }
            Divider()
            menuEntry(DueDateOption.today.title, isSelected: composer.dateOption == .today) {
                composer.select(dateOption: .today)
            }
            menuEntry(DueDateOption.tomorrow.title, isSelected: composer.dateOption == .tomorrow) {
                composer.select(dateOption: .tomorrow)
            }
            menuEntry(DueDateOption.thisWeekend.title, isSelected: composer.dateOption == .thisWeekend) {
                composer.select(dateOption: .thisWeekend)
            }
            menuEntry(DueDateOption.nextWeek.title, isSelected: composer.dateOption == .nextWeek) {
                composer.select(dateOption: .nextWeek)
            }
            Divider()
            menuEntry(DueDateOption.custom.title, isSelected: composer.dateOption == .custom) {
                composer.select(dateOption: .custom)
            }
        } label: {
            menuLabel(symbol: "calendar", title: composer.dateButtonTitle())
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
            menuEntry(DueTimeOption.none.title, isSelected: composer.timeOption == .none) {
                composer.select(timeOption: .none)
            }
            Divider()
            ForEach(DueTimeOption.presets, id: \.self) { option in
                menuEntry(option.title, isSelected: composer.timeOption == option) {
                    composer.select(timeOption: option)
                }
            }
            Divider()
            menuEntry("In 15 Minutes", isSelected: false) { composer.applyRelative(minutes: 15) }
            menuEntry("In 1 Hour", isSelected: false) { composer.applyRelative(minutes: 60) }
            Divider()
            menuEntry(DueTimeOption.custom.title, isSelected: composer.timeOption == .custom) {
                composer.select(timeOption: .custom)
            }
        } label: {
            menuLabel(symbol: "clock", title: composer.timeButtonTitle())
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

    // MARK: - Custom date and time

    private var customRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if composer.dateOption == .custom {
                HStack(spacing: 6) {
                    rowLabel("Date")
                    DatePicker("", selection: customDateBinding, displayedComponents: [.date])
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

            if composer.timeOption == .custom {
                HStack(spacing: 6) {
                    rowLabel("Time")
                    timeField
                    wheelToggle
                    Spacer(minLength: 0)
                }

                if composer.isTimeWheelShown {
                    DatePicker("", selection: customTimeBinding, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .font(.system(size: 12))
                        .environment(\.colorScheme, .dark)
                        .fixedSize()
                        .padding(.leading, Self.rowLabelWidth + 6)
                }
            }
        }
    }

    /// The custom inputs' bindings go through the composer's own methods rather
    /// than straight at the value: the typed text and the wheel are two views
    /// onto one time, and the rule that keeps them agreeing lives with the value.
    /// A binding that wrote the value directly would be the drift the rule exists
    /// to prevent.
    private var customDateBinding: Binding<Date> {
        Binding(get: { composer.customDate }, set: { composer.setCustomDate($0) })
    }

    private var customTimeBinding: Binding<Date> {
        Binding(get: { composer.customTime }, set: { composer.setCustomTime($0) })
    }

    private var customTimeTextBinding: Binding<String> {
        Binding(get: { composer.customTimeText }, set: { composer.setCustomTimeText($0) })
    }

    private static let rowLabelWidth: CGFloat = 34

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .frame(width: Self.rowLabelWidth, alignment: .leading)
    }

    private var timeField: some View {
        TextField(TimeOfDay(hour: 21, minute: 0).formatted(), text: customTimeTextBinding)
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
                    .opacity(composer.customTimeParseFailed ? 1 : 0)
            )
            .help("Type a time such as 21:00, 9pm or 2130")
    }

    private var wheelToggle: some View {
        Button {
            composer.toggleTimeWheel()
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(composer.isTimeWheelShown ? 0.85 : 0.55))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(composer.isTimeWheelShown ? 0.12 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pick the time with the system picker instead")
    }

    // MARK: - Committing

    /// The compose field's placeholder. Named once because it is also how
    /// `FieldCaretFocus` finds the field in the AppKit tree.
    static let draftPlaceholder = "New reminder"

    /// The edit field's placeholder, for the same reason. It is rarely seen —
    /// the field comes pre-filled — but it is what distinguishes the two fields
    /// the compose row and an edited row can have in the tree.
    static let editPlaceholder = "Edit reminder"

    /// One commit: the composer empties the row and hands back what to write, and
    /// this view keeps only what is its own — the caret stays in the field so
    /// several reminders in a row need no trip to the mouse.
    private func commit() {
        guard let pending = composer.consume() else { return }
        draftFocusRequest += 1
        Task { await store.create(title: pending.title, due: pending.due) }
    }

    /// Restores the caret when the drawer comes back to this surface with a
    /// reminder half typed. The text survives because it belongs to the composer;
    /// the caret is this view's, and a draft the user cannot continue typing is
    /// only half returned.
    private func restoreDraftFocus() {
        guard composer.canCommit else { return }
        draftFocusRequest += 1
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

    @ViewBuilder
    private func row(for item: ReminderPanelItem) -> some View {
        // An edit replaces the row's content but keeps its chrome, so the swap
        // reads as the same row changing its mind about being a label.
        if store.editingID == item.id {
            editRow(for: item)
        } else {
            displayRow(for: item)
        }
    }

    private func displayRow(for item: ReminderPanelItem) -> some View {
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

            if item.isEditable {
                Button {
                    store.beginEditing(item)
                    editFocusRequest += 1
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(hoveredItemID == item.id ? 0.6 : 0))
                .help("Edit reminder")
            }
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

    /// The row while its text is being rewritten. The field takes over from the
    /// label and everything that would race the edit steps aside: completing the
    /// row mid-edit would end the edit under the user's hands, and the delete
    /// button has no business inside a row that is being retyped.
    private func editRow(for item: ReminderPanelItem) -> some View {
        HStack(spacing: 9) {
            // The checkbox is where the user's eye expects it, but inert: acting
            // on the row while its text is being rewritten would end the edit
            // under their hands.
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .frame(width: 14, height: 14)

            TextField(Self.editPlaceholder, text: editDraftBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .fieldCaretFocus(request: editFocusRequest, placeholder: Self.editPlaceholder)
                .onSubmit { Task { await store.commitEditing() } }
                // Esc puts the row back the way it was: an abandoned edit is a
                // cancellation, not a save.
                .onExitCommand { store.cancelEditing() }
                .padding(.horizontal, 8)
                .frame(minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.07))
                )

            Spacer(minLength: 8)

            if let dueDate = item.dueDate {
                Text(Self.dueText(for: dueDate, isAllDay: item.isDueDateAllDay))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .monospacedDigit()
            }

            Button {
                Task { await store.commitEditing() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Nothing to write: the draft was cleared, or it still says what the
            // row already says. `rewrite` is the same rule the commit uses.
            .disabled(ReminderStore.rewrite(original: item.title, draft: store.editingDraft) == nil)
            .help("Save reminder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.045))
                .padding(.horizontal, 4)
        )
        .onExitCommand { store.cancelEditing() }
    }

    /// The edit draft's binding goes through the store's method rather than
    /// straight at the value, for the same reason the compose row's does: the
    /// store, not the view, is where this state lives and where its rules are.
    private var editDraftBinding: Binding<String> {
        Binding(
            get: { store.editingDraft },
            set: { store.updateEditingDraft($0) }
        )
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

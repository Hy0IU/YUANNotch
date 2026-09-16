import AppKit
import SwiftUI

struct NotebookView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var settingsStore: AppSettingsStore
    let imageStore: LocalImageStore
    @ObservedObject var fileShelfStore: FileShelfStore
    @ObservedObject var reminderStore: ReminderStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    @ObservedObject var drawerState: DrawerState
    @ObservedObject var editorInteractionState: EditorInteractionState
    let layout: NotchLayout
    let onOpenSettings: () -> Void

    /// The drawer's effective mode. Precedence lives in
    /// `NotebookWorkspaceState.showsReminders(persistedMode:)`.
    private var isRemindersMode: Bool {
        workspaceState.showsReminders(persistedMode: settingsStore.drawerMode)
    }

    var body: some View {
        ZStack(alignment: .top) {
            drawer
        }
        // Fill the panel and center the drawer inside it, so the collapse
        // animation always converges to the panel's center even if the panel
        // frame and the layout size ever disagree
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The drop action and the reveal signal both live here — this is the
        // only path AppKit actually delivers file drags to (its drag
        // destination resolution does not honour a hitTest override on the
        // hosting view, so an NSView-level claim never fires).
        //
        // Targeting is deliberately *reveal-only*: `false` does not retract
        // the shelf. SwiftUI reports `false` for every moment the drag is
        // over the editor, whose NSTextView accepts file drops itself, and
        // retracting on it made the shelf bounce up and down. The retract
        // happens in the controller once the drag session has really ended.
        .dropDestination(for: URL.self) { urls, _ in
            FileDragDiagnostics.log(
                """
                dropDestination action urls=\(urls.count) \
                shelfEnabled=\(settingsStore.isFileShelfEnabled) \
                draggingShelfItem=\(workspaceState.isDraggingShelfItem)
                """
            )
            guard settingsStore.isFileShelfEnabled, !workspaceState.isDraggingShelfItem else {
                workspaceState.isShelfDropTargeted = false
                return false
            }
            // G1: the shelf only exists on the notes surface, so a drop while
            // the drawer shows reminders is refused rather than swallowed.
            guard !isRemindersMode else {
                workspaceState.isShelfDropTargeted = false
                return false
            }
            return receiveDroppedFiles(urls)
        } isTargeted: { isTargeted in
            // Diagnostics only. The shelf's visibility has exactly one
            // authority — the controller's polling rule, which measures the
            // cursor against a strip anchored to the panel's bottom edge.
            // Letting this callback drive it too would reintroduce the second
            // source that made the shelf flicker.
            let mouse = NSEvent.mouseLocation
            FileDragDiagnostics.log(
                "swiftUI isTargeted=\(isTargeted) mouse=\(Int(mouse.x)),\(Int(mouse.y))"
            )
        }
    }

    private var drawer: some View {
        ZStack(alignment: .top) {
            expandedContent
                .frame(width: layout.expandedSize.width, height: layout.expandedSize.height)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .opacity(expandedContentOpacity)

            compactIcon
        }
        .frame(width: layout.expandedSize.width, height: layout.expandedSize.height, alignment: .top)
        .background(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98))
        .mask(alignment: .top) {
            panelShape
                .frame(width: revealWidth, height: revealHeight)
        }
        .overlay(alignment: .top) {
            panelShape
                .stroke(panelBorderColor, lineWidth: drawerState.isDockingTargeted ? 1.5 : 1)
                .frame(width: revealWidth, height: revealHeight)
        }
        .overlay(alignment: .bottom) {
            if drawerState.isExpanded {
                PanelDragHandle(isDetached: drawerState.isDetached)
                    .padding(.bottom, 1)
            }
        }
        .scaleEffect(drawerState.isBeingDragged ? 0.985 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: drawerState.isBeingDragged)
        .animation(.easeOut(duration: 0.14), value: drawerState.isDockingTargeted)
        .contentShape(Rectangle())
        .allowsHitTesting(drawerState.isExpanded)
        .overlay(alignment: .bottomTrailing) {
            // Visual indicator only — dragging is handled at the panel level
            // (see NotchPanelController.handleResizeMouseEvent).
            // Trailing padding tracks the visible (inset) right edge of the shape.
            if drawerState.isExpanded {
                ResizeGrip()
                    .padding(.trailing, panelSideInset + 8)
                    .padding(.bottom, 9)
            }
        }
    }

    private var expandedContent: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    // G7: the tab pager belongs to the notes surface. Hiding it
                    // in reminders mode is what keeps the toolbar from
                    // overflowing on a narrow drawer once the mode toggle is
                    // added.
                    if !isRemindersMode {
                        TabPagerControl(store: store, editorInteractionState: editorInteractionState)
                    }

                    Spacer(minLength: 0)

                    DrawerModeToggle(
                        mode: isRemindersMode ? .reminders : .notes,
                        showsLabels: layout.expandedSize.width >= 430
                    ) { mode in
                        workspaceState.fileDragForcesNotesMode = false
                        settingsStore.drawerMode = mode
                    }

                    // G6: "Clear" means clear the note, so it has no meaning
                    // while reminders are showing.
                    if !isRemindersMode {
                        Button(action: store.clear) {
                            Image(systemName: "trash")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(DarkIconButtonStyle())
                        .help("Clear")
                    }

                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(DarkIconButtonStyle())
                    .help("Settings")
                }
                .frame(height: toolbarHeight, alignment: .center)

                VStack(spacing: shelfSpacing) {
                    Group {
                        if isRemindersMode {
                            RemindersPanelView(
                                store: reminderStore,
                                size: editorSize,
                                onOpenSettings: onOpenSettings
                            )
                        } else {
                            MarkdownEditorPanel(
                                store: store,
                                imageStore: imageStore,
                                editorInteractionState: editorInteractionState,
                                isFileShelfToggleVisible: settingsStore.isFileShelfEnabled
                                    && !fileShelfStore.items.isEmpty,
                                isFileShelfCollapsed: workspaceState.isFileShelfCollapsed,
                                onToggleFileShelf: {
                                    withAnimation(shelfAnimation) {
                                        workspaceState.isFileShelfCollapsed.toggle()
                                    }
                                },
                                size: editorSize
                            )
                        }
                    }
                    .frame(width: editorSize.width, height: editorSize.height)
                    .background(Color(red: 0.06, green: 0.06, blue: 0.07))

                    if isFileShelfVisible {
                        FileShelfView(
                            store: fileShelfStore,
                            workspaceState: workspaceState,
                            size: fileShelfSize
                        )
                        .frame(width: fileShelfSize.width, height: fileShelfSize.height)
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.97, anchor: .bottom))
                        )
                    }
                }
                .animation(shelfAnimation, value: isFileShelfVisible)
            }
        }
        .padding(.top, toolbarTopPadding)
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.bottom, contentBottomPadding)
        .onAppear {
            editorInteractionState.onSelectionChange = { [weak store] range in
                guard let store else { return }
                store.updateSelection(for: store.activeTabID, range: range)
            }
            editorInteractionState.restoreSelection(store.selectionRange(for: store.activeTabID))
        }
        .onChange(of: store.activeTabID) { _, newTabID in
            editorInteractionState.restoreSelection(store.selectionRange(for: newTabID))
            editorInteractionState.requestLayoutRefresh(resetScroll: false)
        }
        .onChange(of: settingsStore.isFileShelfEnabled) { _, isEnabled in
            if !isEnabled {
                workspaceState.isFileShelfCollapsed = false
            }
        }
        .onChange(of: fileShelfStore.items.isEmpty) { _, isEmpty in
            if isEmpty {
                workspaceState.isFileShelfCollapsed = false
            }
        }
        .onDisappear {
            workspaceState.isShelfDropTargeted = false
            workspaceState.isDraggingShelfItem = false
        }
    }

    private var compactIcon: some View {
        Image(systemName: "note.text")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.82))
            .frame(width: layout.compactSize.width, height: layout.compactSize.height)
            .opacity(1 - drawerState.revealProgress)
    }

    private var revealWidth: CGFloat {
        interpolate(from: layout.compactSize.width, to: layout.expandedSize.width)
    }

    private var revealHeight: CGFloat {
        interpolate(from: layout.compactSize.height, to: layout.expandedSize.height)
    }

    private var topCornerRadius: CGFloat {
        interpolate(from: 0, to: CGFloat(settingsStore.expandedTopCornerRadius))
    }

    private var bottomCornerRadius: CGFloat {
        interpolate(from: 12, to: CGFloat(settingsStore.expandedBottomCornerRadius))
    }

    private var panelShape: DetachablePanelShape {
        DetachablePanelShape(
            attachedTopCornerRadius: topCornerRadius,
            attachedBottomCornerRadius: bottomCornerRadius,
            detachmentProgress: drawerState.detachmentProgress
        )
    }

    private var panelBorderColor: Color {
        drawerState.isDockingTargeted
            ? Color.accentColor.opacity(0.78)
            : Color.white.opacity(0.09)
    }

    private var panelSideInset: CGFloat {
        topCornerRadius * (1 - drawerState.detachmentProgress)
    }

    private var expandedContentOpacity: CGFloat {
        let progress = drawerState.revealProgress
        return min(max((progress - 0.42) / 0.34, 0), 1)
    }

    private var editorSize: CGSize {
        CGSize(
            width: layout.expandedSize.width - contentHorizontalPadding * 2,
            height: max(
                layout.expandedSize.height
                    - toolbarTopPadding
                    - contentBottomPadding
                    - toolbarHeight
                    - editorSpacing
                    - (isFileShelfVisible ? fileShelfHeight + shelfSpacing : 0),
                160
            )
        )
    }

    private var fileShelfSize: CGSize {
        CGSize(
            width: layout.expandedSize.width - contentHorizontalPadding * 2,
            height: fileShelfHeight
        )
    }

    private var fileShelfHeight: CGFloat {
        ShelfMetrics.shelfHeight(forDrawerHeight: layout.expandedSize.height)
    }

    private var shelfSpacing: CGFloat {
        8
    }

    private var isFileShelfVisible: Bool {
        // G2: the shelf belongs to the notes surface.
        !isRemindersMode
            && settingsStore.isFileShelfEnabled
            && (
                workspaceState.isShelfDropTargeted
                    || (!workspaceState.isFileShelfCollapsed && !fileShelfStore.items.isEmpty)
            )
    }

    private var shelfAnimation: Animation {
        .spring(response: 0.30, dampingFraction: 0.84)
    }

    private func receiveDroppedFiles(_ urls: [URL]) -> Bool {
        let didAcceptDrop = fileShelfStore.acceptDrop(urls)
        FileDragDiagnostics.log(
            "notebook receiveDroppedFiles accepted=\(didAcceptDrop) items=\(fileShelfStore.items.count)"
        )
        if didAcceptDrop {
            workspaceState.commitLandedFileDrop(to: &settingsStore.drawerMode)
        }
        workspaceState.isShelfDropTargeted = false
        return didAcceptDrop
    }

    private var toolbarTopPadding: CGFloat {
        let attachedPadding = layout.compactSize.height + 6
        return interpolate(
            from: attachedPadding,
            to: 34,
            progress: drawerState.detachmentProgress
        )
    }

    private var contentHorizontalPadding: CGFloat {
        // The NotchShape insets both side edges by the expanded top corner
        // radius (10), so add it back to keep a comfortable visible margin
        interpolate(from: 26, to: 18, progress: drawerState.detachmentProgress)
    }

    private var contentBottomPadding: CGFloat {
        18
    }

    private var toolbarHeight: CGFloat {
        28
    }

    private var editorSpacing: CGFloat {
        12
    }

    private func interpolate(from start: CGFloat, to end: CGFloat) -> CGFloat {
        interpolate(from: start, to: end, progress: drawerState.revealProgress)
    }

    private func interpolate(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * min(max(progress, 0), 1)
    }
}

/// Two-segment switch between the notes surface and the reminders surface.
///
/// Labels collapse to icons on a narrow drawer: at the 360pt minimum width the
/// toolbar also carries the tab pager, the settings button, and (in notes mode)
/// "Clear", so spelled-out segments would not fit.
private struct DrawerModeToggle: View {
    let mode: DrawerMode
    let showsLabels: Bool
    let onSelect: (DrawerMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DrawerMode.allCases) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: candidate.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                        if showsLabels {
                            Text(candidate.title)
                                .font(.system(size: 11, weight: candidate == mode ? .semibold : .regular))
                        }
                    }
                    .foregroundStyle(.white.opacity(candidate == mode ? 0.88 : 0.48))
                    .padding(.horizontal, showsLabels ? 7 : 6)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(candidate == mode ? 0.1 : 0))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(candidate == .notes ? "Show notes" : "Show Apple Reminders")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.045))
        )
    }
}

private struct PanelDragHandle: View {
    let isDetached: Bool
    @State private var isHovering = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(.white.opacity(isHovering ? 0.72 : 0.46))
            .frame(width: 36, height: 4)
            .frame(width: 72, height: 18)
            .contentShape(Rectangle())
            .pointingHandCursor()
            .help(isDetached ? "Drag to move; double-click to return to notch" : "Drag down to float")
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

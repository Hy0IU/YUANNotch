import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class NotchPanelController: NSObject {
    private let store = NoteStore()
    private let settingsStore = AppSettingsStore()
    private let imageStore = LocalImageStore()
    private let fileShelfStore = FileShelfStore()
    private let workspaceState = NotebookWorkspaceState()
    /// Drawer animation state is per display: when the mouse jumps to
    /// another screen mid-collapse, the outgoing drawer finishes its
    /// collapse animation while the incoming one expands — a single shared
    /// state would snap the outgoing panel back open for a frame.
    private var drawerStates: [String: DrawerState] = [:]

    private func drawerState(for key: String) -> DrawerState {
        if let existing = drawerStates[key] { return existing }
        let state = DrawerState()
        drawerStates[key] = state
        return state
    }

    private let editorInteractionState = EditorInteractionState()
    private lazy var settingsWindowController = SettingsWindowController(settingsStore: settingsStore)
    private let displayPanelRegistry = DisplayPanelRegistry()
    private var fileDragTrackingState = FileDragTrackingState()
    /// One drawer panel per display, keyed by screen uniqueID. A window that
    /// has been key on one display gets asynchronously "returned" to it by
    /// the Window Server when later shown on another display — so a drawer
    /// panel never leaves its own display.
    /// The drawer panel currently shown (on `drawerScreen`) while expanded.
    private var activeDrawerPanel: NotchPanel?
    /// Each drawer panel owns its content view permanently. Moving one
    /// shared view between windows makes the Window Server relocate the
    /// receiving window onto the screen where the view was last visible.
    private var activeHostingView: FirstMouseHostingView<NotebookView>?
    private var mousePollingTimer: Timer?
    private var mouseEventMonitor: MouseEventMonitor?
    private var isExpanded = false
    /// True while the drawer is open only as a preview for an incoming file
    /// drag, with the compact panel deliberately still on screen because it
    /// owns the live drag session.
    private var isRevealedForFileDrag = false
    private var currentScreen: NSScreen?
    private var drawerScreen: NSScreen?
    private var activeMenuTrackingCount = 0
    private var collapseTask: DispatchWorkItem?
    /// Consecutive 60Hz ticks in which the shelf should no longer be shown.
    /// The hide is held off for a few ticks so a single odd sample can't
    /// blink the shelf while a drag is running.
    private var pendingHideTickCount = 0
    /// ~0.33s of grace before the shelf retracts, so travelling from the notch
    /// down to the shelf does not blink it while parking over the editor does
    /// dismiss it.
    private static let hideTicksBeforeRetract = 20
    /// Set from the compact notch panel's AppKit drag callbacks: a file drag
    /// over the notch strip is what reveals the shelf on its way in.
    private var isCompactDragTargeted = false
    private var disarmTickCount = 0
    private static let disarmTicksInterval = 30

    override init() {
        super.init()
        startMousePolling()
        observeScreenChanges()
        observeGlobalSelectionMouseEvents()
        observeMenuTracking()
    }

    private func makeDrawerPanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            // Atoll-style window recipe: .borderless + .nonactivatingPanel,
            // no .fullSizeContentView. Two effects with tiling WMs
            // (AeroSpace):
            // 1. No usable AX fullscreen button -> AeroSpace's
            //    isDialogHeuristic floats the drawer instead of tiling it
            //    (previously it dragged the drawer onto the focused
            //    workspace's display).
            // 2. Unlike an AX subrole masquerade, the drawer stays a real
            //    (floating) window in the WM's tree, so focusing it updates
            //    the WM's focus model and its click-arbitration
            //    (clickedMonitor.activeWorkspace != focus.workspace ->
            //    focusWorkspace) no longer yanks keyboard focus back right
            //    after the first click.
            // .nonactivatingPanel (Spotlight-style): the drawer can become
            // key for typing WITHOUT making the app frontmost. Activating
            // the app would emit an AX focus event that window managers
            // answer by summoning the workspace that last held one of our
            // normal windows — visibly switching workspaces on another
            // display.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel(panel)
        panel.onMouseEvent = { [weak self, weak panel] event in
            guard let self, let panel else { return }
            if self.handleResizeMouseEvent(event) { return }
            self.editorInteractionState.handleMouseEvent(event, searchingIn: panel.contentView)
        }
        return panel
    }

    private func drawerPanel(for screen: NSScreen?) -> NotchPanel {
        let key = screen?.uniqueID ?? "unknown-screen"
        if let existing = displayPanelRegistry.drawerPanel(for: key) { return existing }
        let panel = makeDrawerPanel()
        displayPanelRegistry.setDrawerPanel(panel, for: key)
        return panel
    }

    func flushPendingSave() {
        store.flushPendingSave()
    }

    func showDocked() {
        currentScreen = NotchGeometry.targetScreen()
        let layout = NotchGeometry.layout(for: currentScreen, customSize: settingsStore.customExpandedSize)
        rebuildContent(layout: layout)
        rebuildAllHotPanels()
        isExpanded = false
        isRevealedForFileDrag = false
        for state in drawerStates.values {
            state.isExpanded = false
            state.revealProgress = 0
        }
    }

    /// Shows the drawer on the screen containing `currentScreen`, using the
    /// drawer panel dedicated to that display.
    ///
    /// The drawer is ONLY ever ordered front, never programmatically made
    /// key or activated — programmatic focus changes on multi-display setups
    /// cause erratic window placement. The drawer becomes key naturally when
    /// the user clicks into it (first-mouse is accepted).
    func expand(animated: Bool) {
        if isExpanded {
            // Already open on this display: nothing to do.
            guard drawerScreen?.uniqueID != currentScreen?.uniqueID else { return }
            // Hovering/clicking another display's notch hands off: the
            // outgoing drawer keeps playing its collapse animation (its
            // state is per-display) while the new one expands on top.
            handoffCollapse()
        }
        let layout = NotchGeometry.layout(for: currentScreen, customSize: settingsStore.customExpandedSize)
        cancelCollapse()
        isExpanded = true
        drawerScreen = currentScreen
        workspaceState.isShelfDropTargeted = false
        rebuildContent(layout: layout)
        // Rebuild hot panels with the same layout so compact widths match exactly
        rebuildAllHotPanels()
        let panel = drawerPanel(for: currentScreen)
        activeDrawerPanel = panel
        activeHostingView = hostingView(for: currentScreen, layout: layout)
        panel.setFrame(drawerFrame(for: layout, screen: currentScreen), display: true)
        panel.orderFrontRegardless()
        // Never take the compact panel away while it is the window AppKit is
        // delivering the file drag to: ordering out the live drag destination
        // mid-session makes the drag feedback flap between the two windows and
        // the drop is lost. On a file-drag reveal the compact panel therefore
        // stays on screen — above the drawer — and stands down when the drag
        // has moved on or ended.
        if isFileDragInProgress() {
            isRevealedForFileDrag = true
            hotPanelForScreen(currentScreen)?.orderFrontRegardless()
        } else {
            isRevealedForFileDrag = false
            hotPanelForScreen(currentScreen)?.orderOut(nil)
        }
        setDrawerExpanded(true, animated: animated, for: currentScreen?.uniqueID ?? "unknown-screen")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self else { return }
            guard self.isExpanded else { return }
            // If the user already clicked into the editor, don't rebuild the
            // editing session from under them: re-setting the first responder
            // tears down the field editor (the caret visibly "blips" out and
            // typing is dead until the next click).
            let userAlreadyEditing = panel.isKeyWindow && panel.firstResponder is NSTextView
            if !userAlreadyEditing {
                self.editorInteractionState.restoreSelection(
                    self.store.selectionRange(for: self.store.activeTabID),
                    searchingIn: self.activeHostingView
                )
                self.editorInteractionState.requestFocus(searchingIn: self.activeHostingView)
            }
            self.editorInteractionState.requestLayoutRefresh(searchingIn: self.activeHostingView)
            // The editor's text view arms itself for drags shortly after it
            // joins the window; disarm it as soon as it is definitely there,
            // in addition to the periodic sweep.
            EditorFileDropGuard.disarm(in: self.activeHostingView)
        }
    }

    /// Cross-display handoff: unlike `collapse`, the outgoing panel stays
    /// visible until its collapse animation has played out, so the two
    /// displays animate independently.
    private func handoffCollapse() {
        let oldPanel = activeDrawerPanel
        let oldKey = drawerScreen?.uniqueID
        if let range = editorInteractionState.currentSelectionRange() {
            store.updateSelection(for: store.activeTabID, range: range)
        }
        isExpanded = false
        drawerScreen = nil
        if let oldKey {
            setDrawerExpanded(false, animated: true, for: oldKey)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            // The user may have switched back to this display meanwhile
            // (A→B→A within the animation window) — don't kill its panel.
            let reclaimed = self.isExpanded && self.drawerScreen?.uniqueID == oldKey
            if !reclaimed {
                oldPanel?.orderOut(nil)
            }
            if !reclaimed, let oldKey, let screen = NSScreen.screens.first(where: { $0.uniqueID == oldKey }) {
                self.hotPanelForScreen(screen)?.orderFrontRegardless()
            }
        }
    }

    func collapse(animated: Bool) {
        guard isExpanded else { return }
        if let range = editorInteractionState.currentSelectionRange() {
            store.updateSelection(for: store.activeTabID, range: range)
        }
        isExpanded = false
        isRevealedForFileDrag = false
        let collapsingKey = drawerScreen?.uniqueID
        drawerScreen = nil
        setDrawerExpanded(false, animated: animated, for: collapsingKey ?? "unknown-screen")

        if animated {
            // SwiftUI animation: easeOut 0.16s
            // Order out drawer right as animation completes, then show hot panels
            // SwiftUI easeOut is 0.16s; use 0.20s to ensure animation is fully complete
            let collapsingPanel = activeDrawerPanel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard let self else { return }
                if self.isExpanded {
                    // Re-expanded meanwhile; only hide the collapsing panel if
                    // the new expansion uses a different display's panel
                    if self.activeDrawerPanel !== collapsingPanel {
                        collapsingPanel?.orderOut(nil)
                        // The collapsing display's hot panel must come back
                        // even though a new drawer opened on another display
                        // (rebuildAllHotPanels does not re-show existing
                        // hidden panels — only this restores it).
                        self.showAllHotPanels()
                        self.hotPanelForScreen(self.drawerScreen)?.orderOut(nil)
                    }
                    return
                }
                // Show hot panels before removing the drawer so the handoff
                // overlaps instead of leaving a one-frame gap
                self.showAllHotPanels()
                collapsingPanel?.orderOut(nil)
            }
        } else {
            activeDrawerPanel?.orderOut(nil)
            showAllHotPanels()
        }
    }

    private func configurePanel(_ panel: NotchPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
    }

    private func makeNotebookView(layout: NotchLayout, drawerState: DrawerState) -> NotebookView {
        NotebookView(
            store: store,
            settingsStore: settingsStore,
            imageStore: imageStore,
            fileShelfStore: fileShelfStore,
            workspaceState: workspaceState,
            drawerState: drawerState,
            editorInteractionState: editorInteractionState,
            layout: layout,
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
    }

    /// Get-or-create the drawer content for a display. Each panel keeps its
    /// own hosting view for its entire lifetime — views never move between
    /// windows (doing so makes the Window Server relocate the receiving
    /// window onto the screen where the view was last visible).
    private func hostingView(for screen: NSScreen?, layout: NotchLayout) -> FirstMouseHostingView<NotebookView> {
        let key = screen?.uniqueID ?? "unknown-screen"
        if let existing = displayPanelRegistry.drawerHostingView(for: key) { return existing }
        let host = DrawerFileDropHostingView(rootView: makeNotebookView(layout: layout, drawerState: drawerState(for: key)))
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        configureDrawerFileDrop(host)
        displayPanelRegistry.setDrawerHostingView(host, for: key)
        displayPanelRegistry.drawerPanel(for: key)?.contentView = host
        return host
    }

    private func rebuildContent(layout: NotchLayout? = nil) {
        let layout = layout ?? NotchGeometry.layout(for: currentScreen, customSize: settingsStore.customExpandedSize)
        // Rebuild ONLY the active display's content. Another display's
        // panel may be mid-collapse with its own per-screen layout —
        // replacing its view would shift the collapse interpolation
        // endpoints (compact sizes differ between notched and fallback
        // displays) and glitch the running animation. Inactive displays
        // rebuild on their next expand.
        let key = (drawerScreen ?? currentScreen)?.uniqueID ?? "unknown-screen"
        if let host = displayPanelRegistry.drawerHostingView(for: key) {
            host.rootView = makeNotebookView(layout: layout, drawerState: drawerState(for: key))
            // A rebuild installs a fresh editor view, which arms itself for
            // file drops a moment later; the polling sweep catches that.
            EditorFileDropGuard.disarm(in: host)
        }
    }

    private func rebuildAllHotPanels() {
        let screens = NSScreen.screens
        var activeScreenIDs = Set<String>()

        for screen in screens {
            let id = screen.uniqueID
            activeScreenIDs.insert(id)

            // Per-screen layout: each display gets its own compact size
            // (notched built-in vs. fallback for external displays).
            let layout = NotchGeometry.layout(for: screen, customSize: settingsStore.customExpandedSize)
            let frame = hotFrame(for: layout, screen: screen)
            let hotView = CompactNotchView(layout: layout, onTap: { [weak self, weak screen] in
                guard let self, let screen else { return }
                self.currentScreen = screen
                self.expand(animated: true)
            })
            if let existing = displayPanelRegistry.hotHostingView(for: id),
               let panel = displayPanelRegistry.hotPanel(for: id) {
                existing.rootView = hotView
                panel.setFrame(frame, display: true)
            } else {
                let panel = NotchPanel(
                    contentRect: .zero,
                    // .nonactivatingPanel: clicking the compact notch must
                    // not activate the app either (see makeDrawerPanel).
                    styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.allowsKeyboardFocus = false
                configurePanel(panel)
                panel.onMouseEvent = { [weak self, weak screen] event in
                    guard let self, let screen else { return }
                    self.currentScreen = screen
                    guard event.type == .leftMouseDown else { return }
                    self.expand(animated: true)
                }
                let host = CompactFileDropHostingView(rootView: hotView)
                host.translatesAutoresizingMaskIntoConstraints = false
                host.wantsLayer = true
                host.layer?.masksToBounds = true
                configureCompactFileDrop(host, screen: screen)
                panel.contentView = host
                panel.setFrame(frame, display: true)
                panel.orderFrontRegardless()
                displayPanelRegistry.setHotPanel(panel, for: id)
                displayPanelRegistry.setHotHostingView(host, for: id)
            }
        }

        for (id, panel) in displayPanelRegistry.hotPanelEntries where !activeScreenIDs.contains(id) {
            panel.orderOut(nil)
            displayPanelRegistry.removeHotPanel(for: id)
            displayPanelRegistry.removeHotHostingView(for: id)
        }
    }

    private func hotPanelForScreen(_ screen: NSScreen?) -> NotchPanel? {
        guard let screen else { return nil }
        return displayPanelRegistry.hotPanel(for: screen.uniqueID)
    }

    private func configureCompactFileDrop(_ host: CompactFileDropHostingView<CompactNotchView>, screen: NSScreen) {
        host.onFileDragTargeted = { [weak self, weak screen] targeted in
            guard let self, let screen else { return }
            self.isCompactDragTargeted = targeted

            guard targeted else {
                // The drag has left the compact panel. Whatever is under it
                // now owns the session, so the compact panel may stand down —
                // but only after AppKit has finished re-targeting, hence the
                // async hop.
                DispatchQueue.main.async { [weak self] in
                    self?.finishFileDragRevealIfNeeded()
                }
                return
            }

            // A file drag brings the drawer up whatever the shelf setting is:
            // the same gesture also carries a path the user may want to work
            // with, and the shelf keeps itself hidden when it is disabled.
            // On the drawer's own display this callback can't fire while the
            // drawer is expanded (its hot panel is ordered out); on another
            // display, hand the drawer over mid-drag.
            guard !self.isExpanded || self.drawerScreen?.uniqueID != screen.uniqueID else { return }
            self.currentScreen = screen
            self.expand(animated: true)
        }
        host.onFilesDropped = { [weak self] urls in
            self?.receiveDroppedFiles(urls) ?? false
        }
    }

    private func configureDrawerFileDrop(_ host: DrawerFileDropHostingView<NotebookView>) {
        // Claim external file drags only when the shelf can actually accept
        // them, and never claim drags that originate from the shelf itself
        // (dragging chips out writes file URLs to the drag pasteboard too).
        host.isFileDragActive = { [weak self] in
            guard let self else { return false }
            return self.settingsStore.isFileShelfEnabled
                && self.isFileDragInProgress()
                && !self.workspaceState.isDraggingShelfItem
        }
        host.onFileDragTargeted = { [weak self] targeted in
            guard let self, targeted else { return }
            // Reveal-only, for the same reason as the SwiftUI callback: the
            // show/hide decision must not flap with the cursor position.
            FileDragDiagnostics.log("drawer drag entered -> reveal shelf")
            withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                self.workspaceState.isShelfDropTargeted = true
            }
        }
        host.onFilesDropped = { [weak self] urls in
            self?.receiveDroppedFiles(urls) ?? false
        }
    }

    private func receiveDroppedFiles(_ urls: [URL]) -> Bool {
        let accepted = fileShelfStore.acceptDrop(urls)
        FileDragDiagnostics.log(
            "panel receiveDroppedFiles accepted=\(accepted) items=\(fileShelfStore.items.count)"
        )
        guard settingsStore.isFileShelfEnabled, accepted else { return false }
        // Reveal the shelf as drop feedback. Defer so AppKit can finish the
        // drop callback before the window order changes — replacing the
        // window that owns an active dragging destination is not allowed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isExpanded else {
                self.finishFileDragRevealIfNeeded()
                return
            }
            self.expand(animated: true)
        }
        return true
    }

    private func showAllHotPanels() {
        for (_, panel) in displayPanelRegistry.hotPanelEntries {
            panel.orderFrontRegardless()
        }
    }

    private func setDrawerExpanded(_ expanded: Bool, animated: Bool, for key: String) {
        let state = drawerState(for: key)
        guard animated else {
            state.isExpanded = expanded
            state.revealProgress = expanded ? 1 : 0
            return
        }

        let animation: Animation = expanded
            ? .spring(response: 0.28, dampingFraction: 0.86)
            : .easeOut(duration: 0.16)

        withAnimation(animation) {
            state.isExpanded = expanded
            state.revealProgress = expanded ? 1 : 0
        }
    }

    private func startMousePolling() {
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(mousePollingTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        mousePollingTimer = timer
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }



    /// Global monitors for the mouse *gestures* that can start outside our
    /// windows and still affect the drawer. The file-drag detector does not
    /// depend on these anymore — it polls the drag pasteboard instead, so a
    /// monitor that never fires (sandboxed or unauthorized process) can no
    /// longer silently disable it.
    private func observeGlobalSelectionMouseEvents() {
        mouseEventMonitor = MouseEventMonitor(
            onMouseDragged: { [weak self] _ in
                Task { @MainActor in
                    self?.editorInteractionState.noteGlobalMouseDragged()
                }
            },
            onMouseUp: { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.editorInteractionState.noteGlobalMouseUp()
                    self.workspaceState.isDraggingShelfItem = false
                }
            }
        )
    }

    private func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        cancelCollapse()
        // If the drawer was open on a display that disappeared, fall back
        if let drawerScreen, !NSScreen.screens.contains(where: { $0.uniqueID == drawerScreen.uniqueID }) {
            self.drawerScreen = nil
        }
        let screen = drawerScreen ?? currentScreen ?? NotchGeometry.targetScreen()
        let layout = NotchGeometry.layout(for: screen, customSize: settingsStore.customExpandedSize)
        // Drop drawer panels belonging to displays that are gone
        let connectedIDs = Set(NSScreen.screens.map(\.uniqueID))
        for (key, panel) in displayPanelRegistry.drawerPanelEntries where !connectedIDs.contains(key) {
            if activeDrawerPanel === panel {
                activeDrawerPanel = nil
                activeHostingView = nil
            }
            panel.orderOut(nil)
            displayPanelRegistry.removeDrawerPanel(for: key)
            displayPanelRegistry.removeDrawerHostingView(for: key)
            drawerStates.removeValue(forKey: key)
        }
        rebuildAllHotPanels()
        if isExpanded {
            rebuildContent(layout: layout)
            activeDrawerPanel?.setFrame(drawerFrame(for: layout, screen: screen), display: true)
        }
        // The notification can fire while display frames are still mid-transition;
        // rebuild once more after the geometry settles so panels never keep
        // stale (possibly off-screen) frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.rebuildAllHotPanels()
        }
    }

    @objc private func mousePollingTick(_ timer: Timer) {
        // Keep the drag-pasteboard baseline up to date while no button is
        // held; during a drag the baseline stays frozen so the session's
        // pasteboard write keeps reading as "changed".
        let pasteboard = NSPasteboard(name: .drag)
        if !Self.isLeftMouseButtonDown {
            fileDragTrackingState.markPasteboardSettled(pasteboard)
        }
        updateShelfReveal()
        if !isFileDragInProgress() {
            isCompactDragTargeted = false
            finishFileDragRevealIfNeeded()
        }
        // The editor's text view arms itself as a file-drop destination
        // shortly after it joins a window; sweep often enough that a file
        // drag can never find it armed.
        disarmTickCount += 1
        if disarmTickCount >= Self.disarmTicksInterval {
            disarmTickCount = 0
            EditorFileDropGuard.disarm(in: activeHostingView)
        }
        handleMouseLocation(NSEvent.mouseLocation)
    }

    /// Shows the shelf while a file drag is over the shelf's own strip (or
    /// over the compact notch, which is where a drag toward the notch lands),
    /// and hides it once the drag has been elsewhere for a moment.
    ///
    /// Both edges are derived from the *panel frame* and the cursor position,
    /// so they stand still during a drag — the shelf changing the editor's
    /// height cannot move the trigger region out from under the cursor, which
    /// is what made the shelf oscillate before. The hide is held off for a
    /// few ticks so travelling from the notch down to the shelf does not
    /// blink it, while parking the drag over the editor does dismiss it.
    private func updateShelfReveal() {
        guard !workspaceState.isPreviewingShelfItem else { return }

        let isFileDrag = settingsStore.isFileShelfEnabled && isFileDragInProgress()
        let mouseLocation = NSEvent.mouseLocation
        let isOverShelfStrip = activeDrawerPanel.map {
            shelfRevealStrip(for: $0.frame).contains(mouseLocation)
        } ?? false
        let shouldReveal = isFileDrag
            && (isOverShelfStrip || isCompactDragTargeted)
            && !workspaceState.isDraggingShelfItem

        if shouldReveal {
            pendingHideTickCount = 0
        } else if workspaceState.isShelfDropTargeted {
            pendingHideTickCount += 1
        } else {
            pendingHideTickCount = 0
        }

        let keepRevealed = shouldReveal
            || (workspaceState.isShelfDropTargeted && pendingHideTickCount < Self.hideTicksBeforeRetract)
        guard keepRevealed != workspaceState.isShelfDropTargeted else { return }

        FileDragDiagnostics.log(
            """
            shelf reveal=\(keepRevealed) fileDrag=\(isFileDrag) overShelfStrip=\(isOverShelfStrip) \
            compactTargeted=\(isCompactDragTargeted) mouse=\(Int(mouseLocation.x)),\(Int(mouseLocation.y))
            """
        )
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            workspaceState.isShelfDropTargeted = keepRevealed
        }
    }

    /// The shelf's strip in screen coordinates: its own height plus the
    /// content padding and slack above it, anchored to the panel's bottom.
    private func shelfRevealStrip(for panelFrame: NSRect) -> NSRect {
        let height = ShelfMetrics.shelfHeight(forDrawerHeight: panelFrame.height)
            + ShelfMetrics.revealBandSlack
        return NSRect(
            x: panelFrame.minX,
            y: panelFrame.minY,
            width: panelFrame.width,
            height: height
        )
    }

    @objc private func menuTrackingDidBegin(_ notification: Notification) {
        activeMenuTrackingCount += 1
        cancelCollapse()
    }

    @objc private func menuTrackingDidEnd(_ notification: Notification) {
        activeMenuTrackingCount = max(0, activeMenuTrackingCount - 1)
        guard activeMenuTrackingCount == 0, isExpanded else { return }
        handleMouseLocation(NSEvent.mouseLocation)
    }

    /// Stands the compact panel down once it is no longer the drag's owner.
    ///
    /// Called only from moments where the drag has already moved off the
    /// compact panel (or the session is over), or after an async hop out of a
    /// drop callback — never while the compact panel is still the active
    /// drag destination.
    private func finishFileDragRevealIfNeeded() {
        guard isRevealedForFileDrag else { return }
        isRevealedForFileDrag = false
        guard isExpanded else { return }
        FileDragDiagnostics.log("file-drag reveal finished: compact panel stands down")
        hotPanelForScreen(drawerScreen)?.orderOut(nil)
    }

    private func handleMouseLocation(_ point: NSPoint) {
        if isExpanded {
            if activeMenuTrackingCount > 0 {
                cancelCollapse()
                return
            }

            if editorInteractionState.isDraggingSelection {
                cancelCollapse()
                return
            }

            if isResizingDrawer {
                cancelCollapse()
                return
            }

            if workspaceState.isDraggingShelfItem {
                cancelCollapse()
                return
            }

            if workspaceState.isPreviewingShelfItem {
                cancelCollapse()
                return
            }

            // An external file drag pins the drawer open: the drag wanders
            // in and out of the stay region while the user aims at the
            // shelf, and re-triggering expand/collapse on each crossing
            // reads as flicker. (Shelf-item drags already returned above.)
            if isFileDragInProgress() {
                // Dragging toward another display's notch hands the drawer
                // over; the plain quick-handoff below requires an
                // unpressed button, which a drag never satisfies.
                for screenID in displayPanelRegistry.hotDisplayIDs where screenID != drawerScreen?.uniqueID {
                    guard let screen = NSScreen.screens.first(where: { $0.uniqueID == screenID }) else { continue }
                    let layout = NotchGeometry.layout(for: screen, customSize: settingsStore.customExpandedSize)
                    if fileDropFrame(for: layout, screen: screen).contains(point) {
                        currentScreen = screen
                        expand(animated: true)
                        return
                    }
                }
                cancelCollapse()
                return
            }

            // Quick handoff: hovering another display's notch while this
            // drawer is open switches over immediately, without waiting for
            // the collapse to play out first.
            if settingsStore.triggerMode == .hover, NSEvent.pressedMouseButtons & 1 == 0 {
                for (screenID, panel) in displayPanelRegistry.hotPanelEntries where screenID != drawerScreen?.uniqueID {
                    if panel.frame.insetBy(dx: 0, dy: -6).contains(point) {
                        currentScreen = NSScreen.screens.first { $0.uniqueID == screenID }
                        expand(animated: true)
                        return
                    }
                }
            }

            if isPointInExpandedStayRegion(point) {
                cancelCollapse()
            } else {
                scheduleCollapse()
            }
            return
        }

        // A file being dragged toward the notch brings the drawer up. This is
        // deliberately independent of the file-shelf setting: dragging a file
        // is also how a path is carried around, and the drawer is where it can
        // be worked with. The shelf itself only appears when it is enabled.
        if isFileDragInProgress() {
            for screenID in displayPanelRegistry.hotDisplayIDs {
                guard let screen = NSScreen.screens.first(where: { $0.uniqueID == screenID }) else { continue }
                let layout = NotchGeometry.layout(for: screen, customSize: settingsStore.customExpandedSize)
                if fileDropFrame(for: layout, screen: screen).contains(point) {
                    currentScreen = screen
                    expand(animated: true)
                    break
                }
            }
            return
        }

        // Don't expand on hover while the mouse button is held (e.g. dragging)
        if settingsStore.triggerMode == .hover, NSEvent.pressedMouseButtons & 1 == 0 {
            for (screenID, panel) in displayPanelRegistry.hotPanelEntries {
                let activationZone = panel.frame.insetBy(dx: 0, dy: -6)
                if activationZone.contains(point) {
                    currentScreen = NSScreen.screens.first { $0.uniqueID == screenID }
                    expand(animated: true)
                    break
                }
            }
        }
    }

    private func scheduleCollapse() {
        guard collapseTask == nil else { return }
        guard activeMenuTrackingCount == 0 else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseTask = nil
            guard self.activeMenuTrackingCount == 0 else { return }
            guard !self.editorInteractionState.isDraggingSelection else { return }
            guard !self.isResizingDrawer else { return }
            guard !self.workspaceState.isDraggingShelfItem else { return }
            guard !self.workspaceState.isPreviewingShelfItem else { return }
            guard !self.isFileDragInProgress() else { return }
            guard !self.isPointInExpandedStayRegion(NSEvent.mouseLocation) else { return }
            self.collapse(animated: true)
        }

        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: task)
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }



    private func isPointInExpandedStayRegion(_ point: NSPoint) -> Bool {
        let margin: CGFloat = 10
        let layout = NotchGeometry.layout(for: currentScreen, customSize: settingsStore.customExpandedSize)
        let hotRect = hotFrame(for: layout, screen: currentScreen)
        if hotRect.contains(point) { return true }
        guard let panel = activeDrawerPanel else { return false }
        return panel.frame.insetBy(dx: -margin, dy: -margin).contains(point)
    }

    private var isResizingDrawer = false
    private var resizeGrabOffset: CGSize = .zero

    /// Bottom-right hot zone of the drawer panel, in screen coordinates.
    /// Aligned to the visible corner: the NotchShape insets the right edge
    /// by the expanded top corner radius (10).
    private var drawerGripRect: NSRect {
        guard let frame = activeDrawerPanel?.frame else { return .zero }
        // Generous hot zone ending at the visible (inset) right edge,
        // so the grip is easy to grab
        return NSRect(x: frame.maxX - 58, y: frame.minY, width: 48, height: 44)
    }

    /// Panel-level resize handling. This lives on the panel (not a SwiftUI gesture)
    /// because rebuildContent recreates the SwiftUI view tree on every size change,
    /// which corrupts DragGesture translation state mid-drag.
    private func handleResizeMouseEvent(_ event: NSEvent) -> Bool {
        guard isExpanded else {
            isResizingDrawer = false
            return false
        }

        switch event.type {
        case .leftMouseDown:
            let mouse = NSEvent.mouseLocation
            guard drawerGripRect.contains(mouse), let panel = activeDrawerPanel else { return false }
            isResizingDrawer = true
            let frame = panel.frame
            resizeGrabOffset = CGSize(width: frame.maxX - mouse.x, height: mouse.y - frame.minY)
            return true

        case .leftMouseDragged where isResizingDrawer:
            resizeDrawer(to: NSEvent.mouseLocation)
            return true

        case .leftMouseUp where isResizingDrawer:
            isResizingDrawer = false
            return true

        default:
            return false
        }
    }

    private func resizeDrawer(to mouse: NSPoint) {
        guard let panel = activeDrawerPanel, let screen = panel.screen else { return }
        let frame = panel.frame
        let centerX = screen.frame.midX

        // Keep the grabbed point under the mouse. The panel stays horizontally
        // centered, so the width must grow twice as fast as the right edge moves.
        let targetRightEdge = mouse.x + resizeGrabOffset.width
        let targetBottomEdge = mouse.y - resizeGrabOffset.height
        let proposed = CGSize(
            width: (targetRightEdge - centerX) * 2,
            height: frame.maxY - targetBottomEdge
        )

        // Route through NotchGeometry so the panel frame always matches the layout
        // (including screen-edge clamping) — a mismatch shifts the collapse animation off-center
        let layout = NotchGeometry.layout(for: screen, customSize: proposed)
        let size = layout.expandedSize
        guard size != frame.size else { return }

        let newX = centerX - size.width / 2
        let newY = frame.maxY - size.height
        panel.setFrame(NSRect(x: newX, y: newY, width: size.width, height: size.height), display: true)
        settingsStore.customExpandedSize = size
        rebuildContent(layout: layout)
    }

    func openSettings() {
        cancelCollapse()
        if isExpanded {
            collapse(animated: true)
        }
        settingsWindowController.show()
    }

    private func hotFrame(for layout: NotchLayout, screen: NSScreen?) -> NSRect {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return frame(for: layout.compactSize, topY: screenFrame.maxY + layout.compactTopOffset, in: screenFrame)
    }

    /// Extended drop target below the compact notch, so an approaching file
    /// drag reveals the drawer before the cursor reaches the tiny notch area.
    private func fileDropFrame(for layout: NotchLayout, screen: NSScreen?) -> NSRect {
        var frame = hotFrame(for: layout, screen: screen)
        frame.origin.y -= 28
        frame.size.height += 28
        return frame
    }

    private var lastLoggedDragActive = false

    private func isFileDragInProgress() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        let isButtonDown = Self.isLeftMouseButtonDown
        let isActive = fileDragTrackingState.isFileDragInProgress(
            isLeftMouseButtonDown: isButtonDown,
            pasteboard: pasteboard
        )
        if isActive != lastLoggedDragActive {
            lastLoggedDragActive = isActive
            FileDragDiagnostics.log(
                """
                dragActive=\(isActive) buttonDown=\(isButtonDown) \
                dragCC=\(pasteboard.changeCount) \
                hasFileURL=\(FileDropPasteboardReader.containsFileURLs(pasteboard))
                """
            )
        }
        return isActive
    }

    /// Whether the left mouse button is down, sampled from the session event
    /// state in addition to the physical button.
    ///
    /// `NSEvent.pressedMouseButtons` reports the physical HID button, which
    /// never goes down for gestures such as three-finger drag or
    /// tap-and-drag: the system synthesizes the mouse events without a
    /// physical press, so a drag driven that way was invisible to the file
    /// drag detector and every feature gated on it silently did nothing.
    /// The combined session state follows the synthesized events, so it
    /// recognises every gesture. Both are read live, so the state can never
    /// go stale and pin the drawer open.
    private static var isLeftMouseButtonDown: Bool {
        NSEvent.pressedMouseButtons & 1 == 1
            || CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    private func drawerFrame(for layout: NotchLayout, screen: NSScreen?) -> NSRect {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topY = screenFrame.maxY + layout.expandedTopOffset
        return frame(for: layout.expandedSize, topY: topY, in: screenFrame)
    }

    private func frame(for size: NSSize, topY: CGFloat, in screenFrame: NSRect) -> NSRect {
        let x = screenFrame.midX - size.width / 2
        let y = topY - size.height

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

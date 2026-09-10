import AppKit
import SwiftUI

@MainActor
final class NotchPanel: NSPanel {
    var onMouseEvent: ((NSEvent) -> Void)?
    /// Hot (compact) panels should never take keyboard focus; if they stay
    /// in the window cycle, app activation can make the Window Server drag
    /// them onto the active display.
    var allowsKeyboardFocus = true

    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { allowsKeyboardFocus }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
            onMouseEvent?(event)
        }

        super.sendEvent(event)
    }
}

@MainActor
class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

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

    private func drawerState(for screen: NSScreen?) -> DrawerState {
        drawerState(for: screen?.uniqueID ?? "unknown-screen")
    }
    private let editorInteractionState = EditorInteractionState()
    private lazy var settingsWindowController = SettingsWindowController(settingsStore: settingsStore)
    private var hotPanels: [String: NotchPanel] = [:]
    private var hotHostingViews: [String: CompactFileDropHostingView<CompactNotchView>] = [:]
    private var fileDragTrackingState = FileDragTrackingState()
    /// One drawer panel per display, keyed by screen uniqueID. A window that
    /// has been key on one display gets asynchronously "returned" to it by
    /// the Window Server when later shown on another display — so a drawer
    /// panel never leaves its own display.
    private var drawerPanels: [String: NotchPanel] = [:]
    /// The drawer panel currently shown (on `drawerScreen`) while expanded.
    private var activeDrawerPanel: NotchPanel?
    /// Each drawer panel owns its content view permanently. Moving one
    /// shared view between windows makes the Window Server relocate the
    /// receiving window onto the screen where the view was last visible.
    private var drawerHostingViews: [String: FirstMouseHostingView<NotebookView>] = [:]
    private var activeHostingView: FirstMouseHostingView<NotebookView>?
    private var mousePollingTimer: Timer?
    private var globalMouseDownMonitor: Any?
    private var globalMouseDragMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var cachedLayout: NotchLayout?
    private var isExpanded = false
    private var currentScreen: NSScreen?
    private var drawerScreen: NSScreen?
    private var activeMenuTrackingCount = 0
    private var collapseTask: DispatchWorkItem?
    private var collapseDisplayLink: CVDisplayLink?
    private var isCollapsingAnimationRunning = false

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
            switch event.type {
            case .leftMouseDown:
                self.beginFileDragTracking(at: self.screenLocation(for: event))
            case .leftMouseDragged:
                self.noteFileDragMouseDragged(at: self.screenLocation(for: event))
            case .leftMouseUp:
                self.endFileDragTracking()
            default:
                break
            }
            if self.handleResizeMouseEvent(event) { return }
            self.editorInteractionState.handleMouseEvent(event, searchingIn: panel.contentView)
        }
        return panel
    }

    private func drawerPanel(for screen: NSScreen?) -> NotchPanel {
        let key = screen?.uniqueID ?? "unknown-screen"
        if let existing = drawerPanels[key] { return existing }
        let panel = makeDrawerPanel()
        drawerPanels[key] = panel
        return panel
    }

    func showDocked() {
        currentScreen = NotchGeometry.targetScreen()
        let layout = NotchGeometry.layout(for: currentScreen, customSize: settingsStore.customExpandedSize)
        rebuildContent(layout: layout)
        rebuildAllHotPanels()
        isExpanded = false
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
        if let panel = hotPanelForScreen(currentScreen) {
            panel.orderOut(nil)
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
        stopCollapseAnimation()
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
        let collapsingKey = drawerScreen?.uniqueID
        drawerScreen = nil

        stopCollapseAnimation()
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
        if let existing = drawerHostingViews[key] { return existing }
        let host = FirstMouseHostingView(rootView: makeNotebookView(layout: layout, drawerState: drawerState(for: key)))
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        drawerHostingViews[key] = host
        drawerPanels[key]?.contentView = host
        return host
    }

    private func rebuildContent(layout: NotchLayout? = nil) {
        let layout = layout ?? NotchGeometry.layout(for: currentScreen, customSize: settingsStore.customExpandedSize)
        cachedLayout = layout
        // Rebuild ONLY the active display's content. Another display's
        // panel may be mid-collapse with its own per-screen layout —
        // replacing its view would shift the collapse interpolation
        // endpoints (compact sizes differ between notched and fallback
        // displays) and glitch the running animation. Inactive displays
        // rebuild on their next expand.
        let key = (drawerScreen ?? currentScreen)?.uniqueID ?? "unknown-screen"
        if let host = drawerHostingViews[key] {
            host.rootView = makeNotebookView(layout: layout, drawerState: drawerState(for: key))
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
            if let existing = hotHostingViews[id], let panel = hotPanels[id] {
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
                hotPanels[id] = panel
                hotHostingViews[id] = host
            }
        }

        for (id, panel) in hotPanels where !activeScreenIDs.contains(id) {
            panel.orderOut(nil)
            hotPanels.removeValue(forKey: id)
            hotHostingViews.removeValue(forKey: id)
        }
    }

    private func hotPanelForScreen(_ screen: NSScreen?) -> NotchPanel? {
        guard let screen else { return nil }
        return hotPanels[screen.uniqueID]
    }

    private func configureCompactFileDrop(_ host: CompactFileDropHostingView<CompactNotchView>, screen: NSScreen) {
        host.onFileDragTargeted = { [weak self, weak screen] targeted in
            guard let self, let screen, targeted else { return }
            guard self.settingsStore.isFileShelfEnabled, !self.isExpanded else { return }
            self.currentScreen = screen
            self.expand(animated: true)
        }
        host.onFilesDropped = { [weak self] urls in
            self?.receiveDroppedFiles(urls) ?? false
        }
    }

    private func receiveDroppedFiles(_ urls: [URL]) -> Bool {
        guard settingsStore.isFileShelfEnabled, fileShelfStore.acceptDrop(urls) else { return false }
        // Reveal the shelf as drop feedback. Defer so AppKit can finish the
        // drop callback before the window order changes.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isExpanded else { return }
            self.expand(animated: true)
        }
        return true
    }

    private func showAllHotPanels() {
        for (_, panel) in hotPanels {
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



    private func observeGlobalSelectionMouseEvents() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let changeCount = NSPasteboard(name: .drag).changeCount
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.beginFileDragTracking(at: location, pasteboardChangeCount: changeCount)
            }
        }

        globalMouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.noteFileDragMouseDragged(at: location)
                self?.editorInteractionState.noteGlobalMouseDragged()
            }
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.endFileDragTracking()
                self.editorInteractionState.noteGlobalMouseUp()
                self.workspaceState.isDraggingShelfItem = false
            }
        }
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
        // Always refresh cachedLayout so the next expand uses current screen geometry
        let screen = drawerScreen ?? currentScreen ?? NotchGeometry.targetScreen()
        let layout = NotchGeometry.layout(for: screen, customSize: settingsStore.customExpandedSize)
        cachedLayout = layout
        // Drop drawer panels belonging to displays that are gone
        let connectedIDs = Set(NSScreen.screens.map(\.uniqueID))
        for (key, panel) in drawerPanels where !connectedIDs.contains(key) {
            if activeDrawerPanel === panel {
                activeDrawerPanel = nil
                activeHostingView = nil
            }
            panel.orderOut(nil)
            drawerPanels.removeValue(forKey: key)
            drawerHostingViews.removeValue(forKey: key)
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
        let mouseLocation = NSEvent.mouseLocation
        handleMouseLocation(mouseLocation)
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

            // Quick handoff: hovering another display's notch while this
            // drawer is open switches over immediately, without waiting for
            // the collapse to play out first.
            if settingsStore.triggerMode == .hover, NSEvent.pressedMouseButtons & 1 == 0 {
                for (screenID, panel) in hotPanels where screenID != drawerScreen?.uniqueID {
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

        // A file being dragged toward the notch reveals the drawer so it can
        // be dropped onto the shelf
        if settingsStore.isFileShelfEnabled, isFileDragInProgress() {
            for screenID in hotPanels.keys {
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
            for (screenID, panel) in hotPanels {
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
            guard !self.isPointInExpandedStayRegion(NSEvent.mouseLocation) else { return }
            self.collapse(animated: true)
        }

        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: task)
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        stopCollapseAnimation()
    }

    private func stopCollapseAnimation() {
        if let link = collapseDisplayLink {
            CVDisplayLinkStop(link)
            collapseDisplayLink = nil
        }
        isCollapsingAnimationRunning = false
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

    private func isFileDragInProgress() -> Bool {
        fileDragTrackingState.isFileDragInProgress(
            isLeftMouseButtonDown: NSEvent.pressedMouseButtons & 1 == 1,
            pasteboard: NSPasteboard(name: .drag)
        )
    }

    private func beginFileDragTracking(at location: NSPoint, pasteboardChangeCount: Int? = nil) {
        fileDragTrackingState.mouseDown(
            at: location,
            pasteboardChangeCount: pasteboardChangeCount ?? NSPasteboard(name: .drag).changeCount
        )
    }

    private func noteFileDragMouseDragged(at location: NSPoint) {
        fileDragTrackingState.mouseDragged(to: location)
    }

    private func endFileDragTracking() {
        fileDragTrackingState.mouseUp()
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
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

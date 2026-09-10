import AppKit
import SwiftUI

@MainActor
final class NotchPanel: NSPanel {
    var onMouseEvent: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
            onMouseEvent?(event)
        }

        super.sendEvent(event)
    }
}

@MainActor
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class NotchPanelController: NSObject {
    private let store = NoteStore()
    private let settingsStore = AppSettingsStore()
    private let imageStore = LocalImageStore()
    private let drawerState = DrawerState()
    private let editorInteractionState = EditorInteractionState()
    private lazy var settingsPopoverController = SettingsPopoverController(settingsStore: settingsStore)
    private var hotPanels: [String: NotchPanel] = [:]
    private var hotHostingViews: [String: NSHostingView<CompactNotchView>] = [:]
    private let drawerPanel: NotchPanel
    private var hostingView: NSHostingView<NotebookView>?
    private var mousePollingTimer: Timer?
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
        drawerPanel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()
        configurePanel(drawerPanel)
        drawerPanel.onMouseEvent = { [weak self] event in
            guard let self else { return }
            if self.handleResizeMouseEvent(event) { return }
            self.editorInteractionState.handleMouseEvent(event, searchingIn: self.hostingView)
        }
        startMousePolling()
        observeScreenChanges()
        observeGlobalSelectionMouseEvents()
        observeMenuTracking()
    }

    func showDocked() {
        currentScreen = NotchGeometry.targetScreen()
        let layout = NotchGeometry.layout(for: currentScreen, customSize: settingsStore.customExpandedSize)
        rebuildContent(layout: layout)
        rebuildAllHotPanels()
        isExpanded = false
        drawerState.isExpanded = false
        drawerState.revealProgress = 0
        drawerPanel.setFrame(drawerFrame(for: layout, screen: currentScreen), display: true)
        drawerPanel.orderOut(nil)
    }

    func expand(animated: Bool) {
        guard !isExpanded else { return }
        let layout = NotchGeometry.layout(for: currentScreen, customSize: settingsStore.customExpandedSize)
        cancelCollapse()
        isExpanded = true
        drawerScreen = currentScreen
        rebuildContent(layout: layout)
        // Rebuild hot panels with the same layout so compact widths match exactly
        rebuildAllHotPanels()
        drawerPanel.setFrame(drawerFrame(for: layout, screen: currentScreen), display: true)
        NSApp.activate(ignoringOtherApps: true)
        drawerPanel.makeKeyAndOrderFront(nil)
        if let panel = hotPanelForScreen(currentScreen) {
            panel.orderOut(nil)
        }
        setDrawerExpanded(true, animated: animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self else { return }
            guard self.isExpanded else { return }
            self.editorInteractionState.restoreSelection(
                self.store.selectionRange(for: self.store.activeTabID),
                searchingIn: self.hostingView
            )
            self.editorInteractionState.requestLayoutRefresh(searchingIn: self.hostingView)
            self.editorInteractionState.requestFocus(searchingIn: self.hostingView)
        }
    }

    func collapse(animated: Bool) {
        guard isExpanded else { return }
        if let range = editorInteractionState.currentSelectionRange() {
            store.updateSelection(for: store.activeTabID, range: range)
        }
        settingsPopoverController.close(animated: false)
        isExpanded = false

        stopCollapseAnimation()
        setDrawerExpanded(false, animated: animated)

        if animated {
            // SwiftUI animation: easeOut 0.16s
            // Order out drawer right as animation completes, then show hot panels
            // SwiftUI easeOut is 0.16s; use 0.20s to ensure animation is fully complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard let self, !self.isExpanded else { return }
                // Show hot panels before removing the drawer so the handoff
                // overlaps instead of leaving a one-frame gap
                self.showAllHotPanels()
                self.drawerPanel.orderOut(nil)
            }
        } else {
            drawerPanel.orderOut(nil)
            showAllHotPanels()
        }
    }

    private func configurePanel(_ panel: NotchPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
    }

    private func rebuildContent(layout: NotchLayout? = nil) {
        let layout = layout ?? NotchGeometry.layout(for: currentScreen, customSize: settingsStore.customExpandedSize)
        cachedLayout = layout
        let view = NotebookView(
            store: store,
            settingsStore: settingsStore,
            imageStore: imageStore,
            drawerState: drawerState,
            editorInteractionState: editorInteractionState,
            layout: layout,
            onOpenSettings: { [weak self] in self?.openSettingsPopover() }
        )

        if let hostingView {
            hostingView.rootView = view
            return
        }

        let host = FirstMouseHostingView(rootView: view)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        drawerPanel.contentView = host
        hostingView = host
    }

    private func rebuildAllHotPanels() {
        let layout = cachedLayout ?? NotchGeometry.layout(for: currentScreen)
        let screens = NSScreen.screens
        var activeScreenIDs = Set<String>()

        for screen in screens {
            let id = screen.uniqueID
            activeScreenIDs.insert(id)

            let hotView = CompactNotchView(layout: layout, onTap: { [weak self, weak screen] in
                guard let self, let screen else { return }
                self.currentScreen = screen
                self.expand(animated: true)
            })
            if let existing = hotHostingViews[id], let panel = hotPanels[id] {
                existing.rootView = hotView
                panel.setFrame(hotFrame(for: layout, screen: screen), display: true)
            } else {
                let panel = NotchPanel(
                    contentRect: .zero,
                    styleMask: [.borderless, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                configurePanel(panel)
                panel.onMouseEvent = { [weak self, weak screen] event in
                    guard let self, let screen else { return }
                    self.currentScreen = screen
                    guard event.type == .leftMouseDown else { return }
                    self.expand(animated: true)
                }
                let host = FirstMouseHostingView(rootView: hotView)
                host.translatesAutoresizingMaskIntoConstraints = false
                host.wantsLayer = true
                host.layer?.masksToBounds = true
                panel.contentView = host
                panel.setFrame(hotFrame(for: layout, screen: screen), display: true)
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

    private func showAllHotPanels() {
        for (_, panel) in hotPanels {
            panel.orderFrontRegardless()
        }
    }

    private func setDrawerExpanded(_ expanded: Bool, animated: Bool) {
        guard animated else {
            drawerState.isExpanded = expanded
            drawerState.revealProgress = expanded ? 1 : 0
            return
        }

        let animation: Animation = expanded
            ? .spring(response: 0.28, dampingFraction: 0.86)
            : .easeOut(duration: 0.16)

        withAnimation(animation) {
            drawerState.isExpanded = expanded
            drawerState.revealProgress = expanded ? 1 : 0
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
        globalMouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in
                self?.editorInteractionState.noteGlobalMouseDragged()
            }
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                self?.editorInteractionState.noteGlobalMouseUp()
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
        // Always refresh cachedLayout so the next expand uses current screen geometry
        let screen = drawerScreen ?? currentScreen ?? NotchGeometry.targetScreen()
        let layout = NotchGeometry.layout(for: screen, customSize: settingsStore.customExpandedSize)
        cachedLayout = layout
        rebuildAllHotPanels()
        if !isExpanded { return }
        rebuildContent(layout: layout)
        drawerPanel.setFrame(drawerFrame(for: layout, screen: screen), display: true)
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

            if isPointInExpandedStayRegion(point) {
                cancelCollapse()
            } else {
                scheduleCollapse()
            }
            return
        }

        if settingsStore.triggerMode == .hover {
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
        return drawerPanel.frame.insetBy(dx: -margin, dy: -margin).contains(point)
            || hotRect.contains(point)
            || settingsPopoverController.contains(point)
    }

    private var isResizingDrawer = false
    private var resizeGrabOffset: CGSize = .zero

    /// Bottom-right hot zone of the drawer panel, in screen coordinates.
    /// Aligned to the visible corner: the NotchShape insets the right edge
    /// by the expanded top corner radius (10).
    private var drawerGripRect: NSRect {
        let frame = drawerPanel.frame
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
            guard drawerGripRect.contains(mouse) else { return false }
            isResizingDrawer = true
            let frame = drawerPanel.frame
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
        guard let screen = drawerPanel.screen else { return }
        let frame = drawerPanel.frame
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
        drawerPanel.setFrame(NSRect(x: newX, y: newY, width: size.width, height: size.height), display: true)
        settingsStore.customExpandedSize = size
        rebuildContent(layout: layout)
    }

    private func openSettingsPopover() {
        cancelCollapse()
        settingsPopoverController.show(relativeTo: drawerPanel)
    }


    private func hotFrame(for layout: NotchLayout, screen: NSScreen?) -> NSRect {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return frame(for: layout.compactSize, topY: screenFrame.maxY + layout.compactTopOffset, in: screenFrame)
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

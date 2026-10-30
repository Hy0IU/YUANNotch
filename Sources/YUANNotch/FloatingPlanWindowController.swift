import AppKit
import SwiftUI

@MainActor
final class FloatingPlanWindowController: NSObject {
    let panel: NotchPanel

    var isExpanded: Bool { presentation.isExpanded }

    private let store: DailyPlanStore
    private var presentation: FloatingPlanPresentation { store.floatingPresentation }
    private var lastCompactFrame: NSRect?
    private var anchorsRight = true
    private var menuTrackingCount = 0
    private var compactMouseDown: NSEvent?
    private var collapseTask: DispatchWorkItem?
    private var collapseTimer: Timer?
    private var collapseStartedAt: TimeInterval = 0
    private var collapseStartFrame: NSRect = .zero
    private var collapseEndFrame: NSRect = .zero

    init(store: DailyPlanStore, settingsStore: AppSettingsStore) {
        self.store = store
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.allowsKeyboardFocus = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // A changing timer must not become part of AppKit's cached shadow mask.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.onMouseEvent = { [weak self] event in
            self?.handleMouseEvent(event) ?? false
        }

        let host = FloatingPlanHostingView(rootView: FloatingPlanWindowContent(
            store: store,
            settingsStore: settingsStore,
            presentation: presentation,
            onExpand: { [weak self] in self?.expand() }
        ))
        host.onMouseExit = { [weak self] in self?.collapseIfOutside() }
        host.onMouseEnter = { [weak self] in
            guard let self, self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.cancelCollapse()
        }
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        panel.contentView = host

        NotificationCenter.default.addObserver(
            self, selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func toggle(on screen: NSScreen? = nil) {
        if panel.isVisible {
            hide()
        } else {
            show(on: screen)
        }
    }

    func show(on screen: NSScreen? = nil) {
        guard store.activeSession != nil, store.activePlan != nil else { return }
        if panel.isVisible { hide() }
        presentation.isExpanded = false
        let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = FloatingPlanMetrics.compactSize
        let frame: NSRect
        if let saved = lastCompactFrame,
           let savedScreen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(saved) }) {
            frame = clamped(saved, to: savedScreen.visibleFrame)
        } else {
            frame = NSRect(
                x: visibleFrame.maxX - size.width - 24,
                y: visibleFrame.maxY - size.height - 24,
                width: size.width, height: size.height
            )
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        presentation.isVisible = true
    }

    func hide() {
        cancelCollapse()
        presentation.isVisible = false
        guard panel.isVisible else { return }
        lastCompactFrame = resizedFrame(to: FloatingPlanMetrics.compactSize)
        panel.orderOut(nil)
        presentation.isExpanded = false
        compactMouseDown = nil
    }

    func expand() {
        cancelCollapse()
        guard panel.isVisible, !isExpanded else { return }
        let screen = panel.screen ?? NSScreen.main
        anchorsRight = panel.frame.midX >= (screen?.visibleFrame.midX ?? panel.frame.midX)
        let frame = resizedFrame(to: FloatingPlanMetrics.expandedSize)
        presentation.isExpanded = true
        panel.setFrame(frame, display: true)
    }

    private func collapseIfOutside() {
        guard canCollapse else { return }
        guard collapseTask == nil, collapseTimer == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseTask = nil
            guard self.canCollapse else { return }
            self.collapseStartedAt = ProcessInfo.processInfo.systemUptime
            self.collapseStartFrame = self.panel.frame
            self.collapseEndFrame = self.resizedFrame(to: FloatingPlanMetrics.compactSize)
            let timer = Timer(
                timeInterval: 1.0 / 60,
                target: self, selector: #selector(self.collapseTimerFired),
                userInfo: nil, repeats: true
            )
            self.collapseTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + FloatingPlanMetrics.collapseDelay, execute: task)
    }

    private var canCollapse: Bool {
        panel.isVisible && isExpanded && menuTrackingCount == 0
            && NSEvent.pressedMouseButtons & 1 == 0
            && !panel.frame.contains(NSEvent.mouseLocation)
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        let wasCollapsing = collapseTimer != nil
        collapseTimer?.invalidate()
        collapseTimer = nil
        if wasCollapsing, panel.isVisible, isExpanded {
            panel.setFrame(collapseStartFrame, display: true)
        }
    }

    @objc private func collapseTimerFired() {
        guard canCollapse else {
            cancelCollapse()
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - collapseStartedAt
        let progress = min(elapsed / FloatingPlanMetrics.collapseDuration, 1)
        let frame = FloatingPlanMetrics.collapseFrame(
            from: collapseStartFrame, to: collapseEndFrame, progress: progress
        )
        panel.setFrame(frame, display: true)
        if progress >= 1 {
            collapseTimer?.invalidate()
            collapseTimer = nil
            presentation.isExpanded = false
            lastCompactFrame = frame
        }
    }

    private func handleMouseEvent(_ event: NSEvent) -> Bool {
        if isExpanded {
            if event.type == .leftMouseUp {
                // Controls and the explicit drag surface finish before collapsing.
                DispatchQueue.main.async { [weak self] in self?.collapseIfOutside() }
            }
            return false
        }

        switch event.type {
        case .leftMouseDown:
            compactMouseDown = event
        case .leftMouseDragged:
            guard let down = compactMouseDown else { return true }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            if hypot(dx, dy) >= 3 {
                panel.performDrag(with: down)
                compactMouseDown = nil
            }
        case .leftMouseUp:
            let wasClick = compactMouseDown != nil
            compactMouseDown = nil
            if wasClick { expand() }
        default:
            return false
        }
        return true
    }

    private func resizedFrame(to size: CGSize) -> NSRect {
        let current = panel.frame
        let frame = NSRect(
            x: anchorsRight ? current.maxX - size.width : current.minX,
            y: current.maxY - size.height,
            width: size.width, height: size.height
        )
        guard let screen = panel.screen ?? NSScreen.main else { return frame }
        return clamped(frame, to: screen.visibleFrame)
    }

    private func clamped(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: min(max(frame.minX, visibleFrame.minX), max(visibleFrame.maxX - frame.width, visibleFrame.minX)),
            y: min(max(frame.minY, visibleFrame.minY), max(visibleFrame.maxY - frame.height, visibleFrame.minY)),
            width: frame.width, height: frame.height
        )
    }

    @objc private func menuTrackingDidBegin(_ notification: Notification) {
        menuTrackingCount += 1
        cancelCollapse()
    }

    @objc private func menuTrackingDidEnd(_ notification: Notification) {
        menuTrackingCount = max(menuTrackingCount - 1, 0)
        if menuTrackingCount == 0 {
            DispatchQueue.main.async { [weak self] in self?.collapseIfOutside() }
        }
    }
}


private struct FloatingPlanWindowContent: View {
    let store: DailyPlanStore
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var presentation: FloatingPlanPresentation
    let onExpand: () -> Void

    var body: some View {
        FloatingPlanPanelView(
            store: store,
            isExpanded: presentation.isExpanded,
            onExpand: onExpand
        )
        .environment(\.appTypography, settingsStore.typography)
        .font(settingsStore.typography.font(.body))
    }
}

@MainActor
private final class FloatingPlanHostingView<Content: View>: FirstMouseHostingView<Content> {
    var onMouseExit: (() -> Void)?
    var onMouseEnter: (() -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }
}

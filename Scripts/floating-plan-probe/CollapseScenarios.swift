import AppKit
import SwiftUI

@MainActor
enum FloatingPlanCollapseScenarios {
    static func run(store: DailyPlanStore, settings: AppSettingsStore, output: URL) throws {
        var animationTime: TimeInterval = 100
        let controller = FloatingPlanWindowController(
            store: store, settingsStore: settings, nowProvider: { animationTime }
        )
        let session = store.activeSession
        let presentation = store.floatingPresentation
        // Logical presentation is exercised on a real, never-ordered-front panel.
        // No desktop mouse events or pointer movement are generated.
        presentation.isVisible = true
        controller.panel.setFrame(CGRect(x: 100, y: 100, width: 64, height: 64), display: false)
        let compactMask = cardAlphaMask(in: controller.panel.contentView!)
        precondition(controller.panel.hasShadow, "Floating panels must use the system window shadow")
        precondition(!controller.panel.isOpaque && controller.panel.backgroundColor.alphaComponent == 0,
                     "Only the rounded card, not the rectangular window, may supply shadow alpha")
        precondition(controller.panel.styleMask.contains([.borderless, .nonactivatingPanel]))
        precondition(!controller.panel.allowsKeyboardFocus && controller.panel.level == .floating)
        precondition(controller.panel.isMovable && !controller.panel.isMovableByWindowBackground)
        controller.expand()
        let expandedFrame = controller.panel.frame
        precondition(!controller.panel.isVisible && controller.isExpanded)
        let expandedMask = cardAlphaMask(in: controller.panel.contentView!)
        controller.panel.setFrameOrigin(NSPoint(x: expandedFrame.minX + 20, y: expandedFrame.minY + 30))
        precondition(cardAlphaMask(in: controller.panel.contentView!) == expandedMask,
                     "Moving a native-shadow panel must not change its card mask")
        controller.panel.setFrameOrigin(expandedFrame.origin)
        print("PASS native shadow configuration and opaque rounded silhouettes at 64×64 / 350×125; moving preserves the mask")

        let otherMenu = NSMenu(title: "Unrelated menu")
        controller.pointerDidExit()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: otherMenu)
        spinUntil { controller.isCollapsing }
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: otherMenu)
        var previousWidth = expandedFrame.width
        for step in 1...4 {
            animationTime = 100 + FloatingPlanMetrics.collapseDuration * Double(step) / 5
            spinUntil { controller.panel.frame.width < previousWidth - 0.1 }
            let frame = controller.panel.frame
            precondition(expandedFrame.contains(frame), "Contraction must stay within its original frame")
            precondition(frame.width < previousWidth)
            previousWidth = frame.width
            _ = cardAlphaMask(in: controller.panel.contentView!)
            if step == 2 {
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: otherMenu)
                precondition(controller.panel.frame == frame,
                             "An unrelated menu must not restore the expanded frame or cancel the contraction")
                try render(controller, to: output.appendingPathComponent("controller-collapse-mid.png"))
            }
            // Repeated exit reports from a changing tracking area cannot restart it.
            controller.pointerDidExit()
        }
        animationTime = 100 + FloatingPlanMetrics.collapseDuration + 0.001
        spinUntil { !controller.isExpanded }
        precondition(controller.panel.frame.size == FloatingPlanMetrics.compactSize && !controller.isCollapsing)
        precondition(cardAlphaMask(in: controller.panel.contentView!) == compactMask,
                     "Continuous contraction must restore the compact shadow silhouette")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: otherMenu)
        try render(controller, to: output.appendingPathComponent("controller-collapse-complete.png"))
        print("PASS real controller finishes a monotonic collapse without further pointer events, despite unrelated menu tracking")

        precondition(deliver(.leftMouseDown, to: controller))
        precondition(deliver(.leftMouseUp, to: controller))
        precondition(controller.isExpanded && store.activeSession == session,
                     "The compact expansion click must be consumed without activating timer controls")
        let reopenedFrame = controller.panel.frame
        animationTime = 200
        controller.pointerDidExit()
        spinUntil { controller.isCollapsing }
        animationTime = 200 + FloatingPlanMetrics.collapseDuration / 2
        spinUntil { controller.panel.frame.width < reopenedFrame.width - 1 }
        precondition(deliver(.leftMouseDown, to: controller), "A press on the contracting window must reopen it")
        precondition(controller.panel.frame == reopenedFrame && controller.isExpanded && !controller.isCollapsing,
                     "Reopening must restore full size synchronously, not on mouse-up or the next timer tick")
        precondition(cardAlphaMask(in: controller.panel.contentView!) == expandedMask)
        precondition(deliver(.leftMouseDragged, to: controller) && deliver(.leftMouseUp, to: controller),
                     "The entire reopening click must be consumed before reaching timer controls or dragging")
        precondition(store.activeSession == session)
        precondition(!deliver(.leftMouseDragged, to: controller),
                     "An ordinary expanded drag must remain available to the native drag surface")
        animationTime += 10
        pump(for: 0.06)
        precondition(controller.panel.frame == reopenedFrame && controller.isExpanded)
        try render(controller, to: output.appendingPathComponent("controller-click-reopened.png"))
        print("PASS a press during contraction immediately restores the full card; canceled timer callbacks cannot shrink it again")

        controller.pointerDidExit()
        precondition(controller.pointerDidPress(), "A press must also cancel the leave delay")
        pump(for: FloatingPlanMetrics.collapseDelay + 0.04)
        precondition(controller.panel.frame == reopenedFrame && controller.isExpanded && !controller.isCollapsing)
        print("PASS pressing during the leave delay cancels its pending task without a late collapse")

        animationTime = 300
        controller.pointerDidExit()
        spinUntil { controller.isCollapsing }
        animationTime += FloatingPlanMetrics.collapseDuration + 0.001
        spinUntil { !controller.isExpanded }
        precondition(controller.panel.frame.size == FloatingPlanMetrics.compactSize)
        precondition(store.activeSession == session, "Window interactions must not alter the focus session")
        controller.hide()
        pump(for: 0.04)
        precondition(!presentation.isVisible && !controller.isExpanded && !controller.panel.isVisible)
        print("PASS a later exit can collapse again; hiding clears presentation without ever showing a test window")
    }

    // Invoke only the controller's local event handler, never desktop dispatch or
    // AppKit's blocking native drag loop.
    private static func deliver(_ type: NSEvent.EventType, to controller: FloatingPlanWindowController) -> Bool {
        let event = NSEvent.mouseEvent(
            with: type, location: CGPoint(x: 32, y: 32), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
        return controller.panel.onMouseEvent?(event) ?? false
    }

    static func cardAlphaMask(in view: NSView) -> [UInt8] {
        view.layoutSubtreeIfNeeded()
        pump(for: 0.02)
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let card = view.bounds.insetBy(dx: FloatingPlanMetrics.edgeInset, dy: FloatingPlanMetrics.edgeInset)
        var mask: [UInt8] = []
        mask.reserveCapacity(bitmap.pixelsWide * bitmap.pixelsHigh)
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                let point = CGPoint(x: (CGFloat(x) + 0.5) / scaleX, y: (CGFloat(y) + 0.5) / scaleY)
                let alpha = bitmap.colorAt(x: x, y: y)!.alphaComponent
                mask.append(UInt8((alpha * 255).rounded()))
                if !card.contains(point) {
                    precondition(alpha < 0.02, "No self-painted shadow or rectangular backing may surround the card")
                } else if card.insetBy(dx: 15, dy: 15).contains(point) {
                    precondition(alpha > 0.99, "The entire card interior, not its glyphs or ring, must supply shadow alpha")
                }
            }
        }
        let cornerX = Int((card.minX + 1) * scaleX)
        let cornerY = Int((card.minY + 1) * scaleY)
        precondition(bitmap.colorAt(x: cornerX, y: cornerY)!.alphaComponent < 0.02,
                     "The native shadow silhouette must follow rounded corners")
        return mask
    }

    private static func spinUntil(_ predicate: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(predicate(), "Offscreen controller did not reach the expected animation state")
    }

    private static func pump(for duration: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private static func render(_ controller: FloatingPlanWindowController, to url: URL) throws {
        let view = controller.panel.contentView!
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

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
        controller.expand()
        let expandedFrame = controller.panel.frame
        precondition(!controller.panel.isVisible && controller.isExpanded)

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
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: otherMenu)
        try render(controller, to: output.appendingPathComponent("controller-collapse-complete.png"))
        print("PASS real controller finishes a monotonic collapse without further pointer events, despite unrelated menu tracking")

        controller.expand()
        let reopenedFrame = controller.panel.frame
        animationTime = 200
        controller.pointerDidExit()
        spinUntil { controller.isCollapsing }
        animationTime = 200 + FloatingPlanMetrics.collapseDuration / 2
        spinUntil { controller.panel.frame.width < reopenedFrame.width - 1 }
        precondition(controller.pointerDidPress(), "A press on the contracting window must reopen it")
        precondition(controller.panel.frame == reopenedFrame && controller.isExpanded && !controller.isCollapsing,
                     "Reopening must restore full size synchronously, not on mouse-up or the next timer tick")
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

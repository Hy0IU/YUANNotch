import AppKit
import SwiftUI

// Only the persisted raw value is needed; reminder ordering is outside this probe.
enum ReminderSortOrder: String {
    case added
}

@main
struct FloatingPlanProbe {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("floating-plan-\(UUID().uuidString)", isDirectory: true)
        let suite = "floating-plan-probe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: scratch)
        }
        let settings = AppSettingsStore(defaults: defaults)
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let day = PlanDayKey(date: DailyPlanEngine.dayStart(containing: now, calendar: calendar), calendar: calendar)
        let plan = DailyPlan(
            title: "Work", targetMinutes: 330,
            pomodoro: PomodoroConfiguration(
                isEnabled: true, focusMinutes: 50, shortBreakMinutes: 10,
                longBreakMinutes: 20, roundsBeforeLongBreak: 2
            )
        )
        let persistence = DailyPlanPersistence(fileURL: scratch.appendingPathComponent("plans.json"))
        try persistence.save(DailyPlanArchive(
            plans: [plan],
            dayRecords: [DailyPlanDayRecord(planID: plan.id, day: day, focusedSeconds: 17 * 60)],
            activeSession: FocusSession(
                planID: plan.id, phase: .focus, phaseDuration: 50 * 60,
                phaseElapsed: 17 * 60, runningSince: nil, completedFocusRounds: 0, sessionDay: day
            )
        ))
        let store = DailyPlanStore(persistence: persistence, nowProvider: { now }, startsTimer: false)
        let selectedSession = store.activeSession

        for size in InterfaceTextSize.allCases {
            settings.interfaceTextSize = size
            let drawer = makeHost(
                DailyPlansPanelView(
                    store: store, size: CGSize(width: 520, height: 420),
                    isDrawerExpanded: true, onToggleFloatingPlan: {}
                ).environment(\.appTypography, settings.typography),
                size: CGSize(width: 520, height: 420)
            )
            store.floatingPresentation.isVisible = false
            settleLayout(drawer)
            try render(drawer, to: output.appendingPathComponent("drawer-pin-hidden-\(size.rawValue).png"))
            store.floatingPresentation.isVisible = true
            settleLayout(drawer)
            try render(drawer, to: output.appendingPathComponent("drawer-pin-visible-\(size.rawValue).png"))
            store.floatingPresentation.isVisible = false
            settleLayout(drawer)
            try render(drawer, to: output.appendingPathComponent("drawer-pin-closed-\(size.rawValue).png"))
            print("Rendered \(size.rawValue) pin states on the same offscreen drawer")
        }

        let compact = makeHost(
            FloatingPlanPanelView(store: store, isExpanded: false, onExpand: {}),
            size: FloatingPlanMetrics.compactSize
        )
        try render(compact, to: output.appendingPathComponent("compact-progress.png"))
        let expanded = makeHost(
            FloatingPlanPanelView(store: store, isExpanded: true, onExpand: {}),
            size: FloatingPlanMetrics.expandedSize
        )
        try render(expanded, to: output.appendingPathComponent("expanded.png"))
        let startFrame = CGRect(origin: CGPoint(x: 40, y: 80), size: FloatingPlanMetrics.expandedSize)
        for anchorsRight in [false, true] {
            let endFrame = CGRect(
                x: anchorsRight ? startFrame.maxX - FloatingPlanMetrics.compactSize.width : startFrame.minX,
                y: startFrame.maxY - FloatingPlanMetrics.compactSize.height,
                width: FloatingPlanMetrics.compactSize.width,
                height: FloatingPlanMetrics.compactSize.height
            )
            var previousWidth = startFrame.width
            for step in 0 ... 100 {
                let frame = FloatingPlanMetrics.collapseFrame(
                    from: startFrame, to: endFrame, progress: Double(step) / 100
                )
                let anchor = anchorsRight ? frame.maxX : frame.minX
                let expectedAnchor = anchorsRight ? startFrame.maxX : startFrame.minX
                precondition(abs(anchor - expectedAnchor) < 0.001 && abs(frame.maxY - startFrame.maxY) < 0.001)
                precondition(frame.width <= previousWidth && frame.width >= endFrame.width)
                precondition(startFrame.contains(frame), "Retraction must remain inside the expanded window")
                previousWidth = frame.width
            }
            precondition(FloatingPlanMetrics.collapseFrame(from: startFrame, to: endFrame, progress: 1) == endFrame)
        }
        print("PASS continuous retraction preserves either top corner and stays inside the original window")
        let endFrame = CGRect(
            x: startFrame.maxX - FloatingPlanMetrics.compactSize.width,
            y: startFrame.maxY - FloatingPlanMetrics.compactSize.height,
            width: FloatingPlanMetrics.compactSize.width,
            height: FloatingPlanMetrics.compactSize.height
        )
        for step in 0 ... 4 {
            let frame = FloatingPlanMetrics.collapseFrame(
                from: startFrame, to: endFrame, progress: Double(step) / 4
            )
            expanded.window!.setContentSize(frame.size)
            settleLayout(expanded)
            try render(expanded, to: output.appendingPathComponent("retract-\(step * 25).png"))
        }
        print("Rendered five retraction frames on one offscreen host; the ring is not replaced at the endpoint")
        precondition(store.activeSession == selectedSession, "Changing presentation must not reset or resume focus")
        store.togglePause(at: now)
        _ = store.refresh(at: now.addingTimeInterval(60))
        precondition(store.phaseRemaining() == 32 * 60 && store.activeSession?.isRunning == true)
        store.togglePause(at: now.addingTimeInterval(3 * 60))
        settleLayout(compact)
        try render(compact, to: output.appendingPathComponent("compact-progress-later.png"))
        precondition(store.phaseElapsed() == 20 * 60)
        print("PASS presentation changes preserve the selected timer; focus continues and pauses at 20m")
        for phase in [FocusPhase.shortBreak, .longBreak] {
            let duration = DailyPlanEngine.phaseDuration(for: plan, phase: phase)
            let breakPersistence = DailyPlanPersistence(fileURL: scratch.appendingPathComponent("\(phase.rawValue).json"))
            try breakPersistence.save(DailyPlanArchive(
                plans: [plan],
                activeSession: FocusSession(
                    planID: plan.id, phase: phase, phaseDuration: duration,
                    phaseElapsed: duration / 3, runningSince: nil,
                    completedFocusRounds: phase == .shortBreak ? 1 : 2, sessionDay: day
                )
            ))
            let breakStore = DailyPlanStore(
                persistence: breakPersistence, nowProvider: { now }, startsTimer: false
            )
            for step in 0 ... 2 {
                let frame = FloatingPlanMetrics.collapseFrame(
                    from: startFrame, to: endFrame, progress: Double(step) / 2
                )
                let host = makeHost(
                    FloatingPlanPanelView(
                        store: breakStore, isExpanded: step != 2, onExpand: {}
                    ),
                    size: frame.size
                )
                try render(host, to: output.appendingPathComponent("\(phase.rawValue)-retract-\(step * 50).png"))
            }
            print("Rendered \(phase.rawValue) in expanded, retracting and compact states")
        }
        for size in InterfaceTextSize.allCases {
            let host = makeHost(
                FloatingPlanPanelView(store: store, isExpanded: true, onExpand: {})
                    .environment(\.appTypography, AppTypography(interfaceSize: size)),
                size: FloatingPlanMetrics.expandedSize
            )
            checkExpandedHitRegions(host)
            print("PASS expanded \(size.rawValue): ring, countdown, and progress share a drag surface; all three controls remain outside it")
        }
        print("Offscreen previews: \(output.path)")
        print("No windows ordered front, pointer movement, clicks, keyboard input, or desktop event dispatch")
    }

    @MainActor
    private static func checkExpandedHitRegions(_ host: NSView) {
        func hit(_ point: CGPoint) -> NSView? {
            let local = CGPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
            return host.hitTest(host.convert(local, to: host.superview))
        }
        guard let dragSurface = hit(CGPoint(x: 38, y: 38)) else {
            preconditionFailure("The expanded ring must accept dragging")
        }
        precondition(dragSurface !== host, "The hosting view must not swallow the drag surface")
        precondition(hit(CGPoint(x: 130, y: 48)) === dragSurface,
                     "The countdown must belong to the drag surface")
        precondition(hit(CGPoint(x: 120, y: 96)) === dragSurface,
                     "The progress row must belong to the drag surface")
        // Fixed-size controls are right-aligned; probe inside each visible circle.
        for (label, inset) in [("Play/Pause", 98.0), ("Finish Round", 62.0), ("Reset", 29.0)] {
            let buttonHit = hit(CGPoint(x: host.bounds.width - inset, y: 45))
            precondition(buttonHit != nil && buttonHit !== dragSurface,
                         "The drag surface must not intercept \(label)")
        }
    }

    @MainActor
    private static func makeHost<V: View>(_ view: V, size: CGSize) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.preferredColorScheme(.dark)))
        host.frame = NSRect(origin: .zero, size: size)
        host.sizingOptions = []
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        settleLayout(host)
        return host
    }

    @MainActor
    private static func settleLayout(_ view: NSView) {
        for _ in 0 ..< 6 {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    @MainActor
    private static func render(_ view: NSView, to url: URL) throws {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

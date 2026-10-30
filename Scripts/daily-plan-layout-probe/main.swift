import AppKit
import SwiftUI

@main
struct DailyPlanLayoutProbe {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-plan-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let calendar = Calendar.autoupdatingCurrent
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        let reading = DailyPlan(
            title: "Reading · 论文精读",
            targetMinutes: 120,
            pomodoro: .continuous
        )
        let longPlan = DailyPlan(
            title: "Long mixed-language plan title · 深度研究论文精读与写作",
            targetMinutes: 12 * 60,
            pomodoro: .continuous
        )
        let persistence = DailyPlanPersistence(fileURL: scratch.appendingPathComponent("plans.json"))
        let todayKey = PlanDayKey(date: now, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        try persistence.save(DailyPlanArchive(
            plans: [reading, longPlan],
            dayRecords: [
                DailyPlanDayRecord(planID: reading.id, day: todayKey, focusedSeconds: 5_400),
                DailyPlanDayRecord(planID: longPlan.id, day: todayKey, focusedSeconds: 3_900),
                DailyPlanDayRecord(
                    planID: reading.id,
                    day: PlanDayKey(date: yesterday, calendar: calendar),
                    focusedSeconds: TimeInterval((23 * 60 + 59) * 60)
                )
            ]
        ))
        let store = DailyPlanStore(persistence: persistence, nowProvider: { now }, startsTimer: false)

        for interfaceSize in InterfaceTextSize.allCases {
            let typography = AppTypography(interfaceSize: interfaceSize)
            let sizeName = interfaceSize.rawValue
            store.beginEditingTime(on: now)
            store.timeDraft!.entries[0].minutes = 105

            for width: CGFloat in [300, 360, 520] {
                let size = CGSize(width: width, height: 420)
                let host = makeHost(
                    DailyPlanTimeEditor(store: store)
                        .environment(\.appTypography, typography),
                    size: size
                )
                let fields = editableFields(in: host)
                precondition(fields.count == 6, "Every entry must expose hours and minutes")
                let frames = fields.map { $0.convert($0.bounds, to: host) }
                for (field, frame) in zip(fields, frames) {
                    let font = field.font ?? typography.nsFont(.timeInput)
                    let widestValue = ("24" as NSString).size(withAttributes: [.font: font]).width
                    precondition(frame.width + 0.5 >= widestValue, "Time input value does not fit its field")
                    precondition(
                        frame.height + 1 >= font.ascender - font.descender,
                        "Time input text was vertically squeezed (field \(frame.height), font \(font.ascender - font.descender), point size \(font.pointSize))"
                    )
                    precondition(frame.minX >= 0 && frame.maxX <= width, "Input field escaped the panel")
                }
                for index in frames.indices {
                    for other in frames.indices where other > index {
                        precondition(!frames[index].intersects(frames[other]), "Duration fields overlap")
                    }
                }
                try render(host, to: output.appendingPathComponent("editor-\(sizeName)-\(Int(width)).png"))
                print("PASS editor \(sizeName) at \(Int(width))pt: six readable, non-overlapping fields")
            }

            store.cancelEditingTime()
            store.start(longPlan, at: now)
            let planPanel = makeHost(
                DailyPlansPanelView(
                    store: store,
                    size: CGSize(width: 360, height: 420),
                    isDrawerExpanded: true,
                    onToggleFloatingPlan: {}
                )
                .environment(\.appTypography, typography),
                size: CGSize(width: 360, height: 420)
            )
            try render(planPanel, to: output.appendingPathComponent("plans-\(sizeName).png"))

            let history = makeHost(
                DailyPlanHistoryView(store: store)
                    .environment(\.appTypography, typography),
                size: CGSize(width: 300, height: 420)
            )
            try render(history, to: output.appendingPathComponent("history-\(sizeName).png"))

            if interfaceSize == .large {
                for width: CGFloat in [300, 308] {
                    let card = makeHost(
                        DailyPlanActiveCardView(
                            store: store,
                            availableWidth: width - 20,
                            isDrawerExpanded: true,
                            isFloating: false,
                            onFloatingAction: {},
                            displayDate: now
                        )
                        .environment(\.appTypography, typography),
                        size: CGSize(width: width, height: 180)
                    )
                    let timerFont = NSFont.monospacedDigitSystemFont(
                        ofSize: typography.size(.timer),
                        weight: .medium
                    )
                    let timerWidth = ("12:00:00" as NSString)
                        .size(withAttributes: [.font: timerFont]).width
                    let availableTimerWidth = width - 20 - 22 - 58 - 12
                    precondition(timerWidth <= availableTimerWidth, "Hour countdown cannot fit beside the progress ring")
                    try render(card, to: output.appendingPathComponent("drawer-card-large-\(Int(width)).png"))
                    print("PASS drawer card at \(Int(width))pt, large: hour countdown remains readable with compact actions")
                }
            }

            let floatingNow = Date()
            let floatingPersistence = DailyPlanPersistence(
                fileURL: scratch.appendingPathComponent("floating-\(sizeName).json")
            )
            try floatingPersistence.save(DailyPlanArchive(plans: [longPlan]))
            let floatingStore = DailyPlanStore(
                persistence: floatingPersistence,
                nowProvider: { floatingNow },
                startsTimer: false
            )
            floatingStore.start(longPlan, at: floatingNow)
            let floatingSize = FloatingPlanMetrics.expandedSize
            let floating = makeHost(
                FloatingPlanPanelView(store: floatingStore, isExpanded: true, onExpand: {})
                    .environment(\.appTypography, typography),
                size: floatingSize
            )
            precondition(floating.frame.size == floatingSize, "Floating timer changed its fixed panel size")
            let timerFields = staticLabels(in: floating).filter { $0.stringValue.filter(\.isNumber).count >= 6 }
            guard let timer = timerFields.first else {
                preconditionFailure("Floating card did not expose its full hour countdown")
            }
            precondition(timer.stringValue.contains(":"), "Floating countdown should include hours and minutes")
            precondition(abs(timer.font!.pointSize - typography.size(.timer)) < 0.1, "Floating countdown font did not follow the interface size")
            let timerWidth = (timer.stringValue as NSString).size(withAttributes: [.font: timer.font!]).width
            precondition(timer.bounds.width + 0.5 >= timerWidth, "Floating countdown is clipped")
            try render(floating, to: output.appendingPathComponent("floating-\(sizeName).png"))
            print("PASS floating timer \(sizeName): full hour countdown fits the 360 × 125 card")
            let compact = makeHost(
                FloatingPlanPanelView(store: floatingStore, isExpanded: false, onExpand: {})
                    .environment(\.appTypography, typography),
                size: FloatingPlanMetrics.compactSize
            )
            try render(compact, to: output.appendingPathComponent("floating-compact-\(sizeName).png"))
        }

        var rolloverNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 3, minute: 50))!
        let rolloverPersistence = DailyPlanPersistence(fileURL: scratch.appendingPathComponent("rollover.json"))
        let job = DailyPlan(title: "Job", targetMinutes: 90, pomodoro: .continuous)
        try rolloverPersistence.save(DailyPlanArchive(plans: [reading, job, longPlan]))
        let rolloverStore = DailyPlanStore(
            persistence: rolloverPersistence, nowProvider: { rolloverNow }, startsTimer: false
        )
        rolloverStore.start(reading)
        rolloverNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 3, minute: 59, second: 59))!
        _ = rolloverStore.refresh(at: rolloverNow)
        let rolloverHost = makeHost(
            DailyPlansPanelView(
                store: rolloverStore, size: CGSize(width: 520, height: 420),
                isDrawerExpanded: true, onToggleFloatingPlan: {}
            ),
            size: CGSize(width: 520, height: 420)
        )
        try render(rolloverHost, to: output.appendingPathComponent("rollover-before-0400.png"))
        rolloverNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 4))!
        _ = rolloverStore.refresh(at: rolloverNow)
        for _ in 0 ..< 6 {
            rolloverHost.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        try render(rolloverHost, to: output.appendingPathComponent("rollover-after-0400.png"))
        print("Rendered the same Plans surface before and after the 04:00 refresh")

        print("Offscreen previews: \(output.path)")
    }

    @MainActor
    private static func makeHost<V: View>(_ view: V, size: CGSize) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: size.width, height: size.height)
                .background(Color(red: 0.06, green: 0.06, blue: 0.07))
                .preferredColorScheme(.dark)
        ))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0 ..< 6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return host
    }

    @MainActor
    private static func editableFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, field.isEditable { return [field] }
        return view.subviews.flatMap { editableFields(in: $0) }
    }

    @MainActor
    private static func staticLabels(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, !field.isEditable { return [field] }
        return view.subviews.flatMap { staticLabels(in: $0) }
    }

    @MainActor
    private static func render(_ view: NSView, to url: URL) throws {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

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
        let reading = DailyPlan(title: "Reading · 论文精读", targetMinutes: 120)
        let writing = DailyPlan(title: "Writing · A long plan title that should truncate gracefully", targetMinutes: 60)
        let persistence = DailyPlanPersistence(fileURL: scratch.appendingPathComponent("plans.json"))
        try persistence.save(DailyPlanArchive(
            plans: [reading, writing],
            dayRecords: [DailyPlanDayRecord(
                planID: reading.id, day: PlanDayKey(date: now, calendar: calendar), focusedSeconds: 5_400
            )]
        ))
        let store = DailyPlanStore(persistence: persistence, nowProvider: { now }, startsTimer: false)
        store.beginEditingTime(on: now)
        store.timeDraft!.entries[0].minutes = 105

        for width: CGFloat in [300, 360, 520] {
            let size = CGSize(width: width, height: 420)
            let host = makeHost(DailyPlanTimeEditor(store: store), size: size)
            let fields = editableFields(in: host)
            precondition(fields.count == 6, "Every entry must expose hours and minutes")
            let frames = fields.map { $0.convert($0.bounds, to: host) }
            for frame in frames {
                precondition(frame.width >= 24 && frame.height >= 14, "Input field was squeezed")
                precondition(frame.minX >= 0 && frame.maxX <= width, "Input field escaped the panel")
            }
            for index in frames.indices {
                for other in frames.indices where other > index {
                    precondition(!frames[index].intersects(frames[other]), "Duration fields overlap")
                }
            }
            try render(host, to: output.appendingPathComponent("editor-\(Int(width)).png"))
            print("PASS editor at \(Int(width))pt: all six fields fit without overlap")
        }
        store.cancelEditingTime()
        try render(
            makeHost(DailyPlanHistoryView(store: store), size: CGSize(width: 360, height: 420)),
            to: output.appendingPathComponent("history.png")
        )
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
    private static func render(_ view: NSView, to url: URL) throws {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

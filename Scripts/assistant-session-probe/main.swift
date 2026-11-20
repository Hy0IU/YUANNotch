import AppKit
import SwiftUI

// External boundaries only: the real session, reply decoder and panel run without
// a network connection, Keychain entry, EventKit permission or visible window.
@MainActor private enum Fixture {
    static var replies: [String] = []
    static var applied: [String] = []
    static var stale: String?
    static var requests: [String] = []
    static var chunks: [String] = []
    static var afterChunk: ((Int) -> Void)?
}
@MainActor enum AssistantProvider {
    struct Configuration: Identifiable {
        let id = UUID()
        let name = "Fixture provider"
        let model = "Fixture model"
        let endpoint = URL(string: "https://example.invalid/v1/chat/completions")!
    }
    static let configuration: Configuration? = Configuration()
    static let configurations = configuration.map { [$0] } ?? []
    static let profilesChanged = Notification.Name("assistant-probe-profiles-changed")
    static func activate(_ id: UUID) {}
    static let endpointLabel = "https://example.invalid/v1/chat/completions"
    static let changed = Notification.Name("assistant-probe-provider-changed")
    static func complete(system: String, user: String, onDelta: @MainActor (String) -> Void) async throws -> String {
        Fixture.requests.append(user)
        let chunks = Fixture.chunks
        Fixture.chunks = []
        for (index, chunk) in chunks.enumerated() {
            onDelta(chunk)
            Fixture.afterChunk?(index)
        }
        return Fixture.replies.removeFirst()
    }
}
struct AssistantAgendaSnapshot { let modelContext: String }
struct AssistantPreparedChange {
    let summary: String
    var headline: String { "Create reminder · \(summary)" }
}
@MainActor final class AssistantAgenda {
    func snapshot(range: DateInterval, includeReminders: Bool, includeEvents: Bool, allowedSourceIDs: Set<String>) async throws -> AssistantAgendaSnapshot {
        AssistantAgendaSnapshot(modelContext: allowedSourceIDs.sorted().joined(separator: ","))
    }
    func prepare(_ action: AssistantAction, in snapshot: AssistantAgendaSnapshot) throws -> AssistantPreparedChange {
        guard let title = action.title, action.sourceID == snapshot.modelContext else { throw AssistantIssue("Outside selected sources") }
        return AssistantPreparedChange(summary: title)
    }
    func apply(_ change: AssistantPreparedChange) async throws {
        if Fixture.stale == change.summary { throw AssistantIssue("Source changed") }
        Fixture.applied.append(change.summary)
    }
}
@MainActor final class ScheduleStore: ObservableObject {
    @Published var sources = [ScheduleSource(id: "list", title: "List", account: "Test", kind: .reminders, color: ScheduleColor(red: 0, green: 0, blue: 0))]
    func isSelected(_ source: ScheduleSource) -> Bool { true }
    func requestRefresh() {}
}
@MainActor final class DailyPlanStore {
    struct Goal { let id: UUID; let title: String; let targetMinutes: Int }
    let plansForToday = [Goal(id: UUID(), title: "Private goal", targetMinutes: 45)]
    let today = Date()
    func focusedSeconds(for id: UUID, on date: Date) -> Double { 0 }
}

@main struct SessionProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let session = AssistantSession.shared
        let schedule = ScheduleStore(), plans = DailyPlanStore()
        func send(_ question: String, _ reply: String) async throws {
            session.input = question
            Fixture.replies.append(reply)
            session.send(schedule: schedule, plans: plans)
            precondition(session.lastRequest == question && session.input.isEmpty && session.answer.isEmpty && session.working,
                         "The request must appear independently of the model")
            for _ in 0..<200 where session.working { try await Task.sleep(for: .milliseconds(10)) }
            precondition(!session.working, "Session didn't finish")
        }
        let proposal = #"{"answer":"Review the two proposed reminders.","actions":[{"kind":"createReminder","sourceID":"list","title":"Register"},{"kind":"createReminder","sourceID":"list","title":"Prepare notes"}]}"#
        session.reminders = true
        try await send("Workshop on Friday, register by Thursday", proposal)
        precondition(session.error == nil && session.candidates.count == 2 && Fixture.applied.isEmpty)
        precondition(!Fixture.requests[0].contains("Private goal"))

        // Render the actual review surface offscreen; no system input or visible window.
        let panel = AssistantPanelView(scheduleStore: schedule, dailyPlanStore: plans, onBack: {}, onOpenSettings: {})
        let host = NSHostingView(rootView: panel.frame(width: 390, height: 260).background(Color(white: 0.06)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AssistantIssue("Panel did not render") }
        host.cacheDisplay(in: host.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else { throw AssistantIssue("No render data") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

        session.input = "Wait, change the deadline"
        await session.apply(schedule: schedule)
        precondition(Fixture.applied.isEmpty, "Typed revision must disable old Apply")
        try await send("Actually use these two", proposal)
        precondition(Fixture.requests.last!.contains("Workshop on Friday"), "Lost earlier request")
        Fixture.stale = "Prepare notes"
        await session.apply(schedule: schedule)
        precondition(Fixture.applied == ["Register"] && session.candidates.count == 1 && session.error != nil)
        Fixture.stale = nil
        await session.apply(schedule: schedule)
        precondition(Fixture.applied == ["Register", "Prepare notes"] && session.candidates.isEmpty)
        precondition(session.receipt.contains("Register") && session.receipt.contains("Prepare notes"))

        try await send("Suggest more", proposal)
        schedule.sources = []
        await session.apply(schedule: schedule)
        precondition(session.candidates.isEmpty && Fixture.applied.count == 2)
        try await send("Hello", #"{"answer":"Hello","actions":[]}"#)
        precondition(!Fixture.requests.last!.contains("Workshop") && !Fixture.requests.last!.contains("Register"))
        try await send("Discuss only", "You could move the workshop to Friday.")
        precondition(session.error == nil && session.answer.contains("Friday") && session.candidates.isEmpty)
        try await send("Invalid actions", #"{"answer":"OK","actions":[{"kind":"createEvent","attendees":["other"]}]}"#)
        precondition(session.error != nil && session.candidates.isEmpty && Fixture.applied.count == 2)
        Fixture.chunks = ["```js", "on\n{\"ans", "wer\": \"收到", "\\uD83D", "\\uDE03\\n明白", "\",\"actions\":", "[]}\n```"]
        Fixture.afterChunk = { index in
            precondition(session.working && session.candidates.isEmpty)
            if index == 2 || index == 3 { precondition(session.answer == "收到") }
            if index == 4 || index == 5 { precondition(session.answer == "收到😃\n明白") }
        }
        try await send("Streaming check", Fixture.chunks.joined())
        precondition(session.answer == "收到😃\n明白" && session.error == nil)
        Fixture.chunks = ["{\"answer\":\"Earlier model", " must not return\",\"actions\":[]}"]
        Fixture.afterChunk = { index in
            if index == 0 {
                session.input = "Keep this draft"
                NotificationCenter.default.post(name: AssistantProvider.changed, object: nil)
            }
        }
        Fixture.replies.append(Fixture.chunks.joined())
        session.input = "Switch while streaming"
        session.send(schedule: schedule, plans: plans)
        for _ in 0..<200 where session.working { try await Task.sleep(for: .milliseconds(10)) }
        precondition(session.input == "Keep this draft" && session.lastRequest.isEmpty &&
                     session.answer.isEmpty && session.candidates.isEmpty && session.error == nil)
        Fixture.afterChunk = nil

        func findComposer(_ view: NSView) -> AssistantComposerTextView? {
            if let text = view as? AssistantComposerTextView { return text }
            return view.subviews.lazy.compactMap(findComposer).first
        }
        func pressReturn(_ editor: NSTextView, modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                         characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            editor.keyDown(with: event)
        }
        session.reset()
        session.input = ""
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        guard let editor = findComposer(host), window.makeFirstResponder(editor) else { throw AssistantIssue("Composer is not focusable") }
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(editor.hasMarkedText())
        pressReturn(editor)
        precondition(!session.working && session.lastRequest.isEmpty, "Return during composition must not send")
        editor.unmarkText()
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("First line", replacementRange: NSRange(location: NSNotFound, length: 0))
        pressReturn(editor, modifiers: .shift)
        editor.insertText("Second line", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(session.input == "First line\nSecond line" && !session.working)
        Fixture.replies.append("Received")
        pressReturn(editor)
        precondition(session.lastRequest == "First line\nSecond line" && session.working && session.input.isEmpty)
        for _ in 0..<200 where session.working { try await Task.sleep(for: .milliseconds(10)) }
        precondition(session.answer == "Received")
        print("PASS native Return to send, Shift+Return newline, and no send during IME composition")
        print("PASS immediate request; live escaped answer without raw actions; model switch cancels old stream and keeps draft; proposal preview, revision, scope, partial failure/retry, and offscreen panel")
    }
}

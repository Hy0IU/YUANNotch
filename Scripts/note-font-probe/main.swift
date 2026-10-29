import AppKit
import Foundation

enum ReminderSortOrder: String { case added }

@MainActor
private final class BusyTextView: NSTextView {
    var marked = false
    var writingTools = false
    override func hasMarkedText() -> Bool { marked }
    @available(macOS 15.0, *)
    override var isWritingToolsActive: Bool { writingTools }
}

@main
struct NoteFontProbe {
    @MainActor
    private static func pump(_ seconds: TimeInterval = 0.06) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    static func main() {
        _ = NSApplication.shared
        let suiteName = "YUANNotch.NoteFontProbe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(defaults: defaults)
        let typography = NoteEditorTypographyState(settingsStore: settings)
        let interaction = EditorInteractionState()
        let coordinator = EditorFocusBinder.Coordinator()
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let textView = BusyTextView(frame: container.bounds)
        let binder = NSView(frame: .zero)
        textView.string = "中文组合输入与 Writing Tools"
        container.addSubview(textView)
        container.addSubview(binder)
        coordinator.bind(from: binder, state: interaction, typography: typography, documentId: "a")
        pump()

        textView.marked = true
        settings.noteFontSize = 24
        pump()
        precondition(typography.appliedFontSize == 15 && typography.hasDeferredFontSize)
        settings.noteFontSize = 18
        pump()
        textView.marked = false
        // No selection/text notification: the pending-only retry must apply it.
        pump(0.35)
        precondition(typography.appliedFontSize == 18 && !typography.hasDeferredFontSize)
        print("PASS marked input defers formatting and applies the latest size without another event")

        if #available(macOS 15.0, *) {
            textView.writingTools = true
            settings.noteFontSize = 24
            pump()
            precondition(typography.appliedFontSize == 18 && typography.hasDeferredFontSize)
            textView.writingTools = false
            pump(0.35)
            precondition(typography.appliedFontSize == 24 && !typography.hasDeferredFontSize)
            print("PASS simulated Writing Tools cancellation resumes a pending font update")
        }

        settings.noteFontSize = 24
        pump()
        textView.marked = true
        settings.noteFontSize = 12
        pump()
        settings.noteFontSize = 24
        pump()
        precondition(!typography.hasDeferredFontSize)
        textView.marked = false
        pump(0.2)
        precondition(typography.appliedFontSize == 24)
        print("PASS reverting the preference cancels its deferred update")

        textView.marked = true
        settings.noteFontSize = 12
        pump()
        coordinator.unbind()
        textView.marked = false
        settings.noteFontSize = 18
        pump(0.3)
        precondition(typography.appliedFontSize == 24)
        coordinator.bind(from: binder, state: interaction, typography: typography, documentId: "b")
        pump()
        precondition(typography.appliedFontSize == 18)
        coordinator.unbind()
        let discarded = NoteEditorTypographyState(settingsStore: settings)
        let discardedCoordinator = EditorFocusBinder.Coordinator()
        discardedCoordinator.bind(from: binder, state: interaction, typography: discarded, documentId: "c")
        discardedCoordinator.unbind()
        settings.noteFontSize = 24
        pump(0.3)
        precondition(discarded.appliedFontSize == 18)
        print("PASS unbind cancels retries and queued binding; rebind reads current preferences")

        let cases: [(String, NSEvent.ModifierFlags, UInt16, String)] = [
            ("+", [.command, .shift], 24, "increase"),
            ("=", [.command], 24, "increase"),
            ("-", [.command], 27, "decrease"),
            ("0", [.command], 29, "reset"),
            (",", [.command], 43, "none"),
            ("=", [], 24, "none"),
            ("=", [.command, .option], 24, "none"),
            ("-", [.command, .control], 27, "none")
        ]
        for (key, modifiers, code, expected) in cases {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
            let actual: String
            switch NoteFontSizeShortcut.action(for: event) {
            case .increase?: actual = "increase"
            case .decrease?: actual = "decrease"
            case .reset?: actual = "reset"
            case nil: actual = "none"
            }
            precondition(actual == expected)
        }
        typography.applyShortcut(.increase)
        precondition(settings.noteFontSize == 24)
        typography.applyShortcut(.decrease)
        precondition(settings.noteFontSize == 23)
        typography.applyShortcut(.reset)
        precondition(settings.noteFontSize == 15)
        print("PASS plus/equals/minus/reset keys and bounds; Settings shortcut and other modifiers are excluded")
    }
}

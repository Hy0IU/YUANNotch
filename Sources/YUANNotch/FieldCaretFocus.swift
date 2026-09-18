import AppKit
import SwiftUI

/// `.fieldCaretFocus(request:placeholder:)` — makes the matched field first
/// responder with the caret at the end of its text.
///
/// A text field on macOS selects all of its text when it becomes first responder.
/// Measured on this machine: `makeFirstResponder` and SwiftUI's `@FocusState` both
/// land on `selectedRange = {0, length}`, so a draft restored with the field
/// focused comes back highlighted — and the next keystroke replaces it. Focusing
/// here instead collapses the field editor's selection to the end, which is where
/// typing continues.
///
/// The field is found by its placeholder, which the caller already owns: a compose
/// row can show a second field (the custom time), and "first `NSTextField` in the
/// tree" is no way to tell them apart. The search is scoped to this window, so a
/// panel on another display cannot be reached by mistake.
struct FieldCaretFocus: ViewModifier {
    /// Raising this asks for focus; any other value leaves the field alone.
    let request: Int
    let placeholder: String

    func body(content: Content) -> some View {
        content.background(FieldFocusBridge(request: request, placeholder: placeholder))
    }
}

private struct FieldFocusBridge: NSViewRepresentable {
    let request: Int
    let placeholder: String

    func makeNSView(context: Context) -> FieldFocusRequestView {
        let view = FieldFocusRequestView()
        view.placeholder = placeholder
        return view
    }

    func updateNSView(_ view: FieldFocusRequestView, context: Context) {
        view.placeholder = placeholder
        view.handle(request: request)
    }
}

/// A zero-size view that carries the focus request into AppKit, where the field
/// and its editor are reachable.
@MainActor
final class FieldFocusRequestView: NSView {
    var placeholder = ""
    private var lastHandledRequest = 0

    func handle(request: Int) {
        guard request != lastHandledRequest else { return }
        // The field's own view may not exist yet on the first pass — the bridge
        // is laid out in the same transaction that creates it — so an unanswered
        // request is retried for a few turns rather than dropped.
        lastHandledRequest = request
        attemptFocus(remainingTries: 8)
    }

    private func attemptFocus(remainingTries: Int) {
        if focusField() { return }
        guard remainingTries > 0 else { return }
        Task { @MainActor [weak self] in
            self?.attemptFocus(remainingTries: remainingTries - 1)
        }
    }

    @discardableResult
    private func focusField() -> Bool {
        guard let contentView = window?.contentView,
              let field = Self.findField(placeholder: placeholder, in: contentView) else { return false }

        window?.makeFirstResponder(field)
        // `makeFirstResponder` installs the field editor and selects everything;
        // collapse the selection to the end, where typing continues.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
        return true
    }

    private static func findField(placeholder: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == placeholder {
            return field
        }
        for subview in view.subviews {
            if let field = findField(placeholder: placeholder, in: subview) {
                return field
            }
        }
        return nil
    }
}

extension View {
    /// See `FieldCaretFocus`.
    func fieldCaretFocus(request: Int, placeholder: String) -> some View {
        modifier(FieldCaretFocus(request: request, placeholder: placeholder))
    }
}

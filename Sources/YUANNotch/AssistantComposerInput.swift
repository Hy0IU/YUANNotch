import AppKit
import SwiftUI

struct AssistantComposerInput: NSViewRepresentable {
    static let height: CGFloat = 42

    @Binding var text: String
    @Binding var focused: Bool
    @Binding var composing: Bool
    let editable: Bool
    let onSend: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let frame = NSRect(x: 0, y: 0, width: 0, height: Self.height)
        let scrollView = NSScrollView(frame: frame)
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let editor = AssistantComposerTextView(frame: frame)
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.minSize = NSSize(width: 0, height: Self.height)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("输入问题，或粘贴一段通知")
        scrollView.documentView = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? AssistantComposerTextView else { return }
        editor.onSend = onSend
        editor.onFocus = { value in if focused != value { focused = value } }
        editor.onDraft = { value in if text != value { text = value } }
        editor.onComposition = { value in if composing != value { composing = value } }
        editor.updateDraft(text)
        if editor.isEditable != editable { editor.isEditable = editable }
    }
}

final class AssistantComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onDraft: ((String) -> Void)?
    var onComposition: ((Bool) -> Void)?
    private var updatingDraft = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocus?(false) }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        // Let the input method consume Return to choose its candidate. A later,
        // unmarked Return sends; a blocked send still consumes the keystroke.
        guard (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        switch event.modifierFlags.intersection([.shift, .command, .option, .control]) {
        case [], .command:
            onSend?()
        case .shift:
            if isEditable { insertNewline(nil) }
        default:
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        if !updatingDraft { onDraft?(string) }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        publishComposition()
    }

    override func unmarkText() {
        super.unmarkText()
        publishComposition()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        if wasComposing { publishComposition() }
    }

    func updateDraft(_ draft: String) {
        guard string != draft else { return }
        updatingDraft = true
        let wasComposing = hasMarkedText()
        if wasComposing {
            inputContext?.discardMarkedText()
            if hasMarkedText() { unmarkText() }
        }
        string = draft
        setSelectedRange(NSRange(location: draft.utf16.count, length: 0))
        updatingDraft = false
        if wasComposing {
            // An external draft reset can end composition during a SwiftUI update.
            Task { @MainActor [weak self] in
                guard let self else { return }
                onComposition?(hasMarkedText())
            }
        }
    }

    private func publishComposition() {
        guard !updatingDraft else { return }
        onDraft?(string)
        onComposition?(hasMarkedText())
    }
}

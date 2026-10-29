import AppKit
import Combine
import Foundation

@MainActor
final class NoteEditorTypographyState: ObservableObject {
    @Published private(set) var appliedFontSize: Double

    let settingsStore: AppSettingsStore
    private var pendingFontSize: Double?
    private weak var textView: NSTextView?
    var hasDeferredFontSize: Bool { pendingFontSize != nil }
    private var boundDocumentId: String?
    private var restoreGeneration = 0

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        appliedFontSize = AppTypography.normalizedNoteFontSize(settingsStore.noteFontSize)
    }

    func bind(to textView: NSTextView, documentId: String) {
        if self.textView !== textView || boundDocumentId != documentId {
            restoreGeneration += 1
        }
        self.textView = textView
        boundDocumentId = documentId
        applyRequestedFontSize(settingsStore.noteFontSize, in: textView)
    }

    func unbind(from textView: NSTextView) {
        guard self.textView === textView else { return }
        self.textView = nil
        boundDocumentId = nil
        restoreGeneration += 1
    }

    func prepareForDocument(_ documentId: String) {
        guard boundDocumentId != documentId else { return }
        boundDocumentId = documentId
        restoreGeneration += 1
    }

    func receiveRequestedFontSize(_ value: Double, in textView: NSTextView) {
        guard self.textView === textView else { return }
        applyRequestedFontSize(value, in: textView)
    }

    func applyShortcut(_ action: NoteFontSizeShortcut.Action) {
        let current = AppTypography.normalizedNoteFontSize(settingsStore.noteFontSize)
        let requested: Double
        switch action {
        case .decrease:
            requested = current - 1
        case .increase:
            requested = current + 1
        case .reset:
            requested = AppTypography.defaultNoteFontSize
        }

        let normalized = AppTypography.normalizedNoteFontSize(requested)
        guard normalized != current else { return }
        settingsStore.noteFontSize = normalized
    }

    func editingSessionMayHaveEnded(in textView: NSTextView) {
        guard self.textView === textView,
              let pendingFontSize,
              !hasActiveEditingSession(in: textView) else { return }
        self.pendingFontSize = nil
        applyFontSize(pendingFontSize, in: textView)
    }

    private func applyRequestedFontSize(_ value: Double, in textView: NSTextView) {
        let normalized = AppTypography.normalizedNoteFontSize(value)
        guard normalized != appliedFontSize else {
            pendingFontSize = nil
            return
        }

        guard !hasActiveEditingSession(in: textView) else {
            pendingFontSize = normalized
            return
        }

        pendingFontSize = nil
        applyFontSize(normalized, in: textView)
    }

    private func applyFontSize(_ value: Double, in textView: NSTextView) {
        guard value != appliedFontSize else { return }
        let anchor = ScrollAnchor.capture(from: textView)
        let documentId = boundDocumentId
        let originalText = textView.string
        restoreGeneration += 1
        let generation = restoreGeneration
        appliedFontSize = value

        // NativeTextViewWrapper applies the new base size and rebuilds its
        // existing Markdown attributes during SwiftUI's next representable
        // update. Restore the same text anchor after that layout pass.
        DispatchQueue.main.async { [weak textView] in
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self,
                      let textView,
                      self.textView === textView,
                      self.boundDocumentId == documentId,
                      self.restoreGeneration == generation,
                      textView.string == originalText else { return }
                anchor?.restore(in: textView)
            }
        }
    }

    private func hasActiveEditingSession(in textView: NSTextView) -> Bool {
        if textView.hasMarkedText() { return true }
        if #available(macOS 15.0, *), textView.isWritingToolsActive { return true }
        return false
    }
}

@MainActor
private struct ScrollAnchor {
    let characterIndex: Int
    let distanceBelowViewportTop: CGFloat

    static func capture(from textView: NSTextView) -> ScrollAnchor? {
        guard textView.window != nil,
              textView.enclosingScrollView != nil else { return nil }

        let visibleRect = textView.visibleRect
        let viewportTop = textView.isFlipped ? visibleRect.minY : visibleRect.maxY
        let insertionY = textView.isFlipped ? viewportTop + 1 : viewportTop - 1
        let insertionPoint = NSPoint(x: visibleRect.minX + 1, y: insertionY)
        let index = textView.characterIndexForInsertion(at: insertionPoint)
        let textLength = (textView.string as NSString).length
        guard index != NSNotFound, textLength > 0 else { return nil }

        let range = NSRange(location: min(index, textLength - 1), length: 1)
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        guard !screenRect.isEmpty, let window = textView.window else { return nil }
        let anchorRect = textView.convert(window.convertFromScreen(screenRect), from: nil)
        return ScrollAnchor(
            characterIndex: range.location,
            distanceBelowViewportTop: textView.isFlipped
                ? anchorRect.minY - visibleRect.minY
                : visibleRect.maxY - anchorRect.maxY
        )
    }

    func restore(in textView: NSTextView) {
        guard textView.window != nil,
              let scrollView = textView.enclosingScrollView else { return }

        let textLength = (textView.string as NSString).length
        guard textLength > 0 else { return }
        let range = NSRange(location: min(characterIndex, textLength - 1), length: 1)
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        guard !screenRect.isEmpty, let window = textView.window else { return }

        let anchorRect = textView.convert(window.convertFromScreen(screenRect), from: nil)
        let clipView = scrollView.contentView
        let desiredViewportTop = textView.isFlipped
            ? anchorRect.minY - distanceBelowViewportTop
            : anchorRect.maxY + distanceBelowViewportTop
        let maxOriginY = max(0, (scrollView.documentView?.frame.height ?? clipView.bounds.height) - clipView.bounds.height)
        let origin = NSPoint(
            x: clipView.bounds.origin.x,
            y: min(max(textView.isFlipped ? desiredViewportTop : desiredViewportTop - clipView.bounds.height, 0), maxOriginY)
        )
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}

enum NoteFontSizeShortcut {
    enum Action {
        case decrease
        case increase
        case reset
    }

    static func action(for event: NSEvent) -> Action? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              !modifiers.contains(.option),
              !modifiers.contains(.control) else { return nil }

        let shiftPressed = modifiers.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if shiftPressed {
            // On US keyboards, the physical equals key produces '+' with
            // Shift. Also accept '=' here for layouts that report the
            // unshifted character through charactersIgnoringModifiers.
            return (event.keyCode == 24 || key == "=" || key == "+") ? .increase : nil
        }

        switch key {
        case "=", "+": return .increase
        case "-": return .decrease
        case "0": return .reset
        default: return nil
        }
    }
}

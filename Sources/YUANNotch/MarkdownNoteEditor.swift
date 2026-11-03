import AppKit
import MarkdownEngine
import SwiftUI

struct MarkdownNoteEditor: View {
    @ObservedObject var store: NoteStore
    let settingsStore: AppSettingsStore
    let imageStore: LocalImageStore
    @ObservedObject var editorInteractionState: EditorInteractionState
    @StateObject private var typography: NoteEditorTypographyState
    @State private var isWikiLinkActive = false
    @State private var pendingInlineReplacement: InlineReplacementRequest?

    init(
        store: NoteStore,
        settingsStore: AppSettingsStore,
        imageStore: LocalImageStore,
        editorInteractionState: EditorInteractionState
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.imageStore = imageStore
        self.editorInteractionState = editorInteractionState
        _typography = StateObject(wrappedValue: NoteEditorTypographyState(settingsStore: settingsStore))
    }

    var body: some View {
        NativeTextViewWrapper(
            text: Binding(
                get: { store.text },
                set: { store.updateText($0) }
            ),
            isWikiLinkActive: $isWikiLinkActive,
            pendingInlineReplacement: $pendingInlineReplacement,
            configuration: NoteMarkdownStyle.configuration(
                fontSize: CGFloat(typography.appliedFontSize),
                services: MarkdownEditorServices(images: imageStore)
            ),
            fontName: "SF Pro",
            fontSize: CGFloat(typography.appliedFontSize),
            documentId: store.activeTabID.uuidString,
            isEditable: true,
            onPasteImage: savePastedImage
        )
        .accessibilityHint("Change note text size with Command-plus, Command-minus, or Command-zero. Command-equals is also supported.")
        .background {
            EditorFocusBinder(
                state: editorInteractionState,
                typography: typography,
                documentId: store.activeTabID.uuidString
            )
        }
    }

    private func savePastedImage(_ pasteboard: NSPasteboard) -> String? {
        imageStore.saveImage(from: pasteboard)
    }
}

import AppKit
import MarkdownEngine
import SwiftUI

struct MarkdownNoteEditor: View {
    @ObservedObject var store: NoteStore
    let imageStore: LocalImageStore
    let editorInteractionState: EditorInteractionState
    @State private var isWikiLinkActive = false
    @State private var pendingInlineReplacement: InlineReplacementRequest?

    /// Accent for everything the note editor draws outside its text: a list's
    /// marker glyph and a ticked task square. Kept as one value so the two
    /// can't drift into different reds.
    ///
    /// Specified in sRGB: `NSColor(calibratedRed:…)` is generic RGB at a
    /// gamma of 1.8, so the same triple would reach the screen as a lighter,
    /// less red-orange (measured: #FF7347 instead of #FF5C38 on this display).
    private static let markerAccent = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.22, alpha: 1.0)

    var body: some View {
        NativeTextViewWrapper(
            text: Binding(
                get: { store.text },
                set: { store.updateText($0) }
            ),
            isWikiLinkActive: $isWikiLinkActive,
            pendingInlineReplacement: $pendingInlineReplacement,
            configuration: configuration,
            fontName: "SF Pro",
            fontSize: 15,
            documentId: store.activeTabID.uuidString,
            isEditable: true,
            onPasteImage: savePastedImage
        )
        .background {
            EditorFocusBinder(state: editorInteractionState)
        }
    }

    private func savePastedImage(_ pasteboard: NSPasteboard) -> String? {
        imageStore.saveImage(from: pasteboard)
    }

    private var configuration: MarkdownEditorConfiguration {
        let theme = MarkdownEditorTheme(
            bodyText: NSColor(white: 0.92, alpha: 1),
            mutedText: NSColor(white: 0.58, alpha: 1),
            disabledText: NSColor(white: 0.38, alpha: 1),
            headingMarker: NSColor(white: 0.44, alpha: 1),
            listMarker: Self.markerAccent,
            link: NSColor.systemBlue,
            incompleteLink: NSColor.systemBlue.withAlphaComponent(0.75),
            findMatchHighlight: NSColor.systemYellow.withAlphaComponent(0.55),
            findCurrentMatchHighlight: NSColor.systemYellow,
            latexLightModeText: .white,
            latexDarkModeText: .white,
            strikethroughColor: NSColor(white: 0.62, alpha: 1),
            checkboxCheckedFill: Self.markerAccent
        )

        let services = MarkdownEditorServices(images: imageStore)

        return MarkdownEditorConfiguration(
            theme: theme,
            services: services,
            // A bullet is drawn a third larger than the body font: at 15pt the
            // dot goes from 3.0pt to 4.0pt across, which reads as a marker
            // rather than as a full stop. The styler cancels the width the
            // larger font adds, so no text column moves.
            lists: ListStyle(indentPerLevel: 18, extraLineHeight: 1, bulletFontScale: 1.35),
            imageEmbed: ImageEmbedStyle(fallbackMaxWidth: 440, paragraphSpacing: 6, imageGap: 6),
            overscroll: OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0),
            dragSelection: DragSelectionPolicy(movementThreshold: 8, edgeTriggerDistance: 8, scrollStepPerTick: 4, ticksPerSecond: 30),
            scrollers: .vertical,
            textInsets: TextInsets(horizontal: 12, vertical: 12)
        )
    }
}

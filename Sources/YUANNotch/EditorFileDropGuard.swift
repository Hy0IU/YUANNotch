import AppKit
import UniformTypeIdentifiers

/// Keeps the note editor from competing for file drags.
///
/// AppKit registers a text view for its entire readable type set the moment
/// it joins a window — measured at 19 types, including
/// `NSFilenamesPboardType`, `public.url` and the file-promise types. Drag
/// destination resolution prefers the deepest registered view, so a file
/// dragged over the editor is claimed by the text view: the panel's drop
/// feedback flips as the drag crosses the editor and back, and a file
/// released there is swallowed instead of landing on the shelf.
///
/// Two cleaner fixes do not work on the current macOS: overriding `hitTest`
/// on the hosting view is ignored by AppKit's destination resolution, and a
/// subclass cannot intercept the lazy registration (it bypasses
/// `registerForDraggedTypes`). Re-registering the text view *without* the
/// file types does work, and the removal sticks — verified that the text
/// view stays at zero registered types afterwards rather than re-arming
/// itself. Re-running this after the editor's views are rebuilt is
/// therefore enough.
///
/// Only drag types are narrowed; `readablePasteboardTypes` is untouched, so
/// pasting, text drags and image drags behave exactly as before.
@MainActor
enum EditorFileDropGuard {
    /// Pasteboard types that make a text view a file-drop destination.
    ///
    /// The legacy names are listed literally because they have no `UTType`:
    /// measured on a real Finder drag, the pasteboard offers
    /// `public.file-url`, `Apple URL pasteboard type`, `NSFilenamesPboardType`,
    /// `CorePasteboardFlavorType 0x6675726C` and `com.apple.finder.node`.
    /// Note `Apple URL pasteboard type` is NOT `NSPasteboard.PasteboardType.URL`
    /// (that one is `public.url` in this SDK) — missing it left the text view
    /// registered for file drags while appearing to be disarmed.
    private static let blockedNames: Set<String> = [
        NSPasteboard.PasteboardType.fileURL.rawValue,
        NSPasteboard.PasteboardType.URL.rawValue,
        "Apple URL pasteboard type",
        "public.url-name",
        "NSFilenamesPboardType",
        "WebURLsWithTitlesPboardType",
        "CorePasteboardFlavorType 0x6675726C",
        "com.apple.finder.node",
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-name",
        "com.apple.pasteboard.promised-file-content-type"
    ]

    /// True for anything a file or URL drag could match: the known legacy
    /// names, plus any type whose UTI descends from a URL.
    private static func isFileDragType(_ type: NSPasteboard.PasteboardType) -> Bool {
        if blockedNames.contains(type.rawValue) { return true }
        guard let utType = UTType(type.rawValue) else { return false }
        return utType.conforms(to: .fileURL) || utType.conforms(to: .url)
    }

    /// Re-registers every text view under `root` without the file drag
    /// types. Text, image and rich-text drops keep working.
    static func disarm(in root: NSView?) {
        guard let root else { return }

        for textView in textViews(in: root) {
            let registered = textView.registeredDraggedTypes
            guard !registered.isEmpty else { continue }

            let kept = registered.filter { !isFileDragType($0) }
            guard kept.count != registered.count else { continue }

            textView.unregisterDraggedTypes()
            textView.registerForDraggedTypes(kept)
            let removed = registered.filter { isFileDragType($0) }.map(\.rawValue)
            FileDragDiagnostics.log(
                "editor drag destination narrowed: \(registered.count) -> \(kept.count) types, removed \(removed)"
            )
        }
    }

    private static func textViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        if let textView = view as? NSTextView {
            found.append(textView)
        }
        for subview in view.subviews {
            found.append(contentsOf: textViews(in: subview))
        }
        return found
    }
}

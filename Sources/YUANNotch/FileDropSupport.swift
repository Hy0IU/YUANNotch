import AppKit
import Foundation
import SwiftUI

enum FileDropPayload {
    static func normalizedFileURLs(from urls: [URL]) -> [URL] {
        var knownPaths = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }

            let standardizedURL = url.standardizedFileURL
            guard knownPaths.insert(standardizedURL.path).inserted else {
                return nil
            }
            return standardizedURL
        }
    }
}

@MainActor
enum FileDropPasteboardReader {
    static func containsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL]) != nil
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.pasteboardItems?.compactMap { item -> URL? in
            guard let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL else {
                return nil
            }
            return url
        } ?? []

        return FileDropPayload.normalizedFileURLs(from: urls)
    }
}

enum FileDragPasteboard {
    static func writer(for url: URL) -> NSURL {
        url.standardizedFileURL as NSURL
    }
}

extension NSPasteboard.PasteboardType {
    /// Internal drag type marking a drag session as "reorder shelf items"
    /// rather than "drag files out". The payload is a JSON array of the
    /// dragged items' UUIDs, in shelf order.
    static let shelfReorder = NSPasteboard.PasteboardType("io.github.hy0iu.YUANNotch.shelf-reorder")
}

enum FileDragOperationPolicy {
    static let allowedOperations: NSDragOperation = [.copy, .generic]
}

enum FileDragGesturePolicy {
    static let activationDistance: CGFloat = 8

    static func shouldBegin(from start: NSPoint, to current: NSPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= activationDistance
    }
}

/// Hosting view for the compact notch that also accepts file drops.
/// SwiftUI may return nil from hitTest when every rendered pixel is
/// transparent, so keep the full compact frame interactive.
@MainActor
final class CompactFileDropHostingView<Content: View>: FirstMouseHostingView<Content> {
    var onFileDragTargeted: ((Bool) -> Void)?
    var onFilesDropped: (([URL]) -> Bool)?

    private var isFileDragTargeted = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard supportsFileURLs(sender.draggingPasteboard) else { return [] }
        setFileDragTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        supportsFileURLs(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setFileDragTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setFileDragTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        supportsFileURLs(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setFileDragTargeted(false) }
        let urls = FileDropPasteboardReader.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        return onFilesDropped?(urls) ?? false
    }

    private func supportsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL]) != nil
    }

    private func setFileDragTargeted(_ isTargeted: Bool) {
        guard isFileDragTargeted != isTargeted else { return }
        isFileDragTargeted = isTargeted
        onFileDragTargeted?(isTargeted)
    }
}

/// Hosting view for the expanded drawer that offers itself as a drop target
/// for external file drags.
///
/// Best-effort, and deliberately *not* load-bearing: AppKit's drag
/// destination resolution on the current macOS does not honour a `hitTest`
/// override on a hosting view, so this view never actually receives
/// `draggingEntered` — the drag is delivered to the SwiftUI
/// `dropDestination` inside `NotebookView` instead. The claim is kept
/// because it costs nothing and is the right behaviour wherever AppKit does
/// resolve to it, but the shelf's reveal and the drop both work without it.
@MainActor
final class DrawerFileDropHostingView<Content: View>: FirstMouseHostingView<Content> {
    /// True while an external file drag session should be claimed by the
    /// drawer (the file shelf is enabled, a file drag is in progress, and
    /// it did not originate from the shelf itself). Internal shelf-item
    /// drags keep flowing to their own reorder targets.
    var isFileDragActive: (() -> Bool)?
    var onFileDragTargeted: ((Bool) -> Void)?
    var onFilesDropped: (([URL]) -> Bool)?

    private var isFileDragTargeted = false
    private var isClaimingDrag = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Claim the whole drawer during external file drags. Drag sessions
        // consume mouse events, so ordinary hit-testing is unaffected.
        let shouldClaim = isFileDragActive?() == true && bounds.contains(point)
        if shouldClaim != isClaimingDrag {
            isClaimingDrag = shouldClaim
            FileDragDiagnostics.log(
                "drawer hitTest claim=\(shouldClaim) at=\(Int(point.x)),\(Int(point.y))"
            )
        }
        return shouldClaim ? self : super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard supportsFileURLs(sender.draggingPasteboard) else {
            FileDragDiagnostics.log("drawer draggingEntered: rejected (no fileURL)")
            return []
        }
        FileDragDiagnostics.log("drawer draggingEntered")
        setFileDragTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        supportsFileURLs(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // Never retract on exit: moving onto a deeper registered view reports
        // an exit too. The shelf's hide is owned by the controller's
        // end-of-session check.
        FileDragDiagnostics.log("drawer draggingExited (shelf stays revealed)")
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        FileDragDiagnostics.log("drawer draggingEnded")
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        supportsFileURLs(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileDropPasteboardReader.fileURLs(from: sender.draggingPasteboard)
        FileDragDiagnostics.log("drawer performDragOperation urls=\(urls.count)")
        guard !urls.isEmpty else { return false }
        return onFilesDropped?(urls) ?? false
    }

    private func supportsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL]) != nil
    }

    private func setFileDragTargeted(_ isTargeted: Bool) {
        guard isFileDragTargeted != isTargeted else { return }
        isFileDragTargeted = isTargeted
        onFileDragTargeted?(isTargeted)
    }
}

/// Detects a file drag coming from another app.
///
/// Two observations shape this detector:
///
/// 1. Writing the drag pasteboard IS the start of an AppKit drag session,
///    so a change in its change count is the authoritative "a drag started"
///    signal — it works even for drags our process never sees a mouse event
///    for (the source app runs the session in its own event loop).
/// 2. The baseline is *maintained by polling* rather than captured on a
///    mouse-down. Global mouse monitors turned out to be unreliable in
///    practice (a sandboxed or unauthorized process receives nothing), and
///    a predicate that silently depends on one would fail closed forever.
///
/// The baseline is therefore refreshed only while the button is up; while
/// it is held the baseline is frozen at its pre-drag value, so the drag's
/// pasteboard write keeps reading as "changed" for the whole gesture. Once
/// the button comes up the baseline catches up on the next tick, so a later
/// click can never look like a drag.
@MainActor
struct FileDragTrackingState {
    private var settledPasteboardChangeCount: Int?

    /// Records the drag pasteboard as "at rest". Called every poll tick
    /// while the left button is up.
    mutating func markPasteboardSettled(_ pasteboard: NSPasteboard) {
        settledPasteboardChangeCount = pasteboard.changeCount
    }

    func isFileDragInProgress(isLeftMouseButtonDown: Bool, pasteboard: NSPasteboard) -> Bool {
        guard isLeftMouseButtonDown,
              let settledPasteboardChangeCount,
              pasteboard.changeCount != settledPasteboardChangeCount,
              FileDropPasteboardReader.containsFileURLs(pasteboard) else {
            return false
        }

        return true
    }
}

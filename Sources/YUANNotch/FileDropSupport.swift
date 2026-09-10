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

    override required init(rootView: Content) {
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

/// Detects a file drag coming from another app by watching for the drag
/// pasteboard to change while the left mouse button is held and moving.
@MainActor
struct FileDragTrackingState {
    private(set) var mouseDownLocation: NSPoint?
    private(set) var mouseDownPasteboardChangeCount: Int?
    private(set) var didReachActivationDistance = false

    mutating func mouseDown(at location: NSPoint, pasteboardChangeCount: Int) {
        mouseDownLocation = location
        mouseDownPasteboardChangeCount = pasteboardChangeCount
        didReachActivationDistance = false
    }

    mutating func mouseDragged(to location: NSPoint) {
        guard let mouseDownLocation else { return }
        if FileDragGesturePolicy.shouldBegin(from: mouseDownLocation, to: location) {
            didReachActivationDistance = true
        }
    }

    mutating func mouseUp() {
        mouseDownLocation = nil
        mouseDownPasteboardChangeCount = nil
        didReachActivationDistance = false
    }

    func isFileDragInProgress(isLeftMouseButtonDown: Bool, pasteboard: NSPasteboard) -> Bool {
        guard isLeftMouseButtonDown,
              didReachActivationDistance,
              let mouseDownPasteboardChangeCount,
              pasteboard.changeCount != mouseDownPasteboardChangeCount,
              FileDropPasteboardReader.containsFileURLs(pasteboard) else {
            return false
        }

        return true
    }
}

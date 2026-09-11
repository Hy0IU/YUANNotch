import AppKit
import SwiftUI

/// Drop target overlay that turns shelf-internal drags into live reorders.
/// Hit-tests to nil unless a shelf drag is in progress, so it is completely
/// transparent to clicks, marquee selection, and external file drops.
@MainActor
struct FileShelfReorderTargetView: NSViewRepresentable {
    let isShelfDragActive: () -> Bool
    let insertionIndexProvider: (CGFloat, Set<UUID>) -> Int
    let onReorder: (Set<UUID>, Int) -> Void

    func makeNSView(context: Context) -> FileShelfReorderNSView {
        FileShelfReorderNSView()
    }

    func updateNSView(_ nsView: FileShelfReorderNSView, context: Context) {
        nsView.isShelfDragActive = isShelfDragActive
        nsView.insertionIndexProvider = insertionIndexProvider
        nsView.onReorder = onReorder
    }
}

@MainActor
final class FileShelfReorderNSView: NSView {
    var isShelfDragActive: (() -> Bool)?
    var insertionIndexProvider: ((CGFloat, Set<UUID>) -> Int)?
    var onReorder: ((Set<UUID>, Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // `.shelfReorder` only. Registering `.fileURL` as well made this view
        // the deepest registered destination in the shelf's strip, and AppKit
        // does not honour `hitTest` when resolving a drag destination — so
        // external file drops over the shelf were claimed here, found no
        // reorder payload, and were rejected. Internal reorders are
        // unaffected: the chips' drag always carries the reorder payload.
        registerForDraggedTypes([.shelfReorder])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShelfDragActive?() == true, bounds.contains(point) else { return nil }
        return self
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        applyReorder(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        applyReorder(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedIDs(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        applyReorder(sender) == .generic
    }

    private func applyReorder(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let ids = draggedIDs(from: sender.draggingPasteboard) else { return [] }
        let x = convert(sender.draggingLocation, from: nil).x
        let index = insertionIndexProvider?(x, ids) ?? 0
        onReorder?(ids, index)
        return .generic
    }

    private func draggedIDs(from pasteboard: NSPasteboard) -> Set<UUID>? {
        guard let raw = pasteboard.pasteboardItems?
                .compactMap({ $0.string(forType: .shelfReorder) })
                .first,
              let data = raw.data(using: .utf8),
              let ids = try? JSONDecoder().decode([UUID].self, from: data),
              !ids.isEmpty else {
            return nil
        }
        return Set(ids)
    }
}

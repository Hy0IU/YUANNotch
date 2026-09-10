import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct FileShelfChip: View {
    let item: FileShelfItem
    @ObservedObject var store: FileShelfStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    let isSelected: Bool
    let isDragged: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onSelectExclusive: () -> Void
    let dragURLs: () -> [URL]
    let dragItemIDs: () -> [UUID]
    let onSelectAll: () -> Void
    let onPreview: () -> Void
    let onDeleteSelected: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    @State private var isHovering = false
    @State private var thumbnail: NSImage?

    var body: some View {
        draggableChip
            .task(id: item.fallbackPath) {
                await store.refreshAvailability(item)
            }
            .task(id: thumbnailTaskID) {
                thumbnail = nil
                guard let url, isAvailable, isImage else { return }
                let loadedThumbnail = await FileShelfThumbnailLoader.thumbnail(for: url)
                guard !Task.isCancelled else { return }
                thumbnail = loadedThumbnail
            }
    }

    @ViewBuilder
    private var draggableChip: some View {
        if let url, isAvailable {
            chip
                .overlay {
                    FileDragSourceView(
                        url: url,
                        displayName: displayName,
                        dragURLs: dragURLs,
                        dragItemIDs: dragItemIDs,
                        onDragBegan: {
                            workspaceState.isDraggingShelfItem = true
                            workspaceState.isShelfDropTargeted = false
                            onDragBegan()
                        },
                        onDragEnded: {
                            workspaceState.isDraggingShelfItem = false
                            workspaceState.isShelfDropTargeted = false
                            onDragEnded()
                        },
                        onHoverChange: { isHovering = $0 },
                        onSelect: onSelect,
                        onSelectExclusive: onSelectExclusive,
                        onSelectAll: onSelectAll,
                        onPreview: onPreview,
                        onDeleteSelected: onDeleteSelected,
                        onOpen: open,
                        onReveal: revealInFinder,
                        onRemove: removeFromShelf
                    )
                }
        } else {
            chip.onHover { isHovering = $0 }
        }
    }

    private var chip: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 3) {
                ZStack(alignment: .bottomTrailing) {
                    fileIdentityImage

                    if !isAvailable {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.72))
                            .background(Circle().fill(Color.black))
                    }
                }

                Text(displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(
                        .white.opacity(
                            isAvailable ? (isSelected ? 0.92 : 0.66) : 0.34
                        )
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 52)
            }
            .frame(width: 60, height: 54)

            Button {
                removeFromShelf()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(ShelfRemoveButtonStyle())
            .help("Remove from shelf (file stays on disk)")
            .offset(x: 1, y: -1)
            .opacity(isHovering ? 1 : 0)
            .scaleEffect(isHovering ? 1 : 0.86)
            .allowsHitTesting(isHovering)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    .white.opacity(
                        isSelected ? 0.12 : (isHovering ? 0.065 : 0)
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(isSelected ? 0.20 : 0), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isDragged ? 0.35 : 1)
        .animation(.easeOut(duration: 0.13), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .help(
            isAvailable
                ? "\(displayName) · \(fileKind) · Press Space to preview"
                : "\(displayName) is unavailable"
        )
        .accessibilityLabel(displayName)
    }

    private var url: URL? {
        store.resolvedURL(for: item)
    }

    private var isAvailable: Bool {
        store.isAvailable(item)
    }

    private var displayName: String {
        guard let url, isAvailable else { return item.originalName }
        return url.lastPathComponent
    }

    private var fileKind: String {
        if item.isDirectory == true {
            return "Folder"
        }
        return effectiveFileExtension?.uppercased() ?? "File"
    }

    @ViewBuilder
    private var fileIdentityImage: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                }
        } else {
            Image(nsImage: fileIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .opacity(isAvailable ? 1 : 0.34)
        }
    }

    private var isImage: Bool {
        guard item.isDirectory != true,
              let fileExtension = effectiveFileExtension,
              let type = UTType(filenameExtension: fileExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private var effectiveFileExtension: String? {
        if let fileExtension = item.fileExtension, !fileExtension.isEmpty {
            return fileExtension
        }
        guard let pathExtension = url?.pathExtension, !pathExtension.isEmpty else { return nil }
        return pathExtension
    }

    private var thumbnailTaskID: String {
        "\(item.fallbackPath)|\(isAvailable)|\(isImage)"
    }

    private var fileIcon: NSImage {
        let contentType: UTType
        if item.isDirectory == true {
            contentType = .folder
        } else if let fileExtension = effectiveFileExtension,
                  let resolvedType = UTType(filenameExtension: fileExtension) {
            contentType = resolvedType
        } else {
            contentType = .data
        }

        let icon = NSWorkspace.shared.icon(for: contentType)
        icon.size = NSSize(width: 48, height: 48)
        return icon
    }

    private func open() {
        guard let url, isAvailable else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        guard let url, isAvailable else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func removeFromShelf() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            store.remove(item)
        }
    }
}

private struct FileDragSourceView: NSViewRepresentable {
    let url: URL
    let displayName: String
    let dragURLs: () -> [URL]
    let dragItemIDs: () -> [UUID]
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    let onHoverChange: (Bool) -> Void
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onSelectExclusive: () -> Void
    let onSelectAll: () -> Void
    let onPreview: () -> Void
    let onDeleteSelected: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    func makeNSView(context: Context) -> FileDragSourceNSView {
        FileDragSourceNSView()
    }

    func updateNSView(_ nsView: FileDragSourceNSView, context: Context) {
        nsView.url = url
        nsView.displayName = displayName
        nsView.dragURLs = dragURLs
        nsView.dragItemIDs = dragItemIDs
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
        nsView.onHoverChange = onHoverChange
        nsView.onSelect = onSelect
        nsView.onSelectExclusive = onSelectExclusive
        nsView.onSelectAll = onSelectAll
        nsView.onPreview = onPreview
        nsView.onDeleteSelected = onDeleteSelected
        nsView.onOpen = onOpen
        nsView.onReveal = onReveal
        nsView.onRemove = onRemove
    }
}

@MainActor
private final class FileDragSourceNSView: NSView, NSDraggingSource {
    var url: URL?
    var displayName = ""
    var dragURLs: (() -> [URL])?
    var dragItemIDs: (() -> [UUID])?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onSelectExclusive: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onPreview: (() -> Void)?
    var onDeleteSelected: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: (() -> Void)?

    private var didStartDrag = false
    private var mouseDownLocation: NSPoint?
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let removeButtonArea = NSRect(
            x: bounds.maxX - 20,
            y: bounds.maxY - 20,
            width: 20,
            height: 20
        )
        return removeButtonArea.contains(point) ? nil : super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        didStartDrag = false
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        onSelect?(event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            onSelectAll?()
        } else if event.keyCode == 49 {
            onPreview?()
        } else if event.keyCode == 51 || event.keyCode == 117 {
            onDeleteSelected?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard !didStartDrag,
              let mouseDownLocation,
              FileDragGesturePolicy.shouldBegin(from: mouseDownLocation, to: location),
              let url else {
            return
        }
        let urls = dragURLs?() ?? [url]
        guard !urls.isEmpty else { return }
        didStartDrag = true
        onHoverChange?(false)
        onDragBegan?()

        // The first dragging item also carries the reorder payload, so
        // dropping back onto the shelf reorders instead of re-adding.
        let reorderPayload: String? = {
            let ids = dragItemIDs?() ?? []
            guard !ids.isEmpty,
                  let data = try? JSONEncoder().encode(ids) else { return nil }
            return String(data: data, encoding: .utf8)
        }()

        let draggingItems = urls.enumerated().map { index, draggedURL in
            let icon = NSWorkspace.shared.icon(forFile: draggedURL.path)
            icon.size = NSSize(width: 44, height: 44)
            let offset = CGFloat(min(index, 3)) * 3
            let writer: NSPasteboardWriting
            if index == 0, let reorderPayload {
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(draggedURL.absoluteString, forType: .fileURL)
                pasteboardItem.setString(reorderPayload, forType: .shelfReorder)
                writer = pasteboardItem
            } else {
                writer = FileDragPasteboard.writer(for: draggedURL)
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            draggingItem.setDraggingFrame(
                NSRect(
                    x: location.x - 22 + offset,
                    y: location.y - 22 - offset,
                    width: 44,
                    height: 44
                ),
                contents: icon
            )
            return draggingItem
        }

        let session = beginDraggingSession(
            with: draggingItems,
            event: event,
            source: self
        )
        if draggingItems.count > 1 {
            session.draggingFormation = .stack
        }
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard !didStartDrag else { return }
        if event.modifierFlags.intersection([.command, .shift]).isEmpty {
            onSelectExclusive?()
        }
        if event.clickCount == 2 {
            onOpen?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        menu.addItem(menuItem(title: "Open", action: #selector(openItem)))
        menu.addItem(menuItem(title: "Show in Finder", action: #selector(revealItem)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Remove from Shelf", action: #selector(removeItem)))
        return menu
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        FileDragOperationPolicy.allowedOperations
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnded?()
        onHoverChange?(false)
        didStartDrag = false
        mouseDownLocation = nil
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openItem() {
        onOpen?()
    }

    @objc private func revealItem() {
        onReveal?()
    }

    @objc private func removeItem() {
        onRemove?()
    }
}

@MainActor
private enum FileShelfThumbnailLoader {
    static func thumbnail(for url: URL) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let imageData = await thumbnailData(for: url, scale: scale) else {
            return nil
        }
        return NSImage(data: imageData)
    }

    nonisolated private static func thumbnailData(
        for url: URL,
        scale: CGFloat
    ) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 96, height: 72),
            scale: scale,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage.tiffRepresentation)
            }
        }
    }
}

private struct ShelfRemoveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.58 : 0.82))
            .background(
                Circle()
                    .fill(.black.opacity(configuration.isPressed ? 0.72 : 0.58))
            )
            .contentShape(Circle())
    }
}

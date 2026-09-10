import AppKit
import SwiftUI


struct FileShelfView: View {
    @ObservedObject var store: FileShelfStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    let size: CGSize
    @StateObject private var previewController = FileShelfPreviewController()
    @State private var selection = FileShelfSelection()
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var selectionRect: CGRect?
    @State private var selectionAtDragStart: Set<UUID> = []
    @State private var keyboardFocusGeneration = 0

    private let selectionCoordinateSpace = "file-shelf-selection"

    var body: some View {
        ZStack(alignment: .topLeading) {
            FileShelfKeyboardFocusView(
                focusGeneration: keyboardFocusGeneration,
                onSelectAll: selectAllItems,
                onPreview: { previewSelection() },
                onDelete: removeSelectedItems
            )
            .allowsHitTesting(false)

            if !store.items.isEmpty {
                shelfItems
                    .padding(.horizontal, 6)
            }

            // Reorder drop target. Only hit-testable while a shelf drag is
            // in progress, so it never interferes with clicks, marquee
            // selection, or external file drops (those keep flowing to the
            // panel-level destination).
            FileShelfReorderTargetView(
                isShelfDragActive: { workspaceState.isDraggingShelfItem },
                insertionIndexProvider: { x, draggedIDs in
                    insertionIndex(forX: x, excluding: draggedIDs)
                },
                onReorder: { draggedIDs, index in
                    store.move(ids: draggedIDs, toIndex: index)
                }
            )

            marqueeEdgeZones
                .allowsHitTesting(!workspaceState.isShelfDropTargeted)

            if workspaceState.isShelfDropTargeted, store.items.isEmpty {
                dropPrompt
                    .frame(
                        width: size.width,
                        height: size.height,
                        alignment: .center
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if let selectionRect,
               selectionRect.width >= 3,
               selectionRect.height >= 3 {
                Rectangle()
                    .fill(Color.white.opacity(0.055))
                    .overlay {
                        Rectangle()
                            .stroke(Color.white.opacity(0.34), lineWidth: 1)
                    }
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .offset(x: selectionRect.minX, y: selectionRect.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: selectionCoordinateSpace)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(workspaceState.isShelfDropTargeted ? 0.055 : 0.025))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    .white.opacity(workspaceState.isShelfDropTargeted ? 0.16 : 0),
                    lineWidth: 1
                )
        }
        .shadow(
            color: .black.opacity(workspaceState.isShelfDropTargeted ? 0.24 : 0),
            radius: 18,
            y: 8
        )
        .animation(.spring(response: 0.30, dampingFraction: 0.84), value: workspaceState.isShelfDropTargeted)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.items)
        .onPreferenceChange(FileShelfItemFramePreferenceKey.self) { frames in
            Task { @MainActor in
                itemFrames = frames
            }
        }
        .onChange(of: store.items.map(\.id)) { _, itemIDs in
            selection.retainValidIDs(Set(itemIDs))
        }
        .onChange(of: workspaceState.isDraggingShelfItem) { _, isDragging in
            if isDragging {
                cancelMarqueeSelection()
            }
        }
        .onChange(of: workspaceState.isShelfDropTargeted) { _, isTargeted in
            if isTargeted {
                cancelMarqueeSelection()
            }
        }
        .onDisappear {
            cancelMarqueeSelection()
            previewController.close()
        }
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    store.removeAll()
                }
            } label: {
                Label("Remove All Shelf Items", systemImage: "xmark.circle")
            }
            .disabled(store.items.isEmpty)
        }
    }

    private var dropPrompt: some View {
        HStack(spacing: 7) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 9, weight: .semibold))

            Text("Release to add")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Color.white.opacity(0.58))
    }

    private var shelfItems: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            marqueeGap
                        }

                        FileShelfChip(
                            item: item,
                            store: store,
                            workspaceState: workspaceState,
                            isSelected: selection.selectedIDs.contains(item.id),
                            isDragged: workspaceState.draggedShelfItemIDs.contains(item.id),
                            onSelect: { modifiers in
                                selectForMouseDown(item.id, modifiers: modifiers)
                            },
                            onSelectExclusive: {
                                selection.selectExclusively(item.id)
                            },
                            dragURLs: {
                                selectedURLs(startingAt: item.id)
                            },
                            dragItemIDs: {
                                draggedItemIDs(startingAt: item.id)
                            },
                            onSelectAll: selectAllItems,
                            onPreview: {
                                previewSelection(preferredID: item.id)
                            },
                            onDeleteSelected: removeSelectedItems,
                            onDragBegan: {
                                workspaceState.draggedShelfItemIDs = Set(
                                    draggedItemIDs(startingAt: item.id)
                                )
                            },
                            onDragEnded: {
                                workspaceState.draggedShelfItemIDs = []
                            }
                        )
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: FileShelfItemFramePreferenceKey.self,
                                    value: [
                                        item.id: proxy.frame(
                                            in: .named(selectionCoordinateSpace)
                                        )
                                    ]
                                )
                            }
                        }
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.92))
                        )
                    }
                }
                .padding(.vertical, 6)
            }

            dumpAllButton
        }
    }

    /// One-click "pour out": clears the shelf list only — the files on disk
    /// are never touched. Rendered inside the shelf, which itself only
    /// exists while the shelf is enabled in Settings.
    private var dumpAllButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                store.removeAll()
            }
        } label: {
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clear shelf (files stay on disk)")
        .padding(.leading, 2)
        .padding(.trailing, 4)
    }

    private var marqueeGap: some View {
        Color.clear
            .frame(width: 5)
            .contentShape(Rectangle())
            .gesture(selectionGesture)
    }

    private var marqueeEdgeZones: some View {
        ZStack {
            VStack(spacing: 0) {
                marqueeStartSurface.frame(height: 6)
                Spacer(minLength: 0)
                marqueeStartSurface.frame(height: 6)
            }

            HStack(spacing: 0) {
                marqueeStartSurface.frame(width: 6)
                Spacer(minLength: 0)
                marqueeStartSurface.frame(width: 6)
            }
        }
    }

    private var marqueeStartSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(selectionGesture)
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(selectionCoordinateSpace))
            .onChanged { value in
                guard !workspaceState.isShelfDropTargeted else { return }

                if selectionRect == nil {
                    selectionAtDragStart = selection.selectedIDs
                    keyboardFocusGeneration += 1
                }

                let rect = CGRect(
                    x: value.startLocation.x,
                    y: value.startLocation.y,
                    width: value.location.x - value.startLocation.x,
                    height: value.location.y - value.startLocation.y
                ).standardized
                let enclosedIDs = Set(
                    itemFrames.compactMap { id, frame in
                        frame.intersects(rect) ? id : nil
                    }
                )
                selection.applyMarquee(
                    enclosedIDs: enclosedIDs,
                    initialSelection: selectionAtDragStart,
                    modifiers: NSEvent.modifierFlags
                )
                selectionRect = rect
            }
            .onEnded { _ in
                selectionRect = nil
                selectionAtDragStart = []
            }
    }

    private func selectForMouseDown(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        cancelMarqueeSelection()
        selection.selectForMouseDown(
            id,
            orderedIDs: store.items.map(\.id),
            modifiers: modifiers
        )
    }

    private func selectAllItems() {
        selection.selectAll(store.items.map(\.id))
    }

    private func removeSelectedItems() {
        guard !selection.isEmpty else { return }
        store.remove(ids: selection.selectedIDs)
        selection.clear()
        previewController.close()
    }

    private func selectedURLs(startingAt id: UUID? = nil) -> [URL] {
        let selectedIDs = selection.orderedSelection(
            from: store.items.map(\.id),
            startingAt: id
        )
        let itemByID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })

        return selectedIDs.compactMap { id in
            guard let item = itemByID[id], store.isAvailable(item) else { return nil }
            return store.resolvedURL(for: item)
        }
    }

    /// The IDs that travel with a drag started on `id`, in shelf order —
    /// mirrors `selectedURLs`' availability filtering.
    private func draggedItemIDs(startingAt id: UUID) -> [UUID] {
        let itemByID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
        return selection.orderedSelection(from: store.items.map(\.id), startingAt: id)
            .filter { id in
                guard let item = itemByID[id] else { return false }
                return store.isAvailable(item)
            }
    }

    /// Insertion position for a reorder drag at shelf-local x, counted over
    /// the items that are NOT being dragged (matching `FileShelfStore.move`).
    private func insertionIndex(forX x: CGFloat, excluding draggedIDs: Set<UUID>) -> Int {
        var index = 0
        for item in store.items where !draggedIDs.contains(item.id) {
            guard let frame = itemFrames[item.id], frame.midX < x else { return index }
            index += 1
        }
        return index
    }

    private func previewSelection(preferredID: UUID? = nil) {
        let urls = selectedURLs(startingAt: preferredID)
        guard !urls.isEmpty else { return }

        let preferredURL = preferredID.flatMap { id in
            store.items.first(where: { $0.id == id }).flatMap(store.resolvedURL)
        }
        previewController.toggle(urls: urls, preferredURL: preferredURL) { isVisible in
            workspaceState.isPreviewingShelfItem = isVisible
        }
    }

    private func cancelMarqueeSelection() {
        selectionRect = nil
        selectionAtDragStart = []
    }
}

private struct FileShelfItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

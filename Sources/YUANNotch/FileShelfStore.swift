import Combine
import Foundation

@MainActor
final class NotebookWorkspaceState: ObservableObject {
    @Published var isShelfDropTargeted = false
    @Published var isDraggingShelfItem = false
    @Published var isPreviewingShelfItem = false
    @Published var isFileShelfCollapsed = false
    /// Set while an external file drag is in progress.
    ///
    /// The drawer has to show the notes surface then — the file shelf lives
    /// there, and a drop is rejected on the reminders surface — but
    /// `AppSettingsStore.drawerMode` writes through to `UserDefaults` on every
    /// assignment, so borrowing the surface for the duration of a drag must not
    /// go through it. This is that session-scoped borrow: a drag that is
    /// cancelled leaves the user's chosen mode exactly as it was.
    ///
    /// A drag that *lands* is different, and is handled where the drop is
    /// accepted rather than here: the user has just used the notes side, so the
    /// mode is changed for real at that point.
    @Published var fileDragForcesNotesMode = false

    /// Whether the drawer is showing the reminders surface.
    ///
    /// The session override wins: the file shelf lives on the notes surface, so
    /// an in-flight file drag must show it whatever the user persisted. This is
    /// the single place that precedence is expressed — the notebook view and the
    /// panel controller both ask this, instead of each spelling out the
    /// conjunction (which is how they silently drift apart).
    func showsReminders(persistedMode: DrawerMode) -> Bool {
        persistedMode == .reminders && !fileDragForcesNotesMode
    }

    /// Called when a file actually lands in the shelf.
    ///
    /// A landed drop tells us which side the user is working on — the shelf only
    /// exists on the notes surface — so the borrowed surface becomes the chosen
    /// one. That is why this clears the drag override *and* moves the persisted
    /// mode: leaving the override set while nothing borrows it would just be a
    /// persisted mode with worse bookkeeping.
    ///
    /// Defined once because both drop paths have to express it — the panel's
    /// host view and the notebook's SwiftUI target — and a rule written twice is
    /// a rule that drifts.
    func commitLandedFileDrop(to drawerMode: inout DrawerMode) {
        fileDragForcesNotesMode = false
        drawerMode = .notes
    }
    /// IDs of the shelf items being dragged right now (for dimming the
    /// dragged chips and excluding them from reorder hit-testing).
    @Published var draggedShelfItemIDs: Set<UUID> = []
}

struct FileShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let bookmarkData: Data?
    let fallbackPath: String
    let originalName: String
    let addedAt: Date
    let isDirectory: Bool?
    let fileExtension: String?

    init(url: URL) {
        id = UUID()
        // File bookmarks can block the main thread when they are created
        // synchronously inside AppKit's drop callback. The shelf is temporary,
        // so keeping the normalized path is sufficient and avoids that stall.
        bookmarkData = nil
        fallbackPath = url.standardizedFileURL.path
        originalName = url.lastPathComponent
        addedAt = Date()
        isDirectory = url.hasDirectoryPath
        fileExtension = url.pathExtension.isEmpty ? nil : url.pathExtension
    }
}

@MainActor
final class FileShelfStore: ObservableObject {
    @Published private(set) var items: [FileShelfItem]
    @Published private var availabilityByID: [UUID: Bool] = [:]

    private static let storageKey = "yuanNotch.fileShelf.v1"
    private static let maximumItemCount = 100
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Self.load(from: defaults)
    }

    @discardableResult
    func acceptDrop(_ urls: [URL]) -> Bool {
        let fileURLs = FileDropPayload.normalizedFileURLs(from: urls)
        guard !fileURLs.isEmpty else { return false }

        _ = add(fileURLs)
        return true
    }

    @discardableResult
    func add(_ urls: [URL]) -> Int {
        let existingPaths = Set(items.compactMap { resolvedURL(for: $0)?.standardizedFileURL.path })
        var knownPaths = existingPaths
        var addedItems: [FileShelfItem] = []

        for url in urls where url.isFileURL {
            let standardizedURL = url.standardizedFileURL

            if items.contains(where: {
                resolvedURL(for: $0)?.standardizedFileURL.path == standardizedURL.path
            }) {
                continue
            }

            guard items.count + addedItems.count < Self.maximumItemCount else { break }
            guard knownPaths.insert(standardizedURL.path).inserted else { continue }
            addedItems.append(FileShelfItem(url: standardizedURL))
        }

        guard !addedItems.isEmpty else { return 0 }
        items.append(contentsOf: addedItems)
        save()
        return addedItems.count
    }

    func remove(_ item: FileShelfItem) {
        remove(ids: [item.id])
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        for id in ids {
            availabilityByID[id] = nil
        }
        save()
    }

    func removeAll() {
        items.removeAll()
        availabilityByID.removeAll()
        save()
    }

    /// Reorders the shelf by inserting the dragged block at `index`, counted
    /// over the items that are NOT being dragged. Called continuously while
    /// a reorder drag hovers the shelf; no-ops when the order is unchanged.
    func move(ids: Set<UUID>, toIndex index: Int) {
        let moving = items.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        var reordered = items.filter { !ids.contains($0.id) }
        reordered.insert(contentsOf: moving, at: max(0, min(index, reordered.count)))
        guard reordered != items else { return }
        items = reordered
        save()
    }

    func resolvedURL(for item: FileShelfItem) -> URL? {
        URL(fileURLWithPath: item.fallbackPath).standardizedFileURL
    }

    func isAvailable(_ item: FileShelfItem) -> Bool {
        availabilityByID[item.id] ?? true
    }

    func refreshAvailability(_ item: FileShelfItem) async {
        let path = item.fallbackPath
        let isAvailable = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path)
        }.value

        guard items.contains(where: { $0.id == item.id }) else { return }
        availabilityByID[item.id] = isAvailable
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> [FileShelfItem] {
        guard let data = defaults.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([FileShelfItem].self, from: data) else {
            return []
        }

        return items
    }
}

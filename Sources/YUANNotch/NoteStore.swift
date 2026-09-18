import Combine
import Foundation

struct NoteTab: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    var selectionLocation: Int?
    var selectionLength: Int?

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        selectionLocation = 0
        selectionLength = 0
    }
}

/// The notebook as the interface sees it: which pages exist, what is in them, and
/// where the caret sits.
///
/// This type decides *when* a note reaches disk — a short debounce while typing,
/// immediately for anything structural — and nothing about *how* it gets there.
/// The files, their names and the index belong to `NotesLibrary`; keeping the
/// policy here and the mechanism there is what stops the two from drifting into
/// different ideas of what "saved" means.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var tabs: [NoteTab]
    @Published private(set) var activeTabID: UUID

    private let library: NotesLibrary
    private var pendingSaveTask: Task<Void, Never>?
    private var isDirty = false
    private var cancellables: Set<AnyCancellable> = []

    init(library: NotesLibrary) {
        self.library = library

        let workspace = library.load()
        tabs = workspace.tabs
        activeTabID = workspace.activeTabID

        // Changing the notes folder replaces the pages wholesale, and the pages are
        // this type's to hold: the settings page changes the folder and says nothing
        // about the notebook.
        library.folderChanged
            .sink { [weak self] _ in self?.reloadFromLibrary() }
            .store(in: &cancellables)
    }

    var text: String {
        tabs[activeIndex].text
    }

    func updateText(_ nextText: String) {
        tabs[activeIndex].text = nextText
        clampSelection(for: tabs[activeIndex].id)
        isDirty = true
        scheduleDebouncedSave()
    }

    func clear() {
        // Clearing an already-empty tab is not an event: there is nothing to
        // write, nothing to confirm, and the button is reachable in that state.
        guard !tabs[activeIndex].text.isEmpty else { return }

        // The page's file is moved aside rather than overwritten, so "Clear" is
        // recoverable from the Trash like any other deletion. The page itself
        // stays, empty and without a file, until the next thing typed into it.
        library.trashFile(forTab: activeTabID)
        updateText("")
        updateSelection(for: activeTabID, range: NSRange(location: 0, length: 0))
        saveImmediately()
        InterfaceSound.cleared()
    }

    func addTab() {
        let tab = NoteTab()
        tabs.append(tab)
        activeTabID = tab.id
        isDirty = true
        saveImmediately()
    }

    func removeActiveTab() {
        guard tabs.count > 1 else { return }
        let removedIndex = activeIndex
        let removedID = tabs[removedIndex].id
        tabs.remove(at: removedIndex)
        let nextIndex = min(removedIndex, tabs.count - 1)
        activeTabID = tabs[nextIndex].id
        library.trashFile(forTab: removedID)
        isDirty = true
        saveImmediately()
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        isDirty = true
        saveImmediately()
    }

    func updateSelection(for id: UUID, range: NSRange) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let clamped = clampedRange(range, text: tabs[index].text)
        guard tabs[index].selectionLocation != clamped.location
                || tabs[index].selectionLength != clamped.length else { return }
        tabs[index].selectionLocation = clamped.location
        tabs[index].selectionLength = clamped.length
        isDirty = true
        scheduleDebouncedSave()
    }

    func flushPendingSave() {
        guard isDirty else { return }
        saveImmediately()
    }

    func selectionRange(for id: UUID) -> NSRange {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return NSRange(location: 0, length: 0)
        }

        return clampedRange(
            NSRange(location: tab.selectionLocation ?? 0, length: tab.selectionLength ?? 0),
            text: tab.text
        )
    }

    // MARK: - The folder

    /// Brings Markdown files that no page claims into the notebook as pages.
    ///
    /// The one way back from a lost or unreadable index, and the reason it is a
    /// button rather than something that happens on launch: a folder can be
    /// picked that already holds Markdown, and only the person looking at it can
    /// say whether those files are the notebook's or somebody else's.
    @discardableResult
    func adoptLooseMarkdownFiles() -> Int {
        let adopted = library.adoptUnclaimedMarkdown()
        guard !adopted.isEmpty else { return 0 }

        tabs.append(contentsOf: adopted)
        isDirty = true
        saveImmediately()
        return adopted.count
    }

    /// Moves the notebook to another folder, copying the files across and leaving
    /// the originals where they are.
    func moveNotes(to url: URL) {
        flushPendingSave()
        library.copyNotes(to: url)
    }

    // MARK: - Saving

    private var activeIndex: Int {
        tabs.firstIndex { $0.id == activeTabID } ?? 0
    }

    private func reloadFromLibrary() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        let workspace = library.load()
        tabs = workspace.tabs
        activeTabID = workspace.activeTabID
        isDirty = false
    }

    private func clampSelection(for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let range = NSRange(location: tabs[index].selectionLocation ?? 0, length: tabs[index].selectionLength ?? 0)
        let clamped = clampedRange(range, text: tabs[index].text)
        tabs[index].selectionLocation = clamped.location
        tabs[index].selectionLength = clamped.length
    }

    private func clampedRange(_ range: NSRange, text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(range.location, 0), length)
        let selectionLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: selectionLength)
    }

    private func scheduleDebouncedSave() {
        guard isDirty else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled, let self else { return }
            self.pendingSaveTask = nil
            self.saveIfDirty()
        }
    }

    private func saveImmediately() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveIfDirty()
    }

    private func saveIfDirty() {
        guard isDirty else { return }
        if library.save(tabs: tabs, activeTabID: activeTabID) {
            isDirty = false
        }
    }
}

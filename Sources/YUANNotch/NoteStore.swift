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

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var tabs: [NoteTab]
    @Published private(set) var activeTabID: UUID

    private static let legacyTextKey = "yuanNotch.text"
    private static let tabsKey = "yuanNotch.tabs.v1"
    private static let activeTabIDKey = "yuanNotch.activeTabID"

    private let persistence: NotePersistence
    private var pendingSaveTask: Task<Void, Never>?
    private var isDirty = false

    init() {
        let persistence = NotePersistence()
        self.persistence = persistence

        let loadResult = persistence.load()
        let workspace: NotePersistence.Workspace
        switch loadResult {
        case .loaded(let storedWorkspace):
            workspace = storedWorkspace
        case .missing:
            // The old defaults remain in place as a rollback source. Migration
            // is complete only when this first workspace write succeeds.
            workspace = Self.workspaceFromUserDefaults()
        case .failed:
            // Never save this fallback automatically: the unreadable workspace
            // must not be replaced by an empty one.
            let fallbackTab = NoteTab()
            workspace = NotePersistence.Workspace(
                version: NotePersistence.currentVersion,
                tabs: [fallbackTab],
                activeTabID: fallbackTab.id
            )
            NSLog("YUANNotch: workspace load failed; using an in-memory fallback without overwriting the existing file")
        }

        tabs = workspace.tabs
        activeTabID = workspace.activeTabID

        if case .missing = loadResult {
            isDirty = true
            if !saveIfDirty() {
                NSLog("YUANNotch: workspace migration did not complete; it will be retried while the file is missing")
            }
        }
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
        updateText("")
        updateSelection(for: activeTabID, range: NSRange(location: 0, length: 0))
        saveImmediately()
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
        tabs.remove(at: removedIndex)
        let nextIndex = min(removedIndex, tabs.count - 1)
        activeTabID = tabs[nextIndex].id
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

    private var activeIndex: Int {
        tabs.firstIndex { $0.id == activeTabID } ?? 0
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

    @discardableResult
    private func saveIfDirty() -> Bool {
        guard isDirty else { return true }

        let workspace = NotePersistence.Workspace(
            version: NotePersistence.currentVersion,
            tabs: tabs,
            activeTabID: activeTabID
        )
        let didSave = persistence.save(workspace)
        if didSave {
            isDirty = false
        }
        return didSave
    }

    private static func workspaceFromUserDefaults() -> NotePersistence.Workspace {
        let defaults = UserDefaults.standard
        if let workspace = workspace(
            from: defaults,
            tabsKey: tabsKey,
            activeTabIDKey: activeTabIDKey
        ) {
            return workspace
        }

        let legacyDefaults = ["io.github.oiloil.NotchNotes", "NotchNotes"]
            .compactMap(UserDefaults.init(suiteName:))
        for defaults in legacyDefaults {
            if let workspace = workspace(
                from: defaults,
                tabsKey: "notchNotes.tabs.v1",
                activeTabIDKey: "notchNotes.activeTabID"
            ) {
                return workspace
            }
        }

        for defaults in legacyDefaults {
            if let text = defaults.string(forKey: "notchNotes.text") {
                return workspaceFromText(text)
            }
        }

        return workspaceFromText(defaults.string(forKey: legacyTextKey) ?? "")
    }

    private static func workspace(
        from defaults: UserDefaults,
        tabsKey: String,
        activeTabIDKey: String
    ) -> NotePersistence.Workspace? {
        guard let data = defaults.data(forKey: tabsKey),
              let storedTabs = try? JSONDecoder().decode([NoteTab].self, from: data),
              !storedTabs.isEmpty else {
            return nil
        }

        let storedActiveID = defaults.string(forKey: activeTabIDKey).flatMap(UUID.init(uuidString:))
        let activeID = storedActiveID.flatMap { candidate in
            storedTabs.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? storedTabs[0].id
        let workspace = NotePersistence.Workspace(
            version: NotePersistence.currentVersion,
            tabs: storedTabs,
            activeTabID: activeID
        )

        guard (try? NotePersistence.validate(workspace)) != nil else { return nil }
        return workspace
    }

    private static func workspaceFromText(_ text: String) -> NotePersistence.Workspace {
        let tab = NoteTab(text: text)
        return NotePersistence.Workspace(
            version: NotePersistence.currentVersion,
            tabs: [tab],
            activeTabID: tab.id
        )
    }
}

import Foundation

/// Where the notes lived before each page had a file of its own.
///
/// Every source here is frozen: none of these keys or files is written any more,
/// and none of them grows with the app. Keeping the reader costs nothing, while
/// dropping it is one-way — a launch that finds the new folder empty would have
/// no way back to the notes that were still sitting in the old shape.
///
/// The sources are tried in the order the app itself used them: the single
/// document, then this app's tab blob, then the `NotchNotes` era's keys, then the
/// single note that predates tabs.
enum LegacyNotesSource {

    private struct StoredWorkspace: Decodable {
        let version: Int
        let tabs: [NoteTab]
        let activeTabID: UUID
    }

    private static let preTabsTextKey = "yuanNotch.text"
    private static let tabsKey = "yuanNotch.tabs.v1"
    private static let activeTabIDKey = "yuanNotch.activeTabID"

    private static let legacyDomainNames = ["io.github.oiloil.NotchNotes", "NotchNotes"]
    private static let legacyTabsKey = "notchNotes.tabs.v1"
    private static let legacyActiveTabIDKey = "notchNotes.activeTabID"
    private static let legacyTextKey = "notchNotes.text"

    /// Every page the old storage held, in order. Empty when there is nothing to
    /// migrate, which is the ordinary case on a machine that never ran the old
    /// build.
    static func loadTabs() -> [NoteTab] {
        if let tabs = tabsFromWorkspaceFile() {
            NSLog("YUANNotch: found \(tabs.count) note(s) in the old workspace.json")
            return tabs
        }

        if let tabs = tabs(
            from: .standard,
            tabsKey: tabsKey,
            activeTabIDKey: activeTabIDKey
        ) {
            NSLog("YUANNotch: found \(tabs.count) note(s) in this app's defaults")
            return tabs
        }

        let legacyDefaults = legacyDomainNames.compactMap(UserDefaults.init(suiteName:))
        for defaults in legacyDefaults {
            if let tabs = tabs(
                from: defaults,
                tabsKey: legacyTabsKey,
                activeTabIDKey: legacyActiveTabIDKey
            ) {
                NSLog("YUANNotch: found \(tabs.count) note(s) under the previous app identity")
                return tabs
            }
        }

        for defaults in legacyDefaults {
            if let text = defaults.string(forKey: legacyTextKey), !text.isEmpty {
                return [NoteTab(text: text)]
            }
        }

        // Last resort: this app's own note from before tabs existed.
        let text = UserDefaults.standard.string(forKey: preTabsTextKey) ?? ""
        return text.isEmpty ? [] : [NoteTab(text: text)]
    }

    private static func tabsFromWorkspaceFile() -> [NoteTab]? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = support.appendingPathComponent("YUANNotch", isDirectory: true)
        let candidates = [
            directory.appendingPathComponent("workspace.json"),
            directory.appendingPathComponent("workspace.json.backup")
        ]

        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                let stored = try JSONDecoder().decode(StoredWorkspace.self, from: data)
                try validate(version: stored.version, tabs: stored.tabs, activeTabID: stored.activeTabID)
                return stored.tabs
            } catch {
                NSLog("YUANNotch: could not read the old workspace at \(url.path): \(error)")
            }
        }

        return nil
    }

    private static func tabs(
        from defaults: UserDefaults,
        tabsKey: String,
        activeTabIDKey: String
    ) -> [NoteTab]? {
        guard let data = defaults.data(forKey: tabsKey),
              let storedTabs = try? JSONDecoder().decode([NoteTab].self, from: data),
              !storedTabs.isEmpty else {
            return nil
        }

        let storedActiveID = defaults.string(forKey: activeTabIDKey).flatMap(UUID.init(uuidString:))
        let activeID = storedActiveID.flatMap { candidate in
            storedTabs.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? storedTabs[0].id

        guard (try? validate(version: 1, tabs: storedTabs, activeTabID: activeID)) != nil else {
            return nil
        }
        return storedTabs
    }

    private enum ValidationError: Error {
        case unsupportedVersion(Int)
        case emptyWorkspace
        case duplicateTabIDs
        case invalidActiveTab
    }

    private static func validate(version: Int, tabs: [NoteTab], activeTabID: UUID) throws {
        guard version == 1 else { throw ValidationError.unsupportedVersion(version) }
        guard !tabs.isEmpty else { throw ValidationError.emptyWorkspace }
        guard Set(tabs.map(\.id)).count == tabs.count else { throw ValidationError.duplicateTabIDs }
        guard tabs.contains(where: { $0.id == activeTabID }) else { throw ValidationError.invalidActiveTab }
    }
}

import Foundation

struct NotePersistence {
    static let currentVersion = 1

    struct Workspace: Codable, Equatable {
        let version: Int
        let tabs: [NoteTab]
        let activeTabID: UUID
    }

    enum LoadResult {
        case missing
        case loaded(Workspace)
        case failed
    }

    private enum PersistenceError: LocalizedError {
        case unsupportedVersion(Int)
        case emptyWorkspace
        case duplicateTabIDs
        case invalidActiveTab

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "unsupported workspace version \(version)"
            case .emptyWorkspace:
                return "workspace contains no tabs"
            case .duplicateTabIDs:
                return "workspace contains duplicate tab IDs"
            case .invalidActiveTab:
                return "workspace active tab does not exist"
            }
        }
    }

    private let fileManager = FileManager.default
    private let workspaceURL: URL
    private let backupURL: URL

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = applicationSupport.appendingPathComponent("YUANNotch", isDirectory: true)
        workspaceURL = directory.appendingPathComponent("workspace.json")
        backupURL = directory.appendingPathComponent("workspace.json.backup")
    }

    func load() -> LoadResult {
        guard fileManager.fileExists(atPath: workspaceURL.path) else {
            return loadBackupIfPresent(or: .missing)
        }

        do {
            return .loaded(try readWorkspace(at: workspaceURL))
        } catch {
            NSLog("YUANNotch: failed to read workspace at \(workspaceURL.path): \(error)")
            return loadBackupIfPresent(or: .failed)
        }
    }

    @discardableResult
    func save(_ workspace: Workspace) -> Bool {
        do {
            try Self.validate(workspace)
            let data = try JSONEncoder().encode(workspace)
            let directory = workspaceURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: workspaceURL.path) {
                do {
                    _ = try readWorkspace(at: workspaceURL)
                } catch {
                    // Preserve the unreadable file before the first recovery write.
                    try isolateCorruptWorkspace()
                }

                if fileManager.fileExists(atPath: workspaceURL.path) {
                    try updateBackup()
                }
            }

            try data.write(to: workspaceURL, options: [.atomic])
            return true
        } catch {
            NSLog("YUANNotch: failed to save workspace at \(workspaceURL.path): \(error)")
            return false
        }
    }

    private func loadBackupIfPresent(or fallback: LoadResult) -> LoadResult {
        guard fileManager.fileExists(atPath: backupURL.path) else { return fallback }

        do {
            let workspace = try readWorkspace(at: backupURL)
            NSLog("YUANNotch: using workspace backup at \(backupURL.path)")
            return .loaded(workspace)
        } catch {
            NSLog("YUANNotch: failed to read workspace backup at \(backupURL.path): \(error)")
            return .failed
        }
    }

    private func readWorkspace(at url: URL) throws -> Workspace {
        let data = try Data(contentsOf: url)
        let workspace = try JSONDecoder().decode(Workspace.self, from: data)
        try Self.validate(workspace)
        return workspace
    }

    static func validate(_ workspace: Workspace) throws {
        guard workspace.version == Self.currentVersion else {
            throw PersistenceError.unsupportedVersion(workspace.version)
        }
        guard !workspace.tabs.isEmpty else {
            throw PersistenceError.emptyWorkspace
        }
        guard Set(workspace.tabs.map(\.id)).count == workspace.tabs.count else {
            throw PersistenceError.duplicateTabIDs
        }
        guard workspace.tabs.contains(where: { $0.id == workspace.activeTabID }) else {
            throw PersistenceError.invalidActiveTab
        }
    }

    private func isolateCorruptWorkspace() throws {
        let directory = workspaceURL.deletingLastPathComponent()
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var corruptURL = directory.appendingPathComponent("workspace.corrupt-\(timestamp).json")
        if fileManager.fileExists(atPath: corruptURL.path) {
            corruptURL = directory.appendingPathComponent(
                "workspace.corrupt-\(timestamp)-\(UUID().uuidString).json"
            )
        }

        do {
            try fileManager.moveItem(at: workspaceURL, to: corruptURL)
            NSLog("YUANNotch: isolated unreadable workspace at \(corruptURL.path)")
        } catch {
            NSLog("YUANNotch: could not isolate unreadable workspace; refusing to overwrite \(workspaceURL.path): \(error)")
            throw error
        }
    }

    private func updateBackup() throws {
        let temporaryURL = backupURL.deletingLastPathComponent()
            .appendingPathComponent(".workspace.backup-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        do {
            // Copy first, then replace/move. The old backup is never removed first.
            try fileManager.copyItem(at: workspaceURL, to: temporaryURL)
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.replaceItem(
                    at: backupURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: nil
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: backupURL)
            }
        } catch {
            NSLog("YUANNotch: failed to update workspace backup; the workspace write was not attempted: \(error)")
            throw error
        }
    }
}

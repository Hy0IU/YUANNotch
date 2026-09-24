import Foundation

final class DailyPlanPersistence {
    let fileURL: URL
    let backupFileURL: URL

    private let fileManager: FileManager
    private let legacyFileURLs: [URL]
    private var writesAreBlocked = false
    private(set) var loadErrorDescription: String?

    init(fileURL: URL = DailyPlanPersistence.defaultFileURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        backupFileURL = fileURL.appendingPathExtension("backup")
        self.fileManager = fileManager

        let defaultURL = Self.defaultFileURL(fileManager: fileManager)
        legacyFileURLs = fileURL.standardizedFileURL == defaultURL.standardizedFileURL
            ? Self.legacyFileURLs(fileManager: fileManager)
            : []
    }

    /// This location is outside the app bundle, so replacing the app in
    /// /Applications never replaces the user's daily plans.
    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return support
            .appendingPathComponent("YUANNotch", isDirectory: true)
            .appendingPathComponent("daily-plans.json", isDirectory: false)
    }

    private static func legacyFileURLs(fileManager: FileManager) -> [URL] {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return [
            support
                .appendingPathComponent("NotchNotes", isDirectory: true)
                .appendingPathComponent("daily-plans.json", isDirectory: false),
            support
                .appendingPathComponent("io.github.oiloil.NotchNotes", isDirectory: true)
                .appendingPathComponent("daily-plans.json", isDirectory: false)
        ]
    }

    func load() -> DailyPlanArchive {
        var primaryWasUnreadable = false

        for candidate in [fileURL, backupFileURL] + legacyFileURLs {
            guard fileManager.fileExists(atPath: candidate.path) else { continue }

            do {
                let archive = try decode(from: candidate)
                if candidate != fileURL {
                    do {
                        let data = try encode(archive)
                        try writeAtomically(data, to: fileURL)
                        try writeAtomically(data, to: backupFileURL)
                        loadErrorDescription = "Daily plans were recovered from a local backup."
                    } catch {
                        loadErrorDescription = "Daily plans were recovered in memory, but the recovered copy could not be restored to disk."
                    }
                } else {
                    loadErrorDescription = primaryWasUnreadable
                        ? "Daily plans were recovered after the previous file was preserved."
                        : nil
                }
                return archive
            } catch {
                guard candidate == fileURL else { continue }
                do {
                    try preserveUnreadableFile(at: candidate)
                    primaryWasUnreadable = true
                } catch {
                    writesAreBlocked = true
                    loadErrorDescription = "The plans file could not be read or moved aside. It will not be overwritten."
                    return DailyPlanArchive()
                }
            }
        }

        if primaryWasUnreadable {
            loadErrorDescription = "The previous plans file could not be read and was preserved beside the new one."
        }
        return DailyPlanArchive()
    }

    func save(_ archive: DailyPlanArchive) throws {
        guard !writesAreBlocked else { throw DailyPlanPersistenceError.writesBlocked }

        let data = try encode(archive)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Keep the last known-good archive beside the live file before
        // replacing it. Both files are outside the app bundle.
        if fileManager.fileExists(atPath: fileURL.path) {
            let previousData = try Data(contentsOf: fileURL)
            _ = try decode(from: previousData)
            try writeAtomically(previousData, to: backupFileURL)
        }

        try writeAtomically(data, to: fileURL)
        // The newest archive is also the recovery point if the live file is
        // removed or becomes unavailable while the app is being replaced.
        try writeAtomically(data, to: backupFileURL)
    }

    private func encode(_ archive: DailyPlanArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    private func decode(from url: URL) throws -> DailyPlanArchive {
        try decode(from: Data(contentsOf: url))
    }

    private func decode(from data: Data) throws -> DailyPlanArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(DailyPlanArchive.self, from: data)
        guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return archive
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func preserveUnreadableFile(at url: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let uniqueSuffix = UUID().uuidString.prefix(8)
        let preserved = url
            .deletingPathExtension()
            .appendingPathExtension("unreadable-\(stamp)-\(uniqueSuffix).json")
        try fileManager.moveItem(at: url, to: preserved)
    }
}

private enum DailyPlanPersistenceError: LocalizedError {
    case writesBlocked

    var errorDescription: String? {
        "The unreadable plans file could not be preserved, so YUANNotch will not overwrite it."
    }
}

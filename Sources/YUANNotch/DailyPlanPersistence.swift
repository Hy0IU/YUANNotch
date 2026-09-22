import Foundation

final class DailyPlanPersistence {
    let fileURL: URL
    private let fileManager: FileManager
    private var writesAreBlocked = false
    private(set) var loadErrorDescription: String?

    init(fileURL: URL = DailyPlanPersistence.defaultFileURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return support
            .appendingPathComponent("YUANNotch", isDirectory: true)
            .appendingPathComponent("daily-plans.json", isDirectory: false)
    }

    func load() -> DailyPlanArchive {
        guard fileManager.fileExists(atPath: fileURL.path) else { return DailyPlanArchive() }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(DailyPlanArchive.self, from: data)
            guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            loadErrorDescription = nil
            return archive
        } catch {
            do {
                try preserveUnreadableFile()
                loadErrorDescription = "The previous plans file could not be read and was preserved beside the new one."
            } catch {
                writesAreBlocked = true
                loadErrorDescription = "The plans file could not be read or moved aside. It will not be overwritten."
            }
            return DailyPlanArchive()
        }
    }

    func save(_ archive: DailyPlanArchive) throws {
        guard !writesAreBlocked else { throw DailyPlanPersistenceError.writesBlocked }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)
        try data.write(to: fileURL, options: .atomic)
    }

    private func preserveUnreadableFile() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let uniqueSuffix = UUID().uuidString.prefix(8)
        let preserved = fileURL
            .deletingPathExtension()
            .appendingPathExtension("unreadable-\(stamp)-\(uniqueSuffix).json")
        try fileManager.moveItem(at: fileURL, to: preserved)
    }
}

private enum DailyPlanPersistenceError: LocalizedError {
    case writesBlocked

    var errorDescription: String? {
        "The unreadable plans file could not be preserved, so YUANNotch will not overwrite it."
    }
}

import AppKit
import Foundation
import MarkdownEngine

/// Stores the images that notes embed, in an `attachments` folder beside the notes.
///
/// An image is one file named after the name it arrived with, and a note refers to
/// it as `![[attachments/<name>.png]]`. That shape is not a free choice: it is the
/// only one this editor and Obsidian can both resolve. Obsidian reads everything
/// after `|` in an image embed as a size rather than as a label, so an app-private
/// identifier cannot ride along inside the reference — which leaves the file name as
/// the image's identity and the reference as the only link between the two.
///
/// Reachable from the editor's rendering path, so everything mutable sits behind a
/// lock rather than on an actor.
final class LocalImageStore: EmbeddedImageFileProvider, @unchecked Sendable {

    /// The folder inside the notes folder that holds the images. Part of every
    /// reference written into a note, so renaming it breaks existing notes.
    static let directoryName = "attachments"
    static let manifestFilename = "manifest.json"
    static let fileExtension = "png"
    /// Used when a paste arrives without a usable name, which is the ordinary case
    /// for a copied bitmap.
    static let fallbackDisplayName = "pasted-image"
    /// APFS allows 255 UTF-8 bytes per name; sixty characters cannot reach that even
    /// at three bytes each, and they leave room for the ` 2` a collision adds.
    static let maximumDisplayNameLength = 60

    private struct ImageAssetRecord: Codable {
        /// The file name on disk, which is also what a reference names.
        var storedFilename: String
        /// Kept only so the context menu can offer the file the image came from.
        var originalPath: String?
        var createdAt: Date
    }

    private let lock = NSLock()
    /// The notes folder, held rather than derived: the images live inside it, so a
    /// folder change lands here once instead of becoming a second reader of the same
    /// setting.
    private var notesDirectoryURL: URL
    private var records: [String: ImageAssetRecord]
    /// Bumped by anything that changes what a reference resolves to, so the engine's
    /// image cache drops what it is holding.
    private var version = 0

    init(notesDirectoryURL: URL) {
        self.notesDirectoryURL = notesDirectoryURL
        records = Self.loadRecords(from: Self.manifestURL(in: notesDirectoryURL))
        try? FileManager.default.createDirectory(
            at: Self.imagesDirectory(in: notesDirectoryURL),
            withIntermediateDirectories: true
        )
    }

    /// Points the store at another notes folder. Its images come with the folder.
    func moveTo(notesDirectoryURL url: URL) {
        lock.lock()
        notesDirectoryURL = url
        records = Self.loadRecords(from: Self.manifestURL(in: url))
        version += 1
        lock.unlock()

        try? FileManager.default.createDirectory(
            at: Self.imagesDirectory(in: url),
            withIntermediateDirectories: true
        )
    }

    // MARK: - Writing

    /// Files a pasted image and returns the reference to put in the note, or `nil`
    /// when the pasteboard held no image.
    func saveImage(from pasteboard: NSPasteboard) -> String? {
        if let fileURL = PasteboardImageReader.imageFileURL(from: pasteboard),
           let data = try? Data(contentsOf: fileURL),
           NSImage(data: data) != nil {
            return save(
                data: pngData(fromImageData: data) ?? data,
                originalName: fileURL.deletingPathExtension().lastPathComponent,
                originalFileURL: fileURL
            )
        }

        guard let pngData = PasteboardImageReader.imageData(from: pasteboard) else {
            return nil
        }

        return save(
            data: pngData,
            originalName: Self.fallbackDisplayName,
            originalFileURL: nil
        )
    }

    private func save(data: Data, originalName: String, originalFileURL: URL?) -> String? {
        // A file already in the folder counts as taken even when this store has never
        // heard of it: nothing the app did not write may be written over.
        var taken = Set(onDiskFilenames())
        lock.lock()
        taken.formUnion(records.keys)
        lock.unlock()

        let filename = Self.storedFilename(
            displayName: Self.sanitizedDisplayName(originalName),
            fileExtension: Self.fileExtension,
            taken: taken
        )

        do {
            try data.write(to: url(forStoredFilename: filename), options: .atomic)
        } catch {
            NSLog("YUANNotch: could not write image \(filename): \(error)")
            return nil
        }

        lock.lock()
        records[filename] = ImageAssetRecord(
            storedFilename: filename,
            originalPath: originalFileURL?.path,
            createdAt: Date()
        )
        let snapshot = records
        version += 1
        lock.unlock()
        saveRecords(snapshot)

        return Self.reference(storedFilename: filename)
    }

    // MARK: - Reading

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        guard let filename = Self.storedFilename(namedBy: reference.name) else { return nil }
        return NSImage(contentsOf: url(forStoredFilename: filename))
    }

    func storedFileURL(for reference: EmbeddedImageRequest) -> URL? {
        guard let filename = Self.storedFilename(namedBy: reference.name) else { return nil }
        let url = url(forStoredFilename: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The file the image was pasted from, when it was pasted as a file.
    func originalFileURL(for reference: EmbeddedImageRequest) -> URL? {
        guard let filename = Self.storedFilename(namedBy: reference.name) else { return nil }

        lock.lock()
        let path = records[filename]?.originalPath
        lock.unlock()

        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func fingerprint() -> AnyHashable {
        lock.lock()
        defer { lock.unlock() }
        return version
    }

    // MARK: - Naming rules
    //
    // Static and free of instance state so they can be exercised on their own: this
    // project has no test target to hang them off, so the rules that decide what
    // lands on disk — and what a note then says about it — are kept liftable.

    /// Characters a reference cannot carry, replaced rather than left to fail.
    ///
    /// Obsidian documents `# | ^ : %% [[ ]]` as characters that "may not work as a
    /// link", and `/` would turn the name into a path. A name holding one of them
    /// would produce a reference that silently resolves to nothing.
    private static let replacedCharacters: Set<Character> = ["/", "\\", ":", "#", "|", "^", "%", "[", "]"]

    /// The name an image is filed under: the name it arrived with, minus only what a
    /// file name and a reference cannot hold.
    static func sanitizedDisplayName(_ rawName: String) -> String {
        var name = String(rawName.map { replacedCharacters.contains($0) ? "-" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would hide the file from an Open panel.
        while name.hasPrefix(".") { name.removeFirst() }
        // Runs of whitespace, newlines included, become one space.
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if name.count > maximumDisplayNameLength {
            name = String(name.prefix(maximumDisplayNameLength))
                .trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? fallbackDisplayName : name
    }

    /// The file name an image gets: its display name, plus a Finder-style number when
    /// that name is already taken.
    static func storedFilename(
        displayName: String,
        fileExtension: String,
        taken: Set<String>
    ) -> String {
        let candidate = "\(displayName).\(fileExtension)"
        guard taken.contains(candidate) else { return candidate }
        for attempt in 2...Int.max {
            let numbered = "\(displayName) \(attempt).\(fileExtension)"
            if !taken.contains(numbered) { return numbered }
        }
        return candidate
    }

    /// What a note says to embed a stored image.
    ///
    /// The folder is spelled out rather than left implicit: Obsidian resolves a link
    /// from the vault root, and a bare file name would become ambiguous as soon as the
    /// vault holds any other file of the same name.
    static func reference(storedFilename: String) -> String {
        "![[\(directoryName)/\(storedFilename)]]"
    }

    /// The file name a reference names, or `nil` when it points somewhere this store
    /// does not look.
    ///
    /// Only the reference's name is consulted. Everything after `|` is a size to
    /// Obsidian, so no app-private handle travels inside a note, and the file name is
    /// the whole of an image's identity.
    static func storedFilename(namedBy referenceName: String) -> String? {
        let trimmed = referenceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = directoryName + "/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let filename = String(trimmed.dropFirst(prefix.count))
        return filename.isEmpty ? nil : filename
    }

    // MARK: - Files

    static func imagesDirectory(in notesDirectoryURL: URL) -> URL {
        notesDirectoryURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func manifestURL(in notesDirectoryURL: URL) -> URL {
        imagesDirectory(in: notesDirectoryURL).appendingPathComponent(manifestFilename)
    }

    private func currentImagesDirectory() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return Self.imagesDirectory(in: notesDirectoryURL)
    }

    private func url(forStoredFilename filename: String) -> URL {
        currentImagesDirectory().appendingPathComponent(filename)
    }

    private func onDiskFilenames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: currentImagesDirectory().path)) ?? []
    }

    private func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func loadRecords(from url: URL) -> [String: ImageAssetRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([ImageAssetRecord].self, from: data) else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: records.map { ($0.storedFilename, $0) })
    }

    private func saveRecords(_ records: [String: ImageAssetRecord]) {
        let sorted = records.values.sorted { $0.createdAt < $1.createdAt }
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        try? data.write(to: Self.manifestURL(in: currentImagesDirectory()), options: .atomic)
    }
}

import AppKit
import Combine
import Foundation

/// Owns the folder the notes live in, and the Markdown files inside it.
///
/// A page's text exists in exactly one place: its own `.md` file. The index
/// beside it carries only what a file cannot — tab order, the active tab, caret
/// positions — so losing the index costs nothing that cannot be rebuilt, while
/// losing a file costs exactly that one page and never the others.
///
/// That separation is the point of this type. The previous design kept every
/// page's text inside a single `workspace.json`, where one unreadable entry made
/// the whole notebook open blank and refuse to write — a failure domain that
/// spanned pages it had no business touching.
@MainActor
final class NotesLibrary: ObservableObject {

    // MARK: - Model

    /// What the library knows about one tab's file.
    private struct Record {
        /// File name inside the notes folder. `nil` while the page has never
        /// been written, which is the ordinary state of a page nobody has typed
        /// into: an empty page is the absence of a file, not an empty file.
        var filename: String?
        /// The page's first non-empty line as of the last write. Kept so that a
        /// file renamed or retitled outside the app can still be recognised as
        /// this page's file rather than reported as missing.
        var title: String
        /// The exact text last handed to disk, so an untouched page is not
        /// rewritten on every tick of the editor's debounce.
        var writtenText: String?
    }

    private struct IndexEntry: Codable {
        var id: UUID
        var file: String?
        var title: String
        var createdAt: Date
        var selectionLocation: Int?
        var selectionLength: Int?
    }

    private struct Index: Codable {
        var version: Int
        var activeTabID: UUID
        var tabs: [IndexEntry]
    }

    /// One page as it came back from disk.
    private struct ResolvedPage {
        var filename: String?
        var text: String
        /// False when the file exists but could not be read. Such a page is
        /// shown empty and is never written over.
        var isWritable: Bool
    }

    struct Workspace {
        var tabs: [NoteTab]
        var activeTabID: UUID
    }

    // MARK: - Constants

    static let currentIndexVersion = 1
    static let indexFilename = "index.json"
    /// The app's own name for a page whose first line is empty or unusable.
    static let untitledName = "Untitled"
    /// UserDefaults key holding the chosen notes folder.
    static let directoryDefaultsKey = "yuanNotch.notesDirectory"
    /// Set once the notes have been brought across from the pre-file storage, so
    /// that a later empty folder is not mistaken for a fresh install.
    static let migrationFlagKey = "yuanNotch.didMigrateNotesIntoFiles"

    /// Folder used when the user has not chosen one, and the fallback when the
    /// chosen one has gone. Deliberately outside Documents: nothing here needs
    /// the user's consent, so a first launch answered with "Cancel" still stores
    /// notes without a permission prompt.
    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("YUANNotch/Notes", isDirectory: true)
    }

    // MARK: - Published state

    @Published private(set) var directoryURL: URL
    /// Markdown files in the folder that no tab points at. The app never
    /// touches or deletes these; adopting them is an explicit action.
    @Published private(set) var unclaimedMarkdownCount = 0
    /// Last failure worth telling the user about. Cleared by `dismissError()`.
    @Published private(set) var lastError: String?
    /// Fires when the notes folder itself has changed, which is the only event that
    /// replaces the pages wholesale. Carries the new folder, so everything that keeps
    /// files beside the notes — the notebook, and the images stored inside it — can
    /// follow from this one signal instead of reading the setting for itself.
    let folderChanged = PassthroughSubject<URL, Never>()

    // MARK: - Private state

    private let fileManager = FileManager.default
    private var records: [UUID: Record] = [:]
    /// Files that exist but did not read as UTF-8. Isolated only if a write is
    /// ever attempted against them.
    private var unreadableFilenames: Set<String> = []

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        createDirectoryIfNeeded()
    }

    // MARK: - Launch

    /// The folder to open with, asking the user once when none has been chosen.
    ///
    /// Called before anything reads or writes a note, so the choice cannot be
    /// interleaved with a migration writing files somewhere the user did not
    /// pick.
    static func resolveDirectoryAtLaunch() -> URL {
        let defaults = UserDefaults.standard
        let storedPath = defaults.string(forKey: directoryDefaultsKey)
        let stored = storedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }

        if let stored {
            if FileManager.default.fileExists(atPath: stored.path) {
                return stored
            }
            // The folder was moved or deleted. Ask again, starting from where it
            // used to be, rather than silently writing the notes somewhere else.
            NSLog("YUANNotch: notes folder \(stored.path) no longer exists; asking for a new one")
            if let chosen = presentDirectoryPicker(startingAt: stored.deletingLastPathComponent()) {
                defaults.set(chosen.path, forKey: directoryDefaultsKey)
                return chosen
            }
        } else if let chosen = presentDirectoryPicker(startingAt: nil) {
            defaults.set(chosen.path, forKey: directoryDefaultsKey)
            return chosen
        }

        // No choice was made. Persist the fallback so the question is asked once,
        // not on every launch; the settings page is where it gets changed.
        let fallback = defaultDirectory
        defaults.set(fallback.path, forKey: directoryDefaultsKey)
        return fallback
    }

    /// Asks for a folder. Returns `nil` if the user cancels.
    ///
    /// The activation dance is done here because this runs both at launch, when
    /// the app is a menu-bar accessory with nothing frontmost, and from the
    /// settings window, which has already activated the app. Restoring the
    /// policy only when this call changed it keeps the two callers from
    /// fighting over it.
    static func presentDirectoryPicker(startingAt directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = """
            Choose the folder YUANNotch keeps your notes in. Each page is stored \
            as its own Markdown file, and a page is named after its first line.
            """

        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            panel.directoryURL = directory
        }

        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        defer {
            if wasAccessory {
                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }
        }

        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Loading

    /// Reads the folder back into tabs.
    ///
    /// Falls back to migrating the notes the app used to keep in
    /// `workspace.json` and `UserDefaults`, and only then to a single empty page.
    func load() -> Workspace {
        // The count of unclaimed files is refreshed here and nowhere else on this
        // path: every branch below can change which files are spoken for, and a
        // branch that forgets leaves the settings page reporting yesterday's
        // folder.
        let workspace = readWorkspace()
        refreshUnclaimedMarkdownCount()
        return workspace
    }

    private func readWorkspace() -> Workspace {
        createDirectoryIfNeeded()
        records = [:]
        unreadableFilenames = []

        guard let index = readIndex() else {
            return migrateLegacyNotes()
        }

        var claimed: Set<String> = []
        var texts: [String: String] = [:]
        var tabs: [NoteTab] = []

        for entry in index.tabs {
            let page = resolve(entry, claimed: &claimed, cachedTexts: &texts)
            if let filename = page.filename {
                claimed.insert(filename)
            }
            if !page.isWritable, let filename = page.filename {
                unreadableFilenames.insert(filename)
            }

            var tab = NoteTab(id: entry.id, text: page.text, createdAt: entry.createdAt)
            tab.selectionLocation = entry.selectionLocation
            tab.selectionLength = entry.selectionLength
            records[entry.id] = Record(
                filename: page.filename,
                title: entry.title,
                writtenText: page.filename == nil ? nil : page.text
            )
            tabs.append(tab)
        }

        if tabs.isEmpty {
            return freshWorkspace()
        }

        let activeID = tabs.contains(where: { $0.id == index.activeTabID })
            ? index.activeTabID
            : tabs[0].id
        return Workspace(tabs: tabs, activeTabID: activeID)
    }

    /// Where the page's file is, and what is in it.
    ///
    /// The index's file name is tried first. When that file is gone, a file whose
    /// first line matches the title the index recorded is adopted instead — that
    /// is what keeps a page whose file the user retitled by hand from turning
    /// into a blank one.
    private func resolve(
        _ entry: IndexEntry,
        claimed: inout Set<String>,
        cachedTexts: inout [String: String]
    ) -> ResolvedPage {
        if let name = entry.file, !claimed.contains(name), isFile(at: url(for: name)) {
            let text = textContents(ofFilenamed: name, cachedTexts: &cachedTexts)
            guard let text else {
                NSLog("YUANNotch: note file \(name) is not readable UTF-8; leaving it untouched")
                return ResolvedPage(filename: name, text: "", isWritable: false)
            }
            return ResolvedPage(filename: name, text: text, isWritable: true)
        }

        let wanted = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty {
            for name in markdownFilenames() where !claimed.contains(name) {
                guard let text = textContents(ofFilenamed: name, cachedTexts: &cachedTexts),
                      Self.title(from: text) == wanted else { continue }
                NSLog("YUANNotch: relinked note \(entry.id.uuidString) to \(name)")
                return ResolvedPage(filename: name, text: text, isWritable: true)
            }
        }

        if entry.file != nil {
            NSLog("YUANNotch: note file for \(entry.id.uuidString) is missing; the page opens empty")
        }
        return ResolvedPage(filename: nil, text: "", isWritable: true)
    }

    private func readIndex() -> Index? {
        let url = url(for: Self.indexFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }

        guard let index = try? JSONDecoder().decode(Index.self, from: data),
              index.version == Self.currentIndexVersion,
              !index.tabs.isEmpty,
              Set(index.tabs.map(\.id)).count == index.tabs.count else {
            // The index is metadata, and every file it named is still sitting in
            // the folder untouched. Starting a fresh index therefore loses tab
            // order and caret positions, never a word of any note.
            NSLog("YUANNotch: \(url.path) is not a usable index; starting a new one over the files already on disk")
            return nil
        }

        return index
    }

    // MARK: - Saving

    /// Brings the folder in line with `tabs`: one file per page that has
    /// something in it, then the index.
    ///
    /// Page files are written before the index so that a crash between the two
    /// leaves files the index has not heard of — recoverable — rather than index
    /// entries pointing at files that were never written.
    @discardableResult
    func save(tabs: [NoteTab], activeTabID: UUID) -> Bool {
        createDirectoryIfNeeded()

        var claimed: Set<String> = []
        var entries: [IndexEntry] = []
        var didFail = false

        for tab in tabs {
            let (entry, failed) = apply(tab, claimed: &claimed)
            entries.append(entry)
            didFail = didFail || failed
        }

        pruneRecords(keeping: Set(tabs.map(\.id)))

        let index = Index(
            version: Self.currentIndexVersion,
            activeTabID: activeTabID,
            tabs: entries
        )
        if !writeIndex(index) {
            didFail = true
        }

        refreshUnclaimedMarkdownCount()
        return !didFail
    }

    /// Writes one page and returns the index entry that describes what actually
    /// ended up on disk — the file name is read back off the operations rather
    /// than off the intent, so a failed rename cannot leave the index lying.
    private func apply(_ tab: NoteTab, claimed: inout Set<String>) -> (IndexEntry, Bool) {
        var record = records[tab.id] ?? Record(filename: nil, title: "", writtenText: nil)
        let title = Self.title(from: tab.text)
        var didFail = false

        // A page whose title is gone keeps the file it has: wiping the first line
        // should not rename the note to "Untitled".
        if !title.isEmpty {
            record.filename = adopt(Self.filename(forTitle: title), replacing: record.filename, claimed: &claimed)
        }

        if let filename = record.filename {
            claimed.insert(filename)
            if record.writtenText != tab.text {
                do {
                    try write(tab.text, toFilenamed: filename)
                    record.writtenText = tab.text
                } catch {
                    didFail = true
                    report("Could not write “\(filename)”: \(error.localizedDescription)")
                }
            }
        }

        record.title = title
        records[tab.id] = record

        return (
            IndexEntry(
                id: tab.id,
                file: record.filename,
                title: record.title,
                createdAt: tab.createdAt,
                selectionLocation: tab.selectionLocation,
                selectionLength: tab.selectionLength
            ),
            didFail
        )
    }

    /// A record for a tab that no longer exists is dropped, but its file is left
    /// where it is: the file is the user's note, and nothing here deletes one.
    private func pruneRecords(keeping ids: Set<UUID>) {
        for id in records.keys where !ids.contains(id) {
            if let filename = records[id]?.filename {
                NSLog("YUANNotch: \(filename) is no longer claimed by a page; it stays in the folder")
            }
            records[id] = nil
        }
    }

    private func writeIndex(_ index: Index) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(index)
            try data.write(to: url(for: Self.indexFilename), options: .atomic)
            return true
        } catch {
            report("Could not write \(Self.indexFilename): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Removing

    /// Moves a page's file to the Trash, so a deleted page is recoverable from
    /// the Finder in the ordinary way. The file name may be changed by the
    /// system on the way in, which is why nothing here assumes otherwise.
    func trashFile(forTab id: UUID) {
        guard let filename = records[id]?.filename else {
            records[id] = nil
            return
        }

        let fileURL = url(for: filename)
        if isFile(at: fileURL) {
            do {
                try fileManager.trashItem(at: fileURL, resultingItemURL: nil)
            } catch {
                // The file is still where it was. The page is forgotten either
                // way; what is left behind simply becomes a file the notebook
                // does not claim, which the settings page offers to import.
                report("Could not move “\(filename)” to the Trash: \(error.localizedDescription)")
                records[id] = nil
                refreshUnclaimedMarkdownCount()
                return
            }
        }

        records[id] = nil
        unreadableFilenames.remove(filename)
        refreshUnclaimedMarkdownCount()
    }

    // MARK: - Folder

    /// Switches to another folder, leaving the current one exactly as it is.
    func setDirectory(_ url: URL) {
        directoryURL = url
        UserDefaults.standard.set(url.path, forKey: Self.directoryDefaultsKey)
        createDirectoryIfNeeded()
        folderChanged.send(url)
    }

    /// Copies the notebook into `destination` and switches to it. The originals stay
    /// where they are.
    ///
    /// A copy rather than a move: the current folder is what the user has been
    /// trusting all along, and a half-finished move would scatter the notes across
    /// two folders with no way to tell which half went where.
    ///
    /// The files keep their names, so an index that names them stays true. That only
    /// holds if the destination is free of them, so a clash is refused outright
    /// instead of resolved with a numbered name the index would not know about.
    ///
    /// Only the notebook's own files travel. Markdown in the folder that no page
    /// claims is not the notebook's to decide about, so it stays behind — visible in
    /// the folder it was found in, and still there to import if it was wanted. The
    /// images do travel, because they are inside the folder and every reference to
    /// them is written relative to it.
    func copyNotes(to destination: URL) {
        createDirectoryIfNeeded()

        let filenames = records.values.compactMap(\.filename).filter { isFile(at: url(for: $0)) }
        let existing = Set((try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? [])
        if let clash = filenames.first(where: { existing.contains($0) }) {
            report("“\(clash)” already exists in the folder you chose. Pick an empty folder so the notes keep their names.")
            return
        }

        let imagesSource = LocalImageStore.imagesDirectory(in: directoryURL)
        let imagesDestination = LocalImageStore.imagesDirectory(in: destination)
        let existingImages = (try? fileManager.contentsOfDirectory(atPath: imagesDestination.path)) ?? []
        if !existingImages.isEmpty {
            report(
                """
                The folder you chose already has \(existingImages.count) item(s) in its \
                \(LocalImageStore.directoryName) folder. Pick an empty folder so every note \
                still finds its images.
                """
            )
            return
        }

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for filename in filenames {
                try fileManager.copyItem(at: url(for: filename), to: destination.appendingPathComponent(filename))
            }
            if fileManager.fileExists(atPath: imagesSource.path) {
                try fileManager.copyItem(at: imagesSource, to: imagesDestination)
            }
            // Last, so that a copy interrupted part-way never looks complete.
            let indexURL = url(for: Self.indexFilename)
            if isFile(at: indexURL) {
                try fileManager.copyItem(at: indexURL, to: destination.appendingPathComponent(Self.indexFilename))
            }
        } catch {
            report("Could not copy the notes to “\(destination.lastPathComponent)”: \(error.localizedDescription)")
            return
        }

        NSLog("YUANNotch: copied \(filenames.count) note file(s) to \(destination.path)")
        setDirectory(destination)
    }

    func revealDirectoryInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    // MARK: - Adopting loose files

    /// Turns Markdown files in the folder that no page claims into pages, and
    /// hands them back for the notebook to place.
    ///
    /// This is the way back from a lost or unreadable index, and it is
    /// deliberately an action the user takes rather than something that happens on
    /// launch: a folder can be picked that already holds Markdown the app was
    /// never meant to manage, and only the person looking at the list can tell the
    /// difference.
    func adoptUnclaimedMarkdown() -> [NoteTab] {
        let claimed = Set(records.values.compactMap(\.filename))
        let loose = markdownFilenames().filter { !claimed.contains($0) }
        guard !loose.isEmpty else {
            refreshUnclaimedMarkdownCount()
            return []
        }

        var adopted: [NoteTab] = []
        var cache: [String: String] = [:]
        for filename in filesSortedByCreation(loose) {
            guard let text = textContents(ofFilenamed: filename, cachedTexts: &cache) else {
                NSLog("YUANNotch: leaving \(filename) alone: it does not read as UTF-8")
                continue
            }

            let tab = NoteTab(text: text)
            // The file is already on disk under this name and already holds this
            // text, so recording both means the adopt cannot turn into a rewrite.
            records[tab.id] = Record(
                filename: filename,
                title: Self.title(from: text),
                writtenText: text
            )
            adopted.append(tab)
        }

        refreshUnclaimedMarkdownCount()
        return adopted
    }

    func refreshUnclaimedMarkdownCount() {
        let claimed = Set(records.values.compactMap(\.filename))
        unclaimedMarkdownCount = markdownFilenames().filter { !claimed.contains($0) }.count
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Migration

    /// The notes this app kept before each page had a file of its own: an
    /// unreadable single-document `workspace.json` first, then the `UserDefaults`
    /// blob, then the `NotchNotes` era's keys. The originals are left in place —
    /// migration is complete only once the files and the index are on disk, and
    /// until then they are the only copy.
    ///
    /// Asked once, not once per empty folder. Otherwise pointing the app at a
    /// fresh folder — which is what changing the notes location does — would drag
    /// the old notes back in as if the folder had been the source all along.
    private func migrateLegacyNotes() -> Workspace {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migrationFlagKey) else {
            return freshWorkspace()
        }

        let tabs = LegacyNotesSource.loadTabs()
        guard !tabs.isEmpty else {
            // Nothing old to bring across: the question is settled for good.
            defaults.set(true, forKey: Self.migrationFlagKey)
            return freshWorkspace()
        }

        NSLog("YUANNotch: migrating \(tabs.count) note(s) into \(directoryURL.path)")
        for tab in tabs {
            records[tab.id] = Record(
                filename: nil,
                title: Self.title(from: tab.text),
                writtenText: nil
            )
        }

        // A file already in the folder is not adopted: a page that shares its
        // title takes a numbered name instead. Nothing the app never wrote can be
        // overwritten by a note arriving from the old storage, and those files stay
        // where they are, unclaimed, for the folder's owner to import deliberately.
        if save(tabs: tabs, activeTabID: tabs[0].id) {
            defaults.set(true, forKey: Self.migrationFlagKey)
        } else {
            NSLog("YUANNotch: note migration did not finish; it will be retried while no index is present")
        }
        refreshUnclaimedMarkdownCount()
        return Workspace(tabs: tabs, activeTabID: tabs[0].id)
    }

    /// A notebook with nothing in it and nobody's old notes in it either.
    private func freshWorkspace() -> Workspace {
        let tab = NoteTab()
        records[tab.id] = Record(filename: nil, title: "", writtenText: nil)
        return Workspace(tabs: [tab], activeTabID: tab.id)
    }

    // MARK: - Naming rules
    //
    // Static and free of instance state so they can be exercised on their own:
    // this project has no test target to hang them off, so the rules that decide
    // where a user's text lands on disk are kept liftable.

    /// The page's title: its first line that has something on it.
    ///
    /// A leading heading marker is dropped, because it is syntax rather than
    /// something the user would call the note's name; everything after it is
    /// kept exactly as typed, including list and quote markers.
    static func title(from text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            return strippingHeadingMarker(from: candidate)
        }
        return ""
    }

    private static func strippingHeadingMarker(from line: String) -> String {
        guard line.hasPrefix("#") else { return line }
        var rest = Substring(line)
        while rest.first == "#" { rest.removeFirst() }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// The file name a page with this title gets.
    static func filename(forTitle title: String) -> String {
        var name = title
            // A name cannot hold "/", and Finder renders ":" as "/".
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\t", with: " ")
        // A leading dot would make the file invisible to an Open panel.
        while name.hasPrefix(".") { name.removeFirst() }
        // Runs of spaces in an indented first line would otherwise survive into
        // the file name, where they are invisible and annoying.
        name = name.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).joined(separator: " ")
        // APFS caps a name at 255 UTF-8 bytes; 80 characters cannot reach that
        // even at three bytes per character.
        if name.count > 80 {
            name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? untitledName : name
    }

    /// A file name that is not on disk. `base` is tried first; numbered variants
    /// follow, the way Finder resolves a duplicate.
    static func availableName(base: String, taken: Set<String>) -> String {
        let candidate = "\(base).md"
        guard taken.contains(candidate) else { return candidate }
        for attempt in 2...Int.max {
            let numbered = numbered(candidate, attempt: attempt)
            if !taken.contains(numbered) { return numbered }
        }
        return candidate
    }

    /// "Note.md" at attempt 3 becomes "Note 3.md".
    private static func numbered(_ filename: String, attempt: Int) -> String {
        let base = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
        return "\(base) \(attempt).md"
    }

    // MARK: - Files

    /// The name this page should end up under, renaming its existing file when the
    /// title has moved on. Returns a bare name, never a path.
    ///
    /// Everything already in the folder counts as taken, not only the names the
    /// index remembers: a file the user dropped in by hand must not be written
    /// over just because the notebook had never heard of it.
    ///
    /// This page's own file is excluded from what counts as taken, and a name that
    /// resolves back to it is left alone. Without those two rules each save
    /// re-numbers a page that merely shares its title with another one, so a caret
    /// move could rename a note.
    private func adopt(_ desired: String, replacing current: String?, claimed: inout Set<String>) -> String {
        let target = "\(desired).md"
        if current == target { return target }

        var taken = claimed.union(markdownFilenames())
        if let current { taken.remove(current) }
        let resolved = Self.availableName(base: desired, taken: taken)

        guard let current, resolved != current, isFile(at: url(for: current)) else {
            return resolved
        }

        do {
            try fileManager.moveItem(at: url(for: current), to: url(for: resolved))
            unreadableFilenames.remove(current)
            return resolved
        } catch {
            report("Could not rename “\(current)” to “\(resolved)”: \(error.localizedDescription)")
            return current
        }
    }

    private func write(_ text: String, toFilenamed filename: String) throws {
        if unreadableFilenames.contains(filename) {
            try isolateUnreadable(filename)
        }
        try Data(text.utf8).write(to: url(for: filename), options: .atomic)
    }

    /// Moves a file the app could not read out of the way before writing a new
    /// one under its name. Keeping the bytes under a visible name means a file the
    /// app choked on is still there for a person to open.
    private func isolateUnreadable(_ filename: String) throws {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let base = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
        var target = "\(base).unreadable-\(timestamp).md"
        var attempt = 2
        while isFile(at: url(for: target)) {
            target = "\(base).unreadable-\(timestamp)-\(attempt).md"
            attempt += 1
        }

        try fileManager.moveItem(at: url(for: filename), to: url(for: target))
        unreadableFilenames.remove(filename)
        NSLog("YUANNotch: moved unreadable note file to \(target)")
    }

    private func textContents(ofFilenamed filename: String, cachedTexts: inout [String: String]) -> String? {
        if let cached = cachedTexts[filename] { return cached }
        guard let data = try? Data(contentsOf: url(for: filename)) else { return nil }
        let text = String(data: data, encoding: .utf8)
        cachedTexts[filename] = text
        return text
    }

    private func markdownFilenames() -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return contents.filter { $0.lowercased().hasSuffix(".md") }
    }

    private func filesSortedByCreation(_ filenames: [String]) -> [String] {
        filenames.sorted { lhs, rhs in
            let left = creationDate(ofFilenamed: lhs) ?? .distantPast
            let right = creationDate(ofFilenamed: rhs) ?? .distantPast
            if left == right { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
            return left < right
        }
    }

    private func creationDate(ofFilenamed filename: String) -> Date? {
        let attributes = try? fileManager.attributesOfItem(atPath: url(for: filename).path)
        return (attributes?[.creationDate] as? Date) ?? (attributes?[.modificationDate] as? Date)
    }

    private func isFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    private func url(for filename: String) -> URL {
        directoryURL.appendingPathComponent(filename)
    }

    private func createDirectoryIfNeeded() {
        guard !fileManager.fileExists(atPath: directoryURL.path) else { return }
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            report("Could not create \(directoryURL.path): \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        NSLog("YUANNotch: \(message)")
        lastError = message
    }
}

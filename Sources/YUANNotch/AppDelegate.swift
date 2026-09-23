import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var statusItem: NSStatusItem?
    private let updateChecker = UpdateChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyData()
        // Settled before anything reads or writes a note: the fixed default, or
        // whatever Settings was last told. Nothing is asked here — a folder picker on
        // first launch would interrupt the one thing the user opened the app to do,
        // and the question is answered better from Settings by someone who went there.
        let notesLibrary = NotesLibrary(directoryURL: NotesLibrary.directoryAtLaunch())
        // One check, two entry points: the menu item `makeAppMenu` adds, and
        // the settings window's About page. Both reach this same checker — the
        // only reason the second exists is that a menu-bar item can be hidden.
        panelController = NotchPanelController(
            notesLibrary: notesLibrary,
            onCheckForUpdates: { [weak self] in self?.updateChecker.checkManually() }
        )
        panelController?.showDocked()
        buildStatusItem()
        buildMenu()
        updateChecker.startAutomaticChecks()
    }

    /// One-time migration of notes and settings stored under the previous
    /// app identity (NotchNotes / io.github.oiloil.NotchNotes).
    ///
    /// Kept well after the rename on purpose. The old keys are frozen names —
    /// there is nothing here to maintain and nothing that grows with the app —
    /// while the cost of not having it is one-way: a first launch without this
    /// code writes a workspace of its own, and every later chance to recover the
    /// old notes and settings is gone.
    ///
    /// It can be deleted once a public release has been superseded — from then
    /// on, nobody can still be arriving from the previous app identity.
    private func migrateLegacyData() {
        let defaults = UserDefaults.standard
        let migratedFlag = "yuanNotch.didMigrateLegacyData"
        guard !defaults.bool(forKey: migratedFlag) else { return }

        let keyRenames: [(legacy: String, new: String)] = [
            ("notchNotes.text", "yuanNotch.text"),
            ("notchNotes.tabs.v1", "yuanNotch.tabs.v1"),
            ("notchNotes.activeTabID", "yuanNotch.activeTabID"),
            ("notchNotes.triggerMode", "yuanNotch.triggerMode"),
            ("notchNotes.expandedWidth", "yuanNotch.expandedWidth"),
            ("notchNotes.expandedHeight", "yuanNotch.expandedHeight"),
            ("notchNotes.fileShelf.v1", "yuanNotch.fileShelf.v1"),
        ]

        let legacyDomains = ["io.github.oiloil.NotchNotes", "NotchNotes"]
        for domain in legacyDomains {
            guard let legacyDefaults = UserDefaults(suiteName: domain) else { continue }
            for (legacyKey, newKey) in keyRenames where defaults.object(forKey: newKey) == nil {
                if let value = legacyDefaults.object(forKey: legacyKey) {
                    defaults.set(value, forKey: newKey)
                }
            }
        }

        defaults.set(true, forKey: migratedFlag)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        panelController?.flushPendingSave()
        return .terminateNow
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = AppGlyph.templateImage
        item.button?.imagePosition = .imageOnly
        // The artwork carries no description of its own, so the status item's
        // accessibility label is stated here instead of coming from a symbol.
        item.button?.setAccessibilityLabel("YUANNotch")
        item.menu = makeAppMenu()
        statusItem = item
    }

    private func buildMenu() {
        let rootItem = NSMenuItem()
        rootItem.submenu = makeAppMenu()

        let editItem = NSMenuItem()
        editItem.submenu = makeEditMenu()

        let mainMenu = NSMenu()
        mainMenu.addItem(rootItem)
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func makeAppMenu() -> NSMenu {
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        appMenu.addItem(updateItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit YUANNotch", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        return appMenu
    }

    private func makeEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: "Edit")

        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.target = nil
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = nil
        editMenu.addItem(redoItem)

        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.target = nil
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.target = nil
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.target = nil
        editMenu.addItem(pasteItem)

        editMenu.addItem(.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.target = nil
        editMenu.addItem(selectAllItem)

        return editMenu
    }

    @objc private func openSettings() {
        panelController?.openSettings()
    }

    @objc private func checkForUpdates() {
        updateChecker.checkManually()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

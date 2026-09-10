import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyData()
        panelController = NotchPanelController()
        panelController?.showDocked()
        buildStatusItem()
        buildMenu()
    }

    /// One-time migration of notes and settings stored under the previous
    /// app identity (NotchNotes / io.github.oiloil.NotchNotes).
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
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "YUANNotch")
        item.button?.imagePosition = .imageOnly
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
        let showItem = NSMenuItem(title: "Show Notes", action: #selector(showNotes), keyEquivalent: "n")
        showItem.target = self
        appMenu.addItem(showItem)

        let hideItem = NSMenuItem(title: "Hide Notes", action: #selector(hideNotes), keyEquivalent: "w")
        hideItem.target = self
        appMenu.addItem(hideItem)

        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

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

    @objc private func showNotes() {
        panelController?.expand(animated: true)
    }

    @objc private func hideNotes() {
        panelController?.collapse(animated: true)
    }

    @objc private func openSettings() {
        panelController?.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

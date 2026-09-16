import AppKit
import SwiftUI

/// Atoll-style settings: a regular titled window with a sidebar of tabs.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settingsStore: AppSettingsStore
    private let reminderStore: ReminderStore

    init(settingsStore: AppSettingsStore, reminderStore: ReminderStore) {
        self.settingsStore = settingsStore
        self.reminderStore = reminderStore

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "YUANNotch Settings"
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.minSize = NSSize(width: 580, height: 380)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: SettingsView(settingsStore: settingsStore, reminderStore: reminderStore)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        guard let window else { return }

        // Re-assert regular window semantics: the notch panels live at
        // .statusBar level, this window must not inherit that.
        window.level = .normal
        window.collectionBehavior = [.managed, .participatesInCycle]

        if window.isVisible {
            // Already open: bring it forward and focus it again.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            return
        }

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.center()

        // The app runs as a menu-bar accessory and the notch panels never
        // activate it — they are .nonactivatingPanel specifically so the
        // frontmost app stays frontmost. The settings window therefore has to
        // ask for activation itself: without it the window orders front but
        // stays inactive, which renders its controls greyed out and leaves it
        // unable to take keyboard focus (clicking it does not reliably fix
        // that under a tiling window manager either).
        // Same recipe as Atoll's SettingsWindowController.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Activation completes asynchronously, so re-key once it has — this
        // is what actually gives the window focus.
        DispatchQueue.main.async { [weak window] in
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func windowWillClose(_ notification: Notification) {
        // Hand focus back and return to menu-bar accessory mode, so the app
        // the user was working in gets the focus back instead of ours.
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        NSApp.deactivate()
    }
}

// MARK: - Tabs

private enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance
    case trigger
    case fileShelf
    case integrations
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .trigger: return "Trigger"
        case .fileShelf: return "File Shelf"
        case .integrations: return "Integrations"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintpalette"
        case .trigger: return "cursorarrow.rays"
        case .fileShelf: return "tray.full"
        case .integrations: return "checklist"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .appearance: return .purple
        case .trigger: return .blue
        case .fileShelf: return .orange
        case .integrations: return .green
        case .about: return .gray
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var reminderStore: ReminderStore
    @State private var selection: SettingsTab = .appearance

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsTab.allCases) { tab in
                    NavigationLink(value: tab) {
                        sidebarRow(for: tab)
                    }
                }
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            detailView(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 580, minHeight: 380)
    }

    @ViewBuilder
    private func sidebarRow(for tab: SettingsTab) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tab.tint, tab.tint.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 22, height: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.7)
                        .blendMode(.plusLighter)
                }
                .shadow(color: tab.tint.opacity(0.35), radius: 2, x: 0, y: 1)
                .overlay {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }

            Text(tab.title)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func detailView(for tab: SettingsTab) -> some View {
        switch tab {
        case .appearance:
            AppearanceSettingsView(settingsStore: settingsStore)
        case .trigger:
            TriggerSettingsView(settingsStore: settingsStore)
        case .fileShelf:
            FileShelfSettingsView(settingsStore: settingsStore)
        case .integrations:
            IntegrationsSettingsView(settingsStore: settingsStore, reminderStore: reminderStore)
        case .about:
            AboutSettingsView()
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore

    var body: some View {
        Form {
            Section {
                CornerRadiusSlider(
                    title: "Top corners:",
                    value: $settingsStore.expandedTopCornerRadius,
                    range: 0...24
                )
                CornerRadiusSlider(
                    title: "Bottom corners:",
                    value: $settingsStore.expandedBottomCornerRadius,
                    range: 0...32
                )
            } header: {
                Text("Corner Radius")
            } footer: {
                Text("Corner radius of the expanded panel. Applies immediately.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CornerRadiusSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: 1)
                    .frame(maxWidth: 220)
                Text("\(Int(value)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

// MARK: - Trigger

private struct TriggerSettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Open panel:", selection: $settingsStore.triggerMode) {
                    ForEach(TriggerMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text("Hover: moving the cursor to the top edge opens the panel. Click: click the notch area to open it.")
            }

            Section {
                HStack(spacing: 10) {
                    Text("Hover delay:")
                        .fixedSize()

                    Spacer(minLength: 16)

                    Slider(
                        value: hoverDelayBinding,
                        in: AppSettingsStore.hoverActivationDelayRange,
                        step: 0.2
                    )
                    .frame(width: 110)

                    TextField(
                        "",
                        value: hoverDelayBinding,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 58)
                    .accessibilityLabel("Hover delay in seconds")

                    Text("s")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .disabled(settingsStore.triggerMode != .hover)
            } footer: {
                Text("How long the pointer must remain over the notch before the panel opens. Set to 0 for an immediate response.")
            }
        }
        .formStyle(.grouped)
    }

    private var hoverDelayBinding: Binding<Double> {
        Binding(
            get: { settingsStore.hoverActivationDelay },
            set: { value in
                settingsStore.hoverActivationDelay = min(
                    max(value, AppSettingsStore.hoverActivationDelayRange.lowerBound),
                    AppSettingsStore.hoverActivationDelayRange.upperBound
                )
            }
        )
    }
}

// MARK: - File Shelf

private struct FileShelfSettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Enable file shelf", isOn: $settingsStore.isFileShelfEnabled)
            } footer: {
                Text("Drop files onto the notch or the open panel to stage them, then drag them out into other apps. Staged files stay in place on disk.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Integrations

private struct IntegrationsSettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var reminderStore: ReminderStore

    var body: some View {
        Form {
            Section {
                Toggle("Sync reminders with Apple Reminders", isOn: enableBinding)
                    .disabled(reminderStore.isBusy)
            } header: {
                Text("Apple Reminders")
            } footer: {
                Text(
                    """
                    Reminders created in YUANNotch are written to your Mac's Reminders \
                    database. Because that list is an iCloud list, Apple syncs it to your \
                    iPhone, iPad and Apple Watch — this app runs no sync of its own.
                    """
                )
            }

            if reminderStore.isEnabled {
                accessSection

                if reminderStore.authorization.canRead {
                    listSection
                }

                if let error = reminderStore.lastError {
                    Section {
                        LabeledContent("Last error:") {
                            HStack(spacing: 10) {
                                Text(error)
                                    .foregroundStyle(.secondary)
                                Button("Dismiss") { reminderStore.dismissError() }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { reminderStore.requestRefresh(reloadLists: true) }
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { reminderStore.isEnabled },
            set: { isEnabled in
                Task { await reminderStore.setEnabled(isEnabled) }
            }
        )
    }

    @ViewBuilder
    private var accessSection: some View {
        Section {
            LabeledContent("Access:") {
                HStack(spacing: 10) {
                    Text(authorizationDescription)
                        .foregroundStyle(.secondary)

                    if !reminderStore.authorization.canRead {
                        Button(reminderStore.authorization == .notDetermined ? "Request Access" : "Open System Settings") {
                            if reminderStore.authorization == .notDetermined {
                                Task { await reminderStore.requestAccess() }
                            } else {
                                reminderStore.openPrivacySettings()
                            }
                        }
                        .disabled(reminderStore.isBusy)
                    }
                }
            }
        } footer: {
            Text(authorizationFooter)
        }
    }

    @ViewBuilder
    private var listSection: some View {
        Section {
            if reminderStore.lists.isEmpty {
                Text("No writable reminder list was found. Create one in Reminders first.")
                    .foregroundStyle(.secondary)
            } else {
                // Read-only by design: the reminders panel is the one place the
                // list is switched, so there is no second control to disagree
                // with it. `settingsStore.remindersCalendarIdentifier` stays the
                // single source of truth for both.
                LabeledContent("List:") {
                    Text(listDescription)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Open:") {
                    HStack(spacing: 10) {
                        Button("Reminders") { reminderStore.openRemindersApp() }
                    }
                }
            }
        } header: {
            Text("List")
        } footer: {
            Text(listFooter)
        }
    }

    private var listDescription: String {
        guard let list = reminderStore.selectedList else { return "None" }
        return listLabel(list)
    }

    private func listLabel(_ list: ReminderList) -> String {
        var parts = [list.title]
        if list.isLocalOnly {
            parts.append("this Mac only")
        } else if !list.sourceTitle.isEmpty {
            parts.append(list.sourceTitle)
        }
        if list.isDefault {
            parts.append("default")
        }
        return parts.joined(separator: " · ")
    }

    private var authorizationDescription: String {
        switch reminderStore.authorization {
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .writeOnly: return "Write only — reading is required"
        case .fullAccess: return "Granted"
        }
    }

    private var authorizationFooter: String {
        switch reminderStore.authorization {
        case .notDetermined:
            return "macOS asks once per app. The dialog only appears while the app is in the foreground — if it does not show up, activate the app and try again."
        case .denied:
            return "Enable access under System Settings → Privacy & Security → Reminders."
        case .writeOnly:
            return "This app needs read access to list your reminders, not just write access."
        case .fullAccess:
            return "Reminders are read and written directly on this Mac."
        }
    }

    private var listFooter: String {
        if reminderStore.selectedListIsLocalOnly {
            return "This list exists only on this Mac. Reminders written to it will not appear on your iPhone, iPad or Apple Watch. Pick an iCloud list in the reminders panel to sync."
        }
        return "New reminders are written to this list. Switch lists from the drawer's reminders panel. Whether they have reached your other devices is decided by iCloud, and this app cannot read that state."
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1"
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)

            Text("YUANNotch")
                .font(.system(size: 22, weight: .bold))

            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("A native macOS note app that lives at the top edge of your screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Link("View on GitHub", destination: URL(string: "https://github.com/Hy0IU/YUANNotch")!)
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

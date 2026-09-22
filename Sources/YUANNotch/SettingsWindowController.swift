import AppKit
import SwiftUI

/// Atoll-style settings: a regular titled window with a sidebar of tabs.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settingsStore: AppSettingsStore
    private let reminderStore: ReminderStore
    private let notesLibrary: NotesLibrary
    private let noteStore: NoteStore

    init(
        settingsStore: AppSettingsStore,
        reminderStore: ReminderStore,
        notesLibrary: NotesLibrary,
        noteStore: NoteStore
    ) {
        self.settingsStore = settingsStore
        self.reminderStore = reminderStore
        self.notesLibrary = notesLibrary
        self.noteStore = noteStore

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
            rootView: SettingsView(
                settingsStore: settingsStore,
                reminderStore: reminderStore,
                notesLibrary: notesLibrary,
                noteStore: noteStore
            )
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
    case notes
    case fileShelf
    case integrations
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .trigger: return "Trigger"
        case .notes: return "Notes"
        case .fileShelf: return "File Shelf"
        case .integrations: return "Integrations"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintpalette"
        case .trigger: return "cursorarrow.rays"
        case .notes: return "doc.text"
        case .fileShelf: return "tray.full"
        case .integrations: return "checklist"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .appearance: return .purple
        case .trigger: return .blue
        case .notes: return .teal
        case .fileShelf: return .orange
        case .integrations: return .green
        case .about: return .gray
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var reminderStore: ReminderStore
    let notesLibrary: NotesLibrary
    let noteStore: NoteStore
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
        case .notes:
            NotesSettingsView(library: notesLibrary, noteStore: noteStore)
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

    /// Both radii share a range so the two sliders can be read against each
    /// other, and so the fields beside them can be held to the same limits.
    static let cornerRadiusRange: ClosedRange<Double> = 0...50

    /// One tick every this many points.
    ///
    /// The range is 50 wide, so `step: 1` would put 51 ticks on a 220pt track
    /// and read as a ruler rather than a slider. Five is the coarsest spacing
    /// that still leaves the track aimable; any value the ticks skip is still a
    /// perfectly good radius and can be typed into the field instead.
    static let cornerRadiusTickSpacing: Double = 5

    var body: some View {
        Form {
            Section {
                ValueSliderRow(
                    title: "Top corners:",
                    value: $settingsStore.expandedTopCornerRadius,
                    range: Self.cornerRadiusRange,
                    step: Self.cornerRadiusTickSpacing,
                    unit: "pt",
                    decimals: 0
                )
                ValueSliderRow(
                    title: "Bottom corners:",
                    value: $settingsStore.expandedBottomCornerRadius,
                    range: Self.cornerRadiusRange,
                    step: Self.cornerRadiusTickSpacing,
                    unit: "pt",
                    decimals: 0
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

/// A slider and a field editing the same value under the same limits.
///
/// One implementation for every numeric setting, because the behaviour that
/// matters is subtle and must not drift between surfaces: the ticks are a
/// visual rhythm rather than the set of legal values, so the field accepts a
/// number the ticks skip, and a typed value is held to the range but never
/// snapped to the step.
private struct ValueSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    /// Digits the field shows. Also the precision a typed value settles to.
    let decimals: Int
    /// The row is greyed out and inert when this is false.
    var isEnabled = true
    /// `nil` leaves the controls described by the row's `LabeledContent` title
    /// alone, rather than labelling them twice.
    var accessibilityLabel: String? = nil

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(maxWidth: 220)
                    .explicitAccessibilityLabel(accessibilityLabel)
                ValueField(
                    value: $value,
                    range: range,
                    decimals: decimals,
                    unit: unit,
                    isEnabled: isEnabled,
                    accessibilityLabel: accessibilityLabel
                )
            }
        }
        // Disabling the row rather than the two controls keeps them in step with
        // each other; the field also watches this so a half-typed number is
        // settled before it can no longer be edited.
        .disabled(!isEnabled)
    }
}

/// The editable value beside a slider.
///
/// It exists because the ticks are a visual rhythm, not the set of legal values:
/// typing the number beats dragging until it happens to land on it. The text is
/// held here and written out on submit or on losing focus, so a half-typed
/// number is never committed and a drag never overwrites what is being typed.
private struct ValueField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let decimals: Int
    let unit: String
    var isEnabled = true
    var accessibilityLabel: String? = nil

    @State private var text = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: 3) {
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 48)
                .focused($isEditing)
                .onSubmit(commit)
                .onChange(of: isEditing) { _, editing in
                    if editing {
                        // Start from the committed value rather than from
                        // whatever the field happened to be showing.
                        text = Self.format(value, decimals: decimals)
                    } else {
                        commit()
                    }
                }
                .onChange(of: value) { _, newValue in
                    // Dragging has to keep the field in step — but not while
                    // the user is midway through typing into it.
                    guard !isEditing else { return }
                    text = Self.format(newValue, decimals: decimals)
                }
                .onChange(of: isEnabled) { _, enabled in
                    // A row going disabled does not reliably end editing, and a
                    // field left mid-edit never gets corrected afterwards: the
                    // handler above stays suppressed for as long as `isEditing`
                    // is true. Settle it here instead of leaving text and value
                    // out of step until the next successful commit.
                    guard !enabled else { return }
                    isEditing = false
                    commit()
                }
                .onAppear { text = Self.format(value, decimals: decimals) }
                .explicitAccessibilityLabel(accessibilityLabel)

            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    private func commit() {
        guard let entered = Self.parse(text, to: range, decimals: decimals) else {
            // Not a number: put the field back to the committed value.
            text = Self.format(value, decimals: decimals)
            return
        }
        value = entered
        text = Self.format(value, decimals: decimals)
    }

    // MARK: - Pure rules
    //
    // Static and free of view state on purpose: these are the rules the row is
    // built on, and they can be lifted out of this file and exercised on their
    // own, which is the only way this project can check them.

    /// The field's text for a value: at most `decimals` digits, no trailing
    /// zeros, and always a dot.
    ///
    /// The locale is pinned rather than taken from the system because the other
    /// half of the pair only reads dots: on a machine set to a comma decimal
    /// separator, a localised style would print "0,30" and `parse` would then
    /// reject it, turning a commit into a silent revert.
    private static func format(_ value: Double, decimals: Int) -> String {
        // Zero negated would print as "-0"; a radius or a delay of nothing is
        // zero, not minus zero.
        let settled = value.isZero ? 0 : value
        return settled.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(0...decimals))
                .grouping(.never)
        )
    }

    /// The value a typed number means: held to the row's range, and settled to
    /// `decimals` digits so a dragged 0.30000000000000004 is stored as 0.3.
    ///
    /// Deliberately not snapped to the slider's step: a value the ticks skip is
    /// still a legal value.
    private static func clamp(
        _ value: Double,
        to range: ClosedRange<Double>,
        decimals: Int
    ) -> Double {
        let held = min(max(value, range.lowerBound), range.upperBound)
        let scale = pow(10, Double(decimals))
        let settled = (held * scale).rounded() / scale
        return settled.isZero ? 0 : settled
    }

    /// `nil` for anything that is not a plain number, so the caller can put the
    /// field back to the committed value instead of writing nonsense out.
    ///
    /// `nan` and `inf` have to be rejected explicitly: `Double(_:)` accepts both,
    /// and a non-finite value clamped afterwards would land silently on one end
    /// of the range — a delay of 0 or 2 out of a typed "nan" is worse than
    /// leaving the field as it was.
    private static func parse(
        _ text: String,
        to range: ClosedRange<Double>,
        decimals: Int
    ) -> Double? {
        guard let entered = Double(text.trimmingCharacters(in: .whitespaces)),
              entered.isFinite else { return nil }
        return clamp(entered, to: range, decimals: decimals)
    }
}

private extension View {
    /// Labels the view only when a label was given, so a control the surrounding
    /// `LabeledContent` already describes is not read out twice.
    @ViewBuilder
    func explicitAccessibilityLabel(_ label: String?) -> some View {
        if let label {
            accessibilityLabel(label)
        } else {
            self
        }
    }
}

// MARK: - Trigger

private struct TriggerSettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore

    /// One tick every 0.2s across a two-second range: eleven ticks, the same
    /// rhythm the corner-radius sliders keep on their own range.
    private static let hoverDelayTickSpacing: Double = 0.2

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
                ValueSliderRow(
                    title: "Hover delay:",
                    value: $settingsStore.hoverActivationDelay,
                    range: AppSettingsStore.hoverActivationDelayRange,
                    step: Self.hoverDelayTickSpacing,
                    unit: "s",
                    decimals: 2,
                    // The delay only means anything in hover mode; clicking the
                    // notch ignores it.
                    isEnabled: settingsStore.triggerMode == .hover,
                    accessibilityLabel: "Hover delay in seconds"
                )
            } footer: {
                Text("How long the pointer must remain over the notch before the panel opens. Set to 0 for an immediate response.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notes

private struct NotesSettingsView: View {
    @ObservedObject var library: NotesLibrary
    let noteStore: NoteStore

    /// How many files the last import took in, so the button reports something
    /// even when the folder it read from had nothing left to take.
    @State private var lastImportCount: Int?

    var body: some View {
        Form {
            locationSection
            looseFilesSection

            if let error = library.lastError {
                Section {
                    LabeledContent("Last error:") {
                        HStack(spacing: 10) {
                            Text(error)
                                .foregroundStyle(.secondary)
                            Button("Dismiss") { library.dismissError() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // The folder can gain or lose Markdown while this page is closed, so the
        // count is taken when the page appears rather than trusted from launch.
        .task { library.refreshUnclaimedMarkdownCount() }
    }

    private var locationSection: some View {
        Section {
            LabeledContent("Folder:") {
                HStack(spacing: 10) {
                    Text(library.directoryURL.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: 250, alignment: .leading)

                    Button("Show in Finder") { library.revealDirectoryInFinder() }
                    Button("Change…") { changeFolder() }
                }
            }
        } header: {
            Text("Location")
        } footer: {
            Text(
                """
                Notes start out in YUANNotch's own support folder and are only ever moved \
                from here. Each page is one Markdown file in this folder, named after the \
                page's first line. Pasted images go in the \(LocalImageStore.directoryName) \
                folder inside it, and a note refers to one as \
                ![[\(LocalImageStore.directoryName)/name.png]] — so the folder opens as an \
                ordinary notebook anywhere, images included.
                """
            )
        }
    }

    private var looseFilesSection: some View {
        Section {
            LabeledContent("Not in the notebook:") {
                HStack(spacing: 10) {
                    Text(fileCountDescription)
                        .foregroundStyle(.secondary)

                    Button("Import as Notes") {
                        lastImportCount = noteStore.adoptLooseMarkdownFiles()
                    }
                    .disabled(library.unclaimedMarkdownCount == 0)
                }
            }

            if let lastImportCount {
                Text(importResultDescription(lastImportCount))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Markdown Files Not in the Notebook")
        } footer: {
            Text(
                """
                Markdown files in the folder that no page is using. This app never changes \
                or deletes them. Importing adds a page for each one, which is how a notebook \
                is put back together if the index beside the notes is lost.
                """
            )
        }
    }

    private var fileCountDescription: String {
        let count = library.unclaimedMarkdownCount
        return count == 1 ? "1 file" : "\(count) files"
    }

    private func importResultDescription(_ count: Int) -> String {
        switch count {
        case 0: return "There was nothing left to import."
        case 1: return "Imported 1 file."
        default: return "Imported \(count) files."
        }
    }

    /// Switching folders copies the notes across by default rather than moving
    /// them, so the folder the user has been trusting is never the one at risk
    /// halfway through the operation.
    private func changeFolder() {
        guard let chosen = NotesLibrary.presentDirectoryPicker(startingAt: library.directoryURL),
              chosen.standardizedFileURL != library.directoryURL.standardizedFileURL else {
            return
        }

        if shouldCopyNotes(to: chosen) {
            noteStore.moveNotes(to: chosen)
        } else {
            library.setDirectory(chosen)
        }
        lastImportCount = nil
    }

    private func shouldCopyNotes(to url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Copy the notes into “\(url.lastPathComponent)”?"
        alert.informativeText = """
            YUANNotch can copy the files into the folder you chose. The folder you are \
            leaving keeps its own copies either way.
            """
        alert.addButton(withTitle: "Copy Notes")
        alert.addButton(withTitle: "Switch Without Copying")
        return alert.runModal() == .alertFirstButtonReturn
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
    /// The version the running bundle reports.
    ///
    /// The fallback is only reached when there is no bundle to ask — `swift run`
    /// from the build tree. It is kept equal to `Scripts/package-app.sh`'s
    /// `APP_VERSION` default, which is the source of truth the packaged app is
    /// stamped from; bump the two together.
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

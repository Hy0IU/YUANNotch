import AppKit
import SwiftUI

/// Atoll-style settings: a regular titled window with a sidebar of tabs.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settingsStore: AppSettingsStore

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore

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
        window.contentView = NSHostingView(rootView: SettingsView(settingsStore: settingsStore))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        // Like Atoll: become a regular app while settings is visible so the
        // window can actually become key and receive clicks/focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func windowWillClose(_ notification: Notification) {
        // Return to menu-bar accessory mode once settings is closed.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Tabs

private enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance
    case trigger
    case fileShelf
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .trigger: return "Trigger"
        case .fileShelf: return "File Shelf"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintpalette"
        case .trigger: return "cursorarrow.rays"
        case .fileShelf: return "tray.full"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .appearance: return .purple
        case .trigger: return .blue
        case .fileShelf: return .orange
        case .about: return .gray
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore
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

            Section {
                LabeledContent("Size:") {
                    HStack(spacing: 10) {
                        if let size = settingsStore.customExpandedSize {
                            Text("\(Int(size.width)) × \(Int(size.height))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button("Reset to Default") {
                            settingsStore.customExpandedSize = nil
                        }
                        .disabled(settingsStore.customExpandedSize == nil)
                    }
                }
            } header: {
                Text("Panel")
            } footer: {
                Text("Drag the bottom-right corner of the panel to resize it. The new size applies the next time the panel opens.")
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
        }
        .formStyle(.grouped)
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

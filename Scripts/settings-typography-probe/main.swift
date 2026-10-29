import AppKit
import SwiftUI

// The isolated source build supplies the real enum needed by AppSettingsStore.
enum ReminderSortOrder: String {
    case added
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants(of:))
}

@MainActor
private func formScrollView(in host: NSView) -> NSScrollView? {
    descendants(of: host)
        .compactMap { $0 as? NSScrollView }
        .max { lhs, rhs in
            let lhsHeight = lhs.documentView?.bounds.height ?? 0
            let rhsHeight = rhs.documentView?.bounds.height ?? 0
            return lhsHeight < rhsHeight
        }
}

@MainActor
private func scroll(_ view: NSScrollView, to endpoint: String) {
    guard let document = view.documentView else { return }
    let maxY = max(document.bounds.height - view.contentView.bounds.height, 0)
    let y: CGFloat
    if document.isFlipped {
        y = endpoint == "top" ? 0 : maxY
    } else {
        y = endpoint == "top" ? maxY : 0
    }
    view.contentView.scroll(to: NSPoint(x: 0, y: y))
    view.reflectScrolledClipView(view.contentView)
    view.window?.contentView?.layoutSubtreeIfNeeded()
    view.window?.contentView?.displayIfNeeded()
}

@MainActor
private func saveScreenshot(of host: NSView, to url: URL) throws {
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw NSError(domain: "SettingsTypographyProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate screenshot bitmap"])
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SettingsTypographyProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode screenshot"])
    }
    try png.write(to: url, options: .atomic)
}

@MainActor
private func fieldIsFullyVisible(
    value: String,
    in host: NSView,
    viewport: NSView
) -> Bool {
    let viewportInHost = viewport.convert(viewport.bounds, to: host)
    return descendants(of: host).compactMap { $0 as? NSTextField }.contains { field in
        guard field.stringValue == value else { return false }
        let frame = field.convert(field.bounds, to: host)
        return viewportInHost.contains(frame)
            && host.bounds.contains(frame)
    }
}

@MainActor
private func runProbe(outputDirectory: URL) throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    var failures = 0
    for interfaceSize in InterfaceTextSize.allCases {
        for noteSize in [15.0, 24.0] {
            let suiteName = "yuanotch.settings-typography-probe.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw NSError(domain: "SettingsTypographyProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create isolated defaults"])
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let store = AppSettingsStore(defaults: defaults)
            store.interfaceTextSize = interfaceSize
            store.noteFontSize = noteSize

            let root = AppearanceSettingsView(settingsStore: store)
                .environment(\.appTypography, store.typography)
                .font(store.typography.font(.body))
                .frame(width: 360, height: 380)
            let host = NSHostingView(rootView: AnyView(root))
            host.frame = NSRect(x: 0, y: 0, width: 360, height: 380)

            // The window is never ordered front, activated, or shown. It only
            // gives AppKit-backed SwiftUI controls a window for offscreen layout.
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.contentView = host
            window.contentView?.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()

            guard let scrollView = formScrollView(in: host), let document = scrollView.documentView else {
                print("FAIL  \(interfaceSize.title), note \(Int(noteSize)): Form scroll view was not found")
                failures += 1
                continue
            }

            print("CASE  \(interfaceSize.title), note \(Int(noteSize)): window 360×380; Form viewport \(Int(scrollView.contentView.bounds.width))×\(Int(scrollView.contentView.bounds.height)); document height \(Int(document.bounds.height))")

            for endpoint in ["top", "bottom"] {
                scroll(scrollView, to: endpoint)
                let filename = "\(interfaceSize.rawValue)-note\(Int(noteSize))-\(endpoint).png"
                let screenshot = outputDirectory.appendingPathComponent(filename)
                try saveScreenshot(of: host, to: screenshot)
                print("SCREENSHOT  \(screenshot.path)")
            }

            scroll(scrollView, to: "bottom")
            let noteFieldVisible = fieldIsFullyVisible(
                value: String(Int(noteSize)),
                in: host,
                viewport: scrollView.contentView
            )
            print("\(noteFieldVisible ? "PASS" : "FAIL")  \(interfaceSize.title), note \(Int(noteSize)): numeric note-size field is fully visible at the Form scroll endpoint")
            if !noteFieldVisible { failures += 1 }

            window.close()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    print("")
    print(failures == 0 ? "every settings typography check passed" : "\(failures) settings typography check(s) failed")
    if failures > 0 { exit(1) }
}

MainActor.assumeIsolated {
    let directory = CommandLine.arguments.dropFirst().first ?? "/tmp/yuanotch-settings-typography-probe"
    do {
        try runProbe(outputDirectory: URL(fileURLWithPath: directory, isDirectory: true))
    } catch {
        fputs("ERROR  \(error.localizedDescription)\n", stderr)
        exit(2)
    }
}

import AppKit
import SwiftUI

/// Scoped to the visible reminder panel's key window, including its field editor.
struct ReminderFontSizeKeyboard: NSViewRepresentable {
    let settingsStore: AppSettingsStore
    var isEnabled = true

    func makeCoordinator() -> Coordinator { Coordinator(settingsStore: settingsStore) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.bind(to: view, isEnabled: isEnabled)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    @MainActor
    final class Coordinator {
        private let settingsStore: AppSettingsStore
        private weak var view: NSView?
        private var monitor: Any?
        var isEnabled = false

        init(settingsStore: AppSettingsStore) {
            self.settingsStore = settingsStore
        }

        func bind(to view: NSView, isEnabled: Bool) {
            unbind()
            self.view = view
            self.isEnabled = isEnabled
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        func unbind() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            view = nil
            isEnabled = false
        }

        @discardableResult
        func handle(_ event: NSEvent) -> Bool {
            guard isEnabled, let view, !view.isHiddenOrHasHiddenAncestor,
                  let window = view.window, window.isVisible, window.isKeyWindow,
                  NSApp.keyWindow === window, event.window === window,
                  let action = ContentFontSizeShortcut.action(for: event) else { return false }
            switch action {
            case .increase: settingsStore.reminderFontSize += 1
            case .decrease: settingsStore.reminderFontSize -= 1
            case .reset: settingsStore.reminderFontSize = AppTypography.defaultReminderFontSize
            }
            return true
        }
    }
}

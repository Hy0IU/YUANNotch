import AppKit
import Foundation

// The settings store only needs this preference's persisted raw value; the
// reminders model is unrelated to this isolated typography persistence check.
enum ReminderSortOrder: String {
    case added
}

@main
struct TypographyProbe {
    @MainActor
    static func main() {
        let suiteName = "YUANNotch.TypographyProbe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let interfaceKey = "yuanNotch.typography.interfaceSize"
        let noteKey = "yuanNotch.typography.noteFontSize"

        let initial = AppSettingsStore(defaults: defaults)
        precondition(initial.interfaceTextSize == .standard && initial.noteFontSize == 15)
        initial.interfaceTextSize = .large
        initial.noteFontSize = 21
        let reloaded = AppSettingsStore(defaults: defaults)
        precondition(reloaded.interfaceTextSize == .large && reloaded.noteFontSize == 21)
        precondition(reloaded.typography.size(.body) == 15 && reloaded.typography.noteFontSize == 21)
        reloaded.noteFontSize = 12
        precondition(reloaded.interfaceTextSize == .large && reloaded.typography.size(.body) == 15)
        print("PASS independent interface and note preferences survive reload")

        for (input, expected) in [(-4.0, 12.0), (40, 24), (18.6, 19), (.nan, 15), (.infinity, 15)] {
            reloaded.noteFontSize = input
            precondition(reloaded.noteFontSize == expected)
            precondition(AppSettingsStore(defaults: defaults).noteFontSize == expected)
        }
        defaults.set("unknown-size", forKey: interfaceKey)
        defaults.set("invalid", forKey: noteKey)
        let invalid = AppSettingsStore(defaults: defaults)
        precondition(invalid.interfaceTextSize == .standard && invalid.noteFontSize == 15)
        defaults.set(29, forKey: noteKey)
        precondition(AppSettingsStore(defaults: defaults).noteFontSize == 24)
        print("PASS invalid, non-finite, fractional and out-of-range preferences normalize safely")

        for size in InterfaceTextSize.allCases {
            let typography = AppTypography(interfaceSize: size, noteFontSize: 24)
            precondition(typography.size(.body) == 13 + size.pointOffset)
            precondition(typography.size(.control) == 12 + size.pointOffset)
            precondition(typography.size(.secondary) == 11 + size.pointOffset)
            precondition(typography.size(.compact) == 10 + size.pointOffset)
            precondition(typography.noteFontSize == 24)
            precondition(typography.controlHeight() >= typography.lineHeight(.control) + 8)
            precondition(typography.nsFont(.timer).pointSize == typography.size(.timer))
        }
        print("PASS all interface sizes share coherent text and control metrics")
    }
}

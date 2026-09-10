import Combine
import Foundation

enum TriggerMode: String, CaseIterable, Identifiable {
    case hover
    case click

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover:
            return "Hover"
        case .click:
            return "Click"
        }
    }

    var systemImage: String {
        switch self {
        case .hover:
            return "cursorarrow.motionlines"
        case .click:
            return "cursorarrow.click.2"
        }
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var triggerMode: TriggerMode {
        didSet {
            UserDefaults.standard.set(triggerMode.rawValue, forKey: Self.triggerModeKey)
        }
    }

    @Published var customExpandedSize: CGSize? {
        didSet {
            if let size = customExpandedSize {
                UserDefaults.standard.set(size.width, forKey: Self.expandedWidthKey)
                UserDefaults.standard.set(size.height, forKey: Self.expandedHeightKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.expandedWidthKey)
                UserDefaults.standard.removeObject(forKey: Self.expandedHeightKey)
            }
        }
    }

    private static let triggerModeKey = "yuanNotch.triggerMode"
    private static let expandedWidthKey = "yuanNotch.expandedWidth"
    private static let expandedHeightKey = "yuanNotch.expandedHeight"

    init() {
        let rawMode = UserDefaults.standard.string(forKey: Self.triggerModeKey)
        triggerMode = rawMode.flatMap(TriggerMode.init(rawValue:)) ?? .hover

        let w = UserDefaults.standard.double(forKey: Self.expandedWidthKey)
        let h = UserDefaults.standard.double(forKey: Self.expandedHeightKey)
        customExpandedSize = (w > 0 && h > 0) ? CGSize(width: w, height: h) : nil
    }
}

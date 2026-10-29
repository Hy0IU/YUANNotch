import AppKit
import SwiftUI

enum InterfaceTextSize: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Larger"
        }
    }

    var pointOffset: CGFloat {
        switch self {
        case .compact: return -1
        case .standard: return 0
        case .large: return 2
        }
    }
}

enum AppTextStyle: Sendable {
    case sectionTitle
    case body
    case control
    case secondary
    case compact
    case timer
    case timeInput
    case windowTitle

    fileprivate var baseSize: CGFloat {
        switch self {
        case .sectionTitle, .body: return 13
        case .control: return 12
        case .secondary: return 11
        case .compact: return 10
        case .timer: return 25
        case .timeInput: return 21
        case .windowTitle: return 22
        }
    }

    fileprivate var weight: Font.Weight {
        switch self {
        case .sectionTitle: return .semibold
        case .control, .compact, .timer, .timeInput: return .medium
        case .windowTitle: return .bold
        case .body, .secondary: return .regular
        }
    }

    fileprivate var nsWeight: NSFont.Weight {
        switch self {
        case .sectionTitle: return .semibold
        case .control, .compact, .timer, .timeInput: return .medium
        case .windowTitle: return .bold
        case .body, .secondary: return .regular
        }
    }
}

/// The app's text metrics. Icons keep their own fixed sizes; note text has an
/// independent preference and never receives the interface's point offset.
struct AppTypography: Equatable, Sendable {
    static let defaultNoteFontSize: Double = 15
    static let noteFontSizeRange: ClosedRange<Double> = 12...24

    var interfaceSize: InterfaceTextSize = .standard
    var noteFontSize: CGFloat = CGFloat(defaultNoteFontSize)

    func size(_ style: AppTextStyle) -> CGFloat {
        style.baseSize + interfaceSize.pointOffset
    }

    func font(
        _ style: AppTextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> Font {
        .system(size: size(style), weight: weight ?? style.weight, design: design)
    }

    func nsFont(_ style: AppTextStyle, weight: NSFont.Weight? = nil) -> NSFont {
        .systemFont(ofSize: size(style), weight: weight ?? style.nsWeight)
    }

    func lineHeight(_ style: AppTextStyle) -> CGFloat {
        let font = nsFont(style)
        return ceil(font.ascender - font.descender + font.leading)
    }

    func controlHeight(base: CGFloat = 24) -> CGFloat {
        max(base, lineHeight(.control) + 8)
    }

    static func normalizedNoteFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultNoteFontSize }
        return min(max(value.rounded(), noteFontSizeRange.lowerBound), noteFontSizeRange.upperBound)
    }
}

private struct AppTypographyKey: EnvironmentKey {
    static let defaultValue = AppTypography()
}

extension EnvironmentValues {
    var appTypography: AppTypography {
        get { self[AppTypographyKey.self] }
        set { self[AppTypographyKey.self] = newValue }
    }
}

private struct AppTextModifier: ViewModifier {
    @Environment(\.appTypography) private var typography
    let style: AppTextStyle
    let weight: Font.Weight?
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(typography.font(style, weight: weight, design: design))
    }
}

extension View {
    func appText(
        _ style: AppTextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> some View {
        modifier(AppTextModifier(style: style, weight: weight, design: design))
    }
}

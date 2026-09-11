import AppKit
import CoreGraphics

struct NotchLayout: Equatable {
    let notchSize: NSSize
    let compactSize: NSSize
    let expandedSize: NSSize
    let compactTopOffset: CGFloat
    let expandedTopOffset: CGFloat
}

/// Size-independent metrics for the file shelf.
///
/// The shelf's height is a fraction of the drawer's height because the
/// drawer is user-resizable: a fixed pixel height would change its
/// relationship to the drawer every time the drawer is resized, and a shelf
/// derived from the animated content layout would drift while it animates
/// the editor's height.
enum ShelfMetrics {
    /// Target shelf height as a fraction of the drawer height.
    static let heightRatio: CGFloat = 0.20
    /// A chip is 54pt tall inside 6pt of vertical padding, so anything below
    /// 66pt squeezes the row; keep comfortable slack at the small end and a
    /// cap at the large end.
    static let minShelfHeight: CGFloat = 72
    static let maxShelfHeight: CGFloat = 120
    /// How far above the shelf's own row a file drag still counts as
    /// hovering the shelf: the content's bottom padding, the gap above the
    /// shelf, and a little slack. Measured from the panel's bottom edge so
    /// the shelf appearing underneath cannot move the region out from under
    /// the cursor.
    static let revealBandSlack: CGFloat = 44
    /// Smallest drawer height that fits the toolbar, the editor's minimum
    /// height and the shelf without overflowing the visible area.
    static let minimumDrawerHeight: CGFloat = 340

    static func shelfHeight(forDrawerHeight height: CGFloat) -> CGFloat {
        min(max(height * heightRatio, minShelfHeight), maxShelfHeight)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(number.uint32Value)
    }

    var uniqueID: String {
        if let displayID {
            return "display-\(displayID)"
        }
        return "screen-\(frame.origin.x)-\(frame.origin.y)"
    }

    var isBuiltInDisplay: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    var measuredNotchSize: NSSize {
        guard #available(macOS 12.0, *), safeAreaInsets.top > 0 else {
            return .zero
        }

        guard let leftArea = auxiliaryTopLeftArea, let rightArea = auxiliaryTopRightArea else {
            return .zero
        }

        let notchWidth = frame.width - leftArea.width - rightArea.width
        guard notchWidth > 0, notchWidth < frame.width else {
            return .zero
        }

        return NSSize(width: notchWidth, height: safeAreaInsets.top)
    }
}

@MainActor
enum NotchGeometry {
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: \.isBuiltInDisplay)
            ?? NSScreen.screens.first { $0.measuredNotchSize != .zero }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }


    static func layout(for screen: NSScreen?, customSize: CGSize? = nil) -> NotchLayout {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let measured = screen?.measuredNotchSize ?? .zero
        let fallbackNotch = NSSize(width: 210, height: 32)
        let notch = measured == .zero ? fallbackNotch : measured

        let compactWidth = min(max(notch.width - 6, 182), 238)
        let compactHeight = min(max(notch.height + 2, 32), 38)

        let defaultExpandedWidth = min(max(notch.width + 220, 480), 540, screenFrame.width - 36)
        let defaultExpandedHeight = min(max(notch.height + 374, 408), screenFrame.height - 84)

        let expandedWidth: CGFloat
        let expandedHeight: CGFloat
        if let custom = customSize {
            expandedWidth = min(max(custom.width, 360), screenFrame.width - 36)
            // The lower bound keeps the toolbar, the editor's minimum height
            // and the shelf inside the visible drawer: below it the shelf
            // would render clipped under the bottom edge.
            expandedHeight = min(max(custom.height, ShelfMetrics.minimumDrawerHeight), screenFrame.height - 84)
        } else {
            expandedWidth = defaultExpandedWidth
            expandedHeight = defaultExpandedHeight
        }

        return NotchLayout(
            notchSize: notch,
            compactSize: NSSize(width: compactWidth, height: compactHeight),
            expandedSize: NSSize(width: expandedWidth, height: expandedHeight),
            compactTopOffset: 0,
            expandedTopOffset: 0
        )
    }
}

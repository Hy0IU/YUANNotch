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

    static func shelfHeight(forDrawerHeight height: CGFloat) -> CGFloat {
        min(max(height * heightRatio, minShelfHeight), maxShelfHeight)
    }
}

/// Footprint and placement of the bottom-right resize grip.
///
/// It sits here with the other drawer metrics because the drawer's bottom
/// padding has to clear exactly this box. Those two numbers have to agree from
/// opposite ends — the view places the grip, `DrawerMetrics` keeps the content
/// out of its way — and while the placement lived in the view and the reserve
/// was a typed-in `18`, the grip's upper dots ended up drawn on the inner
/// panel's corner with nothing to catch it.
enum ResizeGripMetrics {
    static let size: CGFloat = 16
    /// Distance from the panel's bottom edge.
    static let bottomInset: CGFloat = 9
    /// Distance *inside* the panel's silhouette edge. `DetachablePanelShape`
    /// draws that edge inside the frame, so the view adds `panelSideInset`.
    static let silhouetteInset: CGFloat = 8
    /// Air kept between the grip's footprint and the inner panel above it.
    static let clearance: CGFloat = 8
    /// Air added around the grip's footprint inside its grab zone, so the corner
    /// can be hit without aiming at it.
    static let grabSlack: CGFloat = 10

    /// The zone whose mouse-down starts a drawer resize, in screen coordinates.
    ///
    /// The grip's own box plus `grabSlack` to its left and above, stopped at the
    /// silhouette's right edge and at the inner panel's bottom edge. Both stops
    /// are why this is derived rather than typed in: as a fixed `48 x 44`
    /// measured from a `10`pt inset, a fifth of it sat under the inner panel at
    /// the 25pt radius this drawer runs, so a click that looked like it belonged
    /// to the panel started a resize instead. Holding the top at
    /// `contentBottomInset` makes that overlap impossible at any radius, because
    /// the panel's own bottom edge is exactly what `contentBottomPadding` sets.
    static func grabRect(
        in panelFrame: NSRect,
        sideInset: CGFloat,
        contentBottomInset: CGFloat
    ) -> NSRect {
        let right = panelFrame.maxX - sideInset
        let left = right - silhouetteInset - size - grabSlack
        let height = min(bottomInset + size + grabSlack, contentBottomInset)
        return NSRect(
            x: left,
            y: panelFrame.minY,
            width: right - left,
            height: height
        )
    }
}

/// The drawer's layout metrics, and the shortest drawer they add up to.
///
/// They live here rather than in the view because `minimumHeight` has to be
/// *derived* from them. A minimum written down somewhere else drifts away from
/// the parts it is supposed to fit the first time one of the parts changes —
/// which is exactly how the old flat `340` ended up ~50pt taller than it needed
/// to be.
enum DrawerMetrics {
    /// Inset the attached drawer leaves below the compact block.
    static let attachedTopPaddingInset: CGFloat = 6
    /// The compact block's height on a screen with a real notch. Used only to
    /// bound `minimumHeight`: `NotchGeometry` clamps the block to 32...38, and
    /// this takes the common value rather than the tall end — the four points
    /// that buys are not worth raising the floor on every screen for.
    static let referenceCompactHeight: CGFloat = 34
    /// Top padding once the drawer has detached and may start at the very top.
    static let detachedTopPadding: CGFloat = 34

    /// Top padding while the drawer is still attached, on the reference screen.
    static var attachedTopPadding: CGFloat {
        referenceCompactHeight + attachedTopPaddingInset
    }

    /// How far `DetachablePanelShape` draws each side edge inside the frame.
    ///
    /// This is the shape's own `sideInset`. Named here because the things
    /// measured from the panel's *visible* edge — the content's padding, the
    /// resize grip, and the grip's grab zone — all live in different files, and
    /// each one carrying its own idea of it is how two of them ended up assuming
    /// the default radius of 10 while the drawer ran at 25.
    static func panelSideInset(
        topCornerRadius: CGFloat,
        detachmentProgress: CGFloat
    ) -> CGFloat {
        topCornerRadius * (1 - min(max(detachmentProgress, 0), 1))
    }
    static let toolbarHeight: CGFloat = 28
    static let editorSpacing: CGFloat = 12
    static let shelfSpacing: CGFloat = 8

    /// The gutter under the inner panel — the resize grip's corner.
    ///
    /// Not a taste call, and it cannot be smaller than the grip: a 16pt grip
    /// inset 9pt needs 25pt, so the old flat `18` left the grip's upper dots on
    /// the inner panel's bottom-right corner. Derived from `ResizeGripMetrics`
    /// so growing the grip grows the gutter instead of the overlap.
    static var contentBottomPadding: CGFloat {
        ResizeGripMetrics.bottomInset + ResizeGripMetrics.size + ResizeGripMetrics.clearance
    }

    /// Gap the content keeps from the panel's own silhouette edge.
    ///
    /// Not the content's inset from the drawer's frame: `DetachablePanelShape`
    /// draws its side edges inside the frame by the user's top-corner radius, so
    /// the real padding is this margin *plus* that inset. Keeping the two apart
    /// is what stops the padding from being right only at the default radius —
    /// written as one number it has to assume one.
    static let contentSideMargin: CGFloat = 16
    static let detachedContentSideMargin: CGFloat = 18
    /// Below this the editor is not worth opening.
    static let minimumEditorHeight: CGFloat = 120

    /// The shortest drawer that still fits the toolbar, a usable editor and the
    /// shelf without clipping.
    ///
    /// Built from the attached top padding: the drawer can be resized while it
    /// is still attached, so the clamp has to hold in that state.
    static var minimumHeight: CGFloat {
        attachedTopPadding
            + toolbarHeight
            + editorSpacing
            + minimumEditorHeight
            + shelfSpacing
            + ShelfMetrics.minShelfHeight
            + contentBottomPadding
    }
}

/// What the notebook toolbar can afford at the width it is given.
///
/// The pager is the only part of the row that grows with the user's data, so it
/// is the only part that has to know what the rest of the row costs. Before this
/// existed the strip had no width of its own: it was a `frame(minWidth: 20)`,
/// which made it the one item the row squeezed when it ran out of room — but its
/// dots sit in rigid 26pt slots, so a squeeze only shrank the frame and the dots
/// painted outside it, over the minus/plus buttons and the controls to their
/// right. Measured at the default 480pt drawer with eight tabs: the toolbar gets
/// 428pt, the row to the right of the pager costs 242pt, the pager's chrome
/// 72pt, which left the strip 104pt of space for 312pt of dots — they spilled
/// 104pt to each side.
///
/// The widths below are the real controls', measured rather than guessed, and
/// `stripWidth(tabCount:)` is the single figure the pager has to ask for.
struct NotebookToolbarLayout: Equatable {
    /// The width the toolbar row is given: the drawer less its side padding.
    let width: CGFloat
    let isRemindersMode: Bool

    static let iconButton: CGFloat = 28
    static let itemSpacing: CGFloat = 10
    /// The mode toggle with its two labels ("Notes" / "Reminders"), and with
    /// icons only, at the fonts `DrawerModeToggle` uses. Both figures are
    /// measured, not derived: `Scripts/toolbar-layout-probe.sh` hosts the real
    /// toggle and fails if either drifts.
    static let modeToggleLabelledWidth: CGFloat = 158
    static let modeToggleIconWidth: CGFloat = 57
    /// The pager's own chrome: minus, plus, the two gaps around the strip and
    /// the pill's horizontal padding.
    static let pagerChrome: CGFloat = 72
    /// Air the pager keeps before the controls to its right, so a full strip
    /// never crowds the mode toggle.
    static let pagerTrailingGap: CGFloat = 12
    /// Dots are drawn in fixed slots so that selecting one widens the capsule
    /// without moving its neighbours.
    static let dotSlot: CGFloat = 26
    static let dotSpacing: CGFloat = 6
    static let selectedDotWidth: CGFloat = 20
    static let unselectedDotWidth: CGFloat = 6
    /// Below this many dots the toggle's labels are not worth their 99pt.
    static let minimumDotsWithLabels = 3

    static var dotStride: CGFloat { dotSlot + dotSpacing }

    var showsClearButton: Bool { !isRemindersMode }

    /// Labels cost 99pt — three dots — so they are worth showing only where the
    /// strip still has room for a few. Written as a derivation because the old
    /// test read the *drawer's* width (`>= 430`) while the row is 52pt narrower:
    /// a drawer could keep labels the row could not pay for.
    var showsModeToggleLabels: Bool {
        guard !isRemindersMode else { return true }
        return width >= Self.widthNeededForLabels
    }

    /// Everything the toolbar puts to the right of the pager.
    static func trailingReserve(showsClearButton: Bool, showsModeToggleLabels: Bool) -> CGFloat {
        let toggle = showsModeToggleLabels ? modeToggleLabelledWidth : modeToggleIconWidth
        var reserve = itemSpacing + toggle
        if showsClearButton { reserve += itemSpacing + iconButton }
        reserve += itemSpacing + iconButton
        return reserve + pagerTrailingGap
    }

    private static var widthNeededForLabels: CGFloat {
        pagerChrome
            + trailingReserve(showsClearButton: true, showsModeToggleLabels: true)
            + CGFloat(minimumDotsWithLabels) * dotStride
    }

    /// Width of the dot row when nothing constrains it.
    static func stripContentWidth(tabCount: Int) -> CGFloat {
        guard tabCount > 0 else { return 0 }
        return CGFloat(tabCount) * dotStride - dotSpacing
    }

    /// Width the strip is allowed to occupy. The dots do not shrink to fit: what
    /// does not fit is reached by sliding the strip, so this is its viewport.
    func stripWidth(tabCount: Int) -> CGFloat {
        let budget = width
            - Self.pagerChrome
            - Self.trailingReserve(
                showsClearButton: showsClearButton,
                showsModeToggleLabels: showsModeToggleLabels
            )
        return min(Self.stripContentWidth(tabCount: tabCount), max(budget, 0))
    }

    /// The furthest the strip can slide before its last dot reaches the edge.
    func maximumScrollOffset(tabCount: Int) -> CGFloat {
        max(Self.stripContentWidth(tabCount: tabCount) - stripWidth(tabCount: tabCount), 0)
    }

    /// The smallest change to `currentOffset` that puts `tabIndex`'s slot fully
    /// inside the viewport — the rule a list uses to keep a selection visible,
    /// which moves the strip only when the selected dot would be hidden.
    func scrollOffset(keepingVisible tabIndex: Int, currentOffset: CGFloat, tabCount: Int) -> CGFloat {
        let limit = maximumScrollOffset(tabCount: tabCount)
        var offset = min(max(currentOffset, 0), limit)
        guard tabCount > 0 else { return offset }

        let viewport = stripWidth(tabCount: tabCount)
        let slotStart = CGFloat(min(max(tabIndex, 0), tabCount - 1)) * Self.dotStride
        let slotEnd = slotStart + Self.dotSlot
        if slotStart < offset { offset = slotStart }
        if slotEnd > offset + viewport { offset = slotEnd - viewport }
        return min(max(offset, 0), limit)
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
    /// Height of the compact block on a screen that has no real notch — an
    /// external display, or a Mac whose built-in screen has none.
    ///
    /// The two cases are not the same problem. A real notch is measured from the
    /// system and the panel has to hug it, so its height is whatever the screen
    /// reports and the `32...38` clamp only guards against a wild value. A
    /// stand-in has nothing to hug: it only has to hold the icon and read as a
    /// notch, so it is deliberately shorter than one.
    private static let simulatedCompactHeight: CGFloat = 28

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
        let hasRealNotch = measured != .zero
        let notch = hasRealNotch ? measured : fallbackNotch

        let compactWidth = min(max(notch.width - 6, 182), 238)
        let compactHeight = hasRealNotch
            ? min(max(notch.height + 2, 32), 38)
            : Self.simulatedCompactHeight

        let defaultExpandedWidth = min(max(notch.width + 220, 480), 540, screenFrame.width - 36)
        let defaultExpandedHeight = min(max(notch.height + 374, 408), screenFrame.height - 84)

        let expandedWidth: CGFloat
        let expandedHeight: CGFloat
        if let custom = customSize {
            expandedWidth = min(max(custom.width, 360), screenFrame.width - 36)
            // The lower bound keeps the toolbar, the editor's minimum height
            // and the shelf inside the visible drawer: below it the shelf
            // would render clipped under the bottom edge.
            expandedHeight = min(max(custom.height, DrawerMetrics.minimumHeight), screenFrame.height - 84)
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

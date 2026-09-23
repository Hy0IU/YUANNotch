import SwiftUI

@MainActor
final class DrawerState: ObservableObject {
    @Published var isExpanded = false
    @Published var revealProgress: CGFloat = 0
    @Published var detachmentProgress: CGFloat = 0
    @Published var isDetached = false
    @Published var isBeingDragged = false
    @Published var isResizing = false
    @Published var isDockingTargeted = false

    /// The geometry this display's drawer is drawn at.
    ///
    /// Held as state rather than passed to the view, because the drawer's
    /// size changes while the drawer is on screen. During a drag the hosting
    /// view's actual size drives drawing; this value is updated once when the
    /// drag ends. Publishing it avoids rebuilding the root view, which would
    /// tear down the editor's SwiftUI identity and TextKit layout.
    ///
    /// `NotchPanelController` is the only writer: it is the one place that
    /// knows both the display and the persisted size, and it owns the single
    /// derivation (`NotchGeometry.layout`).
    @Published var layout: NotchLayout

    init(layout: NotchLayout) {
        self.layout = layout
    }
}

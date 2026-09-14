import SwiftUI

@MainActor
final class DrawerState: ObservableObject {
    @Published var isExpanded = false
    @Published var revealProgress: CGFloat = 0
    @Published var detachmentProgress: CGFloat = 0
    @Published var isDetached = false
    @Published var isBeingDragged = false
    @Published var isDockingTargeted = false
}

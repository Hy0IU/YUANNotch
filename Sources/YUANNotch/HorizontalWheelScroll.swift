import AppKit
import SwiftUI

/// A horizontal strip that answers the wheel.
///
/// SwiftUI's `ScrollView` scrolls sideways only for a trackpad's two-finger
/// swipe: a mouse wheel's vertical deltas are ignored, so over a strip that is
/// meant to behave like a scrollbar they would reach the editor underneath
/// instead. The scroller here is AppKit's, with the strip's own SwiftUI content
/// inside it — clicks, hover and drawing all keep working, and the wheel gets
/// the same treatment a window's horizontal scroller does.
struct HorizontalWheelScroll<Content: View>: NSViewRepresentable {
    /// The strip's scroll position. The wheel writes it, so that the code that
    /// decides what to reveal knows where the dots currently sit; a change made
    /// from the SwiftUI side is applied to the scroller in `updateNSView`.
    @Binding var offset: CGFloat
    let contentWidth: CGFloat
    let height: CGFloat
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator(offset: $offset)
    }

    func makeNSView(context: Context) -> WheelDrivenScrollView {
        let scrollView = WheelDrivenScrollView()
        let documentView = NSHostingView(rootView: content)
        // The hosting view is sized by us, not by SwiftUI's ideal size, because
        // the strip's scrollable range is exactly the dots' own width.
        documentView.sizingOptions = []
        documentView.frame = NSRect(x: 0, y: 0, width: max(contentWidth, 1), height: height)
        scrollView.documentView = documentView

        context.coordinator.documentView = documentView
        scrollView.onScroll = { [weak coordinator = context.coordinator] newOffset in
            guard let coordinator else { return }
            guard abs(coordinator.offset.wrappedValue - newOffset) > 0.5 else { return }
            coordinator.offset.wrappedValue = newOffset
        }
        return scrollView
    }

    func updateNSView(_ scrollView: WheelDrivenScrollView, context: Context) {
        context.coordinator.offset = $offset

        if let documentView = context.coordinator.documentView {
            let size = NSSize(width: max(contentWidth, 1), height: height)
            if documentView.frame.size != size {
                documentView.frame.size = size
            }
            if let hostingView = documentView as? NSHostingView<Content> {
                hostingView.rootView = content
            }
        }

        scrollView.reveal(offset: offset)
    }

    final class Coordinator {
        var offset: Binding<CGFloat>
        weak var documentView: NSView?

        init(offset: Binding<CGFloat>) {
            self.offset = offset
        }
    }
}

/// The scroller the strip lives in: no visible bars, no vertical scrolling, and
/// a wheel that slides it sideways.
final class WheelDrivenScrollView: NSScrollView {
    /// Reports the position the wheel produced, so the SwiftUI side stays in
    /// step with the dots the user can actually see.
    var onScroll: ((CGFloat) -> Void)?

    /// One wheel notch slides one dot, which is what makes the strip read as a
    /// scrollbar rather than as a view that creeps when the wheel is turned.
    private static let notchStep = NotebookToolbarLayout.dotStride

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        scrollerStyle = .overlay
        contentView.drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WheelDrivenScrollView is created in code only")
    }

    override func scrollWheel(with event: NSEvent) {
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        // A trackpad's horizontal swipe is already horizontal: let the scroller
        // handle it natively, and report where it landed.
        guard abs(deltaY) >= abs(deltaX), deltaY != 0 else {
            super.scrollWheel(with: event)
            onScroll?(contentView.bounds.origin.x)
            return
        }

        let step = event.hasPreciseScrollingDeltas ? deltaY : deltaY * Self.notchStep
        let next = scrollingOrigin(from: contentView.bounds.origin.x, bySliding: -step)
        contentView.setBoundsOrigin(next)
        reflectScrolledClipView(contentView)
        onScroll?(next.x)
    }

    /// Moves the strip to `offset` unless it is already there, which is what
    /// stops a wheel-driven change from bouncing back through SwiftUI.
    func reveal(offset: CGFloat) {
        let current = contentView.bounds.origin.x
        guard abs(current - offset) > 0.5 else { return }

        let destination = scrollingOrigin(from: current, toAbsolute: offset)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(destination)
        }
    }

    private func scrollingOrigin(from current: CGFloat, bySliding distance: CGFloat) -> NSPoint {
        scrollingOrigin(from: current, toAbsolute: current + distance)
    }

    private func scrollingOrigin(from current: CGFloat, toAbsolute offset: CGFloat) -> NSPoint {
        guard let documentView else { return NSPoint(x: current, y: 0) }
        let limit = max(documentView.frame.width - contentView.bounds.width, 0)
        return NSPoint(x: min(max(offset, 0), limit), y: 0)
    }
}

import SwiftUI

/// Notch shape inspired by Atoll (https://github.com/Ebullioscopic/Atoll):
/// small rounded corners where the panel meets the top edge of the screen,
/// larger rounded corners at the bottom.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let topRadius = min(topCornerRadius, rect.width / 2, rect.height / 2)
        let bottomRadius = min(bottomCornerRadius, rect.width / 2 - topRadius, rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()

        return path
    }
}

/// Morphs the attached notch silhouette into a conventional rounded window.
/// Keeping one path topology makes the pull-away transition continuous rather
/// than swapping masks at the moment the panel detaches.
struct DetachablePanelShape: Shape {
    var attachedTopCornerRadius: CGFloat
    var attachedBottomCornerRadius: CGFloat
    var detachmentProgress: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get {
            .init(
                .init(attachedTopCornerRadius, attachedBottomCornerRadius),
                detachmentProgress
            )
        }
        set {
            attachedTopCornerRadius = newValue.first.first
            attachedBottomCornerRadius = newValue.first.second
            detachmentProgress = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(max(detachmentProgress, 0), 1)
        let floatingRadius = min(14, rect.width / 2, rect.height / 2)
        let attachedTopRadius = min(attachedTopCornerRadius, rect.width / 2, rect.height / 2)
        let topRadius = attachedTopRadius + (floatingRadius - attachedTopRadius) * progress
        let attachedBottomRadius = min(
            attachedBottomCornerRadius,
            rect.width / 2 - attachedTopRadius,
            rect.height / 2
        )
        let bottomRadius = attachedBottomRadius
            + (floatingRadius - attachedBottomRadius) * progress
        let sideInset = attachedTopRadius * (1 - progress)
        let topEdgeInset = topRadius * progress

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topEdgeInset, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + sideInset, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + sideInset, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + sideInset, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + sideInset + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + sideInset, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - sideInset - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - sideInset, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - sideInset, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - sideInset, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topEdgeInset, y: rect.minY),
            control: CGPoint(x: rect.maxX - sideInset, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

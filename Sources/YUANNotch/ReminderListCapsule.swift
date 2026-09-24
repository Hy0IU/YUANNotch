import AppKit
import QuartzCore
import SwiftUI

/// One local view onto a real Reminders list. Activating a capsule switches
/// views; clicking the selected capsule opens its list chooser and actions.
struct ReminderListCapsule: View {
    let list: ReminderList
    let availableLists: [ReminderList]
    let occupiedListIDs: Set<String>
    let isSelected: Bool
    let canDelete: Bool
    let onActivate: () -> Void
    let onSelect: (String) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isListChooserPresented = false

    var body: some View {
        control
        // Keep the capsule shell outside its controls so the menu cannot
        // compress the visible dimensions.
        .padding(.horizontal, 12)
        .frame(minWidth: 56)
        .frame(height: 24)
        // Draw the shell around the control itself. macOS is free to re-host a
        // menu's label, which can discard a background attached inside it.
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(isSelected ? 0.16 : (isHovered ? 0.11 : 0.075)))
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    isSelected ? .white.opacity(0.34) : .white.opacity(0.13),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .clipShape(Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .fixedSize()
        .help(isSelected
            ? "Click to choose another list or remove this view; drag to reorder"
            : "Drag to reorder; switch to this list view")
    }

    @ViewBuilder
    private var control: some View {
        Button {
            if isSelected {
                isListChooserPresented = true
            } else {
                onActivate()
            }
        }
        label: { capsuleLabel.contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .popover(isPresented: $isListChooserPresented, arrowEdge: .bottom) {
            listChooser
        }
    }

    private var listChooser: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(availableLists) { candidate in
                Button {
                    isListChooserPresented = false
                    onSelect(candidate.id)
                } label: {
                    HStack(spacing: 8) {
                        Text(menuTitle(candidate))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        if candidate.id == list.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(candidate.id != list.id && occupiedListIDs.contains(candidate.id))
            }

            Divider()

            Button(role: .destructive) {
                isListChooserPresented = false
                onDelete()
            } label: {
                Label("Remove View", systemImage: "trash")
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
        }
        .padding(8)
        .frame(minWidth: 190, maxWidth: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var capsuleLabel: some View {
        Text(list.title)
            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(.white.opacity(isSelected ? 0.92 : 0.72))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 120)
    }

    private func menuTitle(_ candidate: ReminderList) -> String {
        var parts = [candidate.title]
        if candidate.isLocalOnly {
            parts.append("this Mac only")
        } else if !candidate.sourceTitle.isEmpty {
            parts.append(candidate.sourceTitle)
        }
        return parts.joined(separator: " · ")
    }
}

/// A compact horizontal strip whose vertical mouse-wheel motion is translated
/// into horizontal movement. Unlike the individual capsules, the strip is the
/// only object that consumes wheel events.
struct ReminderListStripScroll<Content: View>: NSViewRepresentable {
    let height: CGFloat
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ReminderListStripScrollView {
        let scrollView = ReminderListStripScrollView()
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = [.intrinsicContentSize]
        scrollView.documentView = hostingView
        context.coordinator.hostingView = hostingView
        resize(hostingView, in: scrollView, preservingX: 0)
        return scrollView
    }

    func updateNSView(_ scrollView: ReminderListStripScrollView, context: Context) {
        guard let hostingView = context.coordinator.hostingView else { return }
        // Capture before changing the hosted tree. AppKit may adjust the clip
        // view as soon as the document's intrinsic width changes.
        let previousX = scrollView.contentView.bounds.origin.x
        hostingView.rootView = content
        hostingView.invalidateIntrinsicContentSize()
        resize(hostingView, in: scrollView, preservingX: previousX)
    }

    private func resize(
        _ hostingView: NSHostingView<Content>,
        in scrollView: NSScrollView,
        preservingX previousX: CGFloat
    ) {
        hostingView.layoutSubtreeIfNeeded()
        let fittingWidth = max(hostingView.fittingSize.width, 1)
        hostingView.frame = NSRect(x: 0, y: 0, width: fittingWidth, height: height)
        let maxX = max(fittingWidth - scrollView.contentView.bounds.width, 0)
        scrollView.contentView.scroll(to: NSPoint(x: min(previousX, maxX), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
    }
}

final class ReminderListStripScrollView: NSScrollView {
    private static let mouseWheelStep: CGFloat = 32

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
        fatalError("ReminderListStripScrollView is created in code only")
    }

    override func scrollWheel(with event: NSEvent) {
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        guard abs(deltaY) >= abs(deltaX), deltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }

        let distance = event.hasPreciseScrollingDeltas
            ? -deltaY
            : -deltaY * Self.mouseWheelStep
        let current = contentView.bounds.origin.x
        guard let documentView else { return }
        let limit = max(documentView.frame.width - contentView.bounds.width, 0)
        let destination = min(max(current + distance, 0), limit)
        guard abs(destination - current) > 0.5 else { return }

        if event.hasPreciseScrollingDeltas {
            contentView.setBoundsOrigin(NSPoint(x: destination, y: 0))
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().setBoundsOrigin(NSPoint(x: destination, y: 0))
            }
        }
        reflectScrolledClipView(contentView)
    }
}

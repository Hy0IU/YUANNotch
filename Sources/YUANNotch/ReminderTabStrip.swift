import AppKit
import SwiftUI

/// The strip's height, shared by the row and the wheel container so the two
/// cannot drift apart. A file constant because a generic type cannot carry a
/// static stored one.
private let reminderTabStripHeight: CGFloat = 26

/// The cylinder math, pure and static: a probe can pin these numbers down
/// without hosting any view.
enum ReminderTabCylinderMath {
    /// Shortest distance around the drum — the strip loops, so the last chip
    /// is one step from the first.
    static func circularDistance(from: Int, to: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let straight = abs(from - to)
        return min(straight, count - straight)
    }

    /// One wheel notch turns the drum one slot, wrapping in both directions.
    static func steppedIndex(current: Int, step: Int, count: Int) -> Int {
        guard count > 0 else { return current }
        return ((current + step) % count + count) % count
    }

    /// The cylindrical look: chips farther from the active one sit smaller,
    /// dimmer and tilted, as if rotated toward the back of the drum.
    static func chipScale(distance: Int) -> CGFloat {
        max(1.0 - CGFloat(distance) * 0.07, 0.78)
    }

    static func chipOpacity(distance: Int) -> Double {
        max(1.0 - Double(distance) * 0.22, 0.35)
    }

    /// Degrees around the strip's horizontal axis.
    static func chipTilt(distance: Int) -> Double {
        Double(distance) * 9
    }
}

/// The reminders panel's cylinder strip: one chip per pinned list, a "+" that
/// loads another list into the drum, and a wheel that turns it.
///
/// State discipline: which lists are pinned and which is active are persisted
/// choices, so they live in the settings store — the drawer throws this surface
/// away on every mode switch, and it must not own anything the user would
/// miss. What this view keeps is only hover, which is presentation.
struct ReminderTabStrip: View {
    @ObservedObject var store: ReminderStore
    @ObservedObject var settingsStore: AppSettingsStore

    @State private var hoveredTabIndex: Int?

    private static let chipHeight: CGFloat = 20

    private static let drumAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        HStack(spacing: 8) {
            cylinder

            addButton
        }
        .padding(.horizontal, 10)
        .frame(height: reminderTabStripHeight)
    }

    private var pinnedListIDs: [String] { settingsStore.reminderTabListIDs }

    private var cylinder: some View {
        WheelSteppedScrollView(onStep: { step in
            activate(index: ReminderTabCylinderMath.steppedIndex(
                current: settingsStore.reminderActiveTabIndex,
                step: step,
                count: pinnedListIDs.count
            ))
        }) {
            HStack(spacing: 6) {
                ForEach(Array(pinnedListIDs.enumerated()), id: \.element) { index, listID in
                    chip(index: index, listID: listID)
                }
            }
            .padding(.horizontal, 2)
            .frame(height: reminderTabStripHeight, alignment: .center)
            .animation(Self.drumAnimation, value: settingsStore.reminderActiveTabIndex)
            .animation(Self.drumAnimation, value: settingsStore.reminderTabListIDs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: reminderTabStripHeight)
    }

    private func chip(index: Int, listID: String) -> some View {
        // The highlight follows the list actually shown, not the stored index,
        // so a switch made through the list picker never lights the wrong tab.
        let isActive = listID == store.selectedList?.id
        let distance = ReminderTabCylinderMath.circularDistance(
            from: index,
            to: settingsStore.reminderActiveTabIndex,
            count: pinnedListIDs.count
        )

        return HStack(spacing: 4) {
            Button {
                activate(index: index)
            } label: {
                Text(title(for: listID))
                    .font(.system(size: 11, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Switch to this list")

            Button {
                settingsStore.removeReminderTab(at: index)
                // If the removed tab was the active one, the clamped index now
                // names its successor — follow the selection there.
                syncSelection()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 6, weight: .semibold))
                    .frame(width: 12, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(hoveredTabIndex == index ? 0.6 : 0))
            .help("Remove this tab")
        }
        .padding(.trailing, 5)
        .frame(height: Self.chipHeight)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(isActive ? 0.16 : 0.05))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(isActive ? 0.35 : 0), lineWidth: 1)
        )
        .scaleEffect(ReminderTabCylinderMath.chipScale(distance: distance))
        .opacity(ReminderTabCylinderMath.chipOpacity(distance: distance))
        .rotation3DEffect(
            .degrees(ReminderTabCylinderMath.chipTilt(distance: distance)),
            axis: (x: 1, y: 0, z: 0)
        )
        .onHover { hovering in
            hoveredTabIndex = hovering ? index : (hoveredTabIndex == index ? nil : hoveredTabIndex)
        }
    }

    /// Loads a list that is not pinned yet. Pinned lists are absent from the
    /// menu — they are already in the drum, one tap away.
    private var addButton: some View {
        Menu {
            ForEach(unpinnedLists) { list in
                Button {
                    settingsStore.appendReminderTab(listID: list.id)
                    store.select(listID: list.id)
                } label: {
                    Text(list.title)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.05)))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(unpinnedLists.isEmpty)
        .help("Pin a list as a tab")
    }

    private var unpinnedLists: [ReminderList] {
        store.lists.filter { list in !pinnedListIDs.contains(list.id) }
    }

    private func title(for listID: String) -> String {
        store.lists.first { $0.id == listID }?.title ?? "…"
    }

    private func activate(index: Int) {
        guard pinnedListIDs.indices.contains(index) else { return }
        settingsStore.reminderActiveTabIndex = index
        store.select(listID: pinnedListIDs[index])
    }

    /// Re-points the selection at whatever the active index now holds. A
    /// no-op when the removal did not touch the active tab's list.
    private func syncSelection() {
        let index = settingsStore.reminderActiveTabIndex
        guard pinnedListIDs.indices.contains(index) else { return }
        store.select(listID: pinnedListIDs[index])
    }
}

// MARK: - Wheel capture

/// A horizontal strip that turns the drum instead of scrolling content: every
/// wheel notch is reported as one ±1 step, and nothing moves on its own. Same
/// shape as `WheelDrivenScrollView` — an AppKit scroller wrapping the SwiftUI
/// content — because SwiftUI cannot intercept a mouse wheel on macOS 14, and
/// an unanswered wheel would reach the list underneath.
struct WheelSteppedScrollView<Content: View>: NSViewRepresentable {
    /// +1 turns to the next slot, -1 to the previous.
    let onStep: (Int) -> Void
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator(onStep: onStep)
    }

    func makeNSView(context: Context) -> SteppedScrollView {
        let scrollView = SteppedScrollView()
        let documentView = NSHostingView(rootView: content)
        documentView.sizingOptions = []
        documentView.frame = NSRect(x: 0, y: 0, width: 1, height: reminderTabStripHeight)
        scrollView.documentView = documentView
        scrollView.onStep = { context.coordinator.onStep($0) }
        return scrollView
    }

    func updateNSView(_ scrollView: SteppedScrollView, context: Context) {
        context.coordinator.onStep = onStep
        if let hostingView = scrollView.documentView as? NSHostingView<Content> {
            hostingView.rootView = content
        }
        scrollView.fitDocumentView()
    }

    final class Coordinator {
        var onStep: (Int) -> Void
        init(onStep: @escaping (Int) -> Void) {
            self.onStep = onStep
        }
    }

    /// The scroller the strip lives in: it never scrolls — the document view is
    /// always exactly the visible strip — and the wheel turns the drum instead.
    final class SteppedScrollView: NSScrollView {
        var onStep: ((Int) -> Void)?

        /// Precise deltas (trackpad) accumulate; a notch of a plain wheel is
        /// one step on its own. Tuned by feel: small enough that one turn of
        /// the wheel is one slot, large enough that a resting finger does not
        /// spin the drum.
        private var accumulatedDelta: CGFloat = 0
        /// An instance constant on purpose: a type nested in a generic one
        /// cannot carry static stored properties.
        private var preciseStepThreshold: CGFloat { 12 }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            drawsBackground = false
            hasHorizontalScroller = false
            hasVerticalScroller = false
            horizontalScrollElasticity = .none
            verticalScrollElasticity = .none
            contentView.drawsBackground = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("SteppedScrollView is created in code only")
        }

        override func scrollWheel(with event: NSEvent) {
            // The dominant axis wins, so a diagonal trackpad swipe does not
            // double-fire.
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                ? event.scrollingDeltaY
                : event.scrollingDeltaX
            guard delta != 0 else { return }

            if event.hasPreciseScrollingDeltas {
                accumulatedDelta += delta
                if abs(accumulatedDelta) >= preciseStepThreshold {
                    onStep?(accumulatedDelta < 0 ? 1 : -1)
                    accumulatedDelta = 0
                }
            } else {
                onStep?(delta < 0 ? 1 : -1)
            }
            // Deliberately not calling super: the drum turns, the strip never
            // scrolls, and the event must not reach the list underneath.
        }

        override func tile() {
            super.tile()
            fitDocumentView()
        }

        /// Sizes the document view to the visible strip, re-run whenever the
        /// scroller is laid out or SwiftUI updates, so a drawer resize never
        /// leaves the chips laid out against a stale width.
        func fitDocumentView() {
            let width = max(contentView.bounds.width, 1)
            guard let documentView,
                  documentView.frame.size
                      != NSSize(width: width, height: reminderTabStripHeight)
            else { return }
            documentView.frame = NSRect(
                x: 0,
                y: 0,
                width: width,
                height: reminderTabStripHeight
            )
        }
    }
}

import SwiftUI

/// The tab pager: remove, switch, add.
///
/// The dots live inside a strip whose width comes from `NotebookToolbarLayout`,
/// never from the row's willingness to squeeze: a strip that is drawn slightly
/// too wide would paint over the buttons beside it, which is what used to happen
/// once a notebook grew past three tabs. What does not fit is reached by sliding
/// the strip with the wheel, and the selected dot is kept in view.
struct TabPagerControl: View {
    @ObservedObject var store: NoteStore
    let editorInteractionState: EditorInteractionState
    let layout: NotebookToolbarLayout

    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: Self.gap) {
            Button {
                rememberCurrentSelection()
                withAnimation(tabSwitchAnimation) {
                    store.removeActiveTab()
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: NotebookToolbarLayout.iconButton, height: NotebookToolbarLayout.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabIconButtonStyle())
            .disabled(store.tabs.count <= 1)
            .help("Remove current tab")

            strip

            Button {
                rememberCurrentSelection()
                withAnimation(tabSwitchAnimation) {
                    store.addTab()
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: NotebookToolbarLayout.iconButton, height: NotebookToolbarLayout.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabIconButtonStyle())
            .help("New tab")
        }
        .frame(height: 28, alignment: .center)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.045))
        )
        .onAppear { revealActiveTab() }
        .onChange(of: store.activeTabID) { _, _ in revealActiveTab() }
        .onChange(of: store.tabs.count) { _, _ in revealActiveTab() }
        // The drawer is resizable, so the strip's viewport changes with it and
        // the offset has to be clamped back inside the new one.
        .onChange(of: layout) { _, _ in revealActiveTab() }
    }

    private var strip: some View {
        HorizontalWheelScroll(
            offset: $scrollOffset,
            contentWidth: NotebookToolbarLayout.stripContentWidth(tabCount: store.tabs.count),
            height: 28
        ) {
            HStack(spacing: NotebookToolbarLayout.dotSpacing) {
                ForEach(store.tabs) { tab in
                    dot(for: tab)
                }
            }
            .frame(height: 28, alignment: .center)
        }
        .frame(width: layout.stripWidth(tabCount: store.tabs.count), height: 28)
    }

    private func dot(for tab: NoteTab) -> some View {
        let isSelected = tab.id == store.activeTabID
        return Button {
            rememberCurrentSelection()
            withAnimation(tabSwitchAnimation) {
                store.selectTab(tab.id)
            }
        } label: {
            Capsule()
                .fill(isSelected ? Color.white.opacity(0.82) : Color.white.opacity(0.34))
                .frame(
                    width: isSelected
                        ? NotebookToolbarLayout.selectedDotWidth
                        : NotebookToolbarLayout.unselectedDotWidth,
                    height: 6
                )
                .frame(width: NotebookToolbarLayout.dotSlot, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabDotButtonStyle(isSelected: isSelected))
        .help("Switch tab")
    }

    private var tabSwitchAnimation: Animation {
        .spring(response: 0.26, dampingFraction: 0.82)
    }

    private var activeIndex: Int {
        store.tabs.firstIndex { $0.id == store.activeTabID } ?? 0
    }

    private func revealActiveTab() {
        let next = layout.scrollOffset(
            keepingVisible: activeIndex,
            currentOffset: scrollOffset,
            tabCount: store.tabs.count
        )
        guard abs(next - scrollOffset) > 0.5 else { return }
        scrollOffset = next
    }

    private func rememberCurrentSelection() {
        guard let range = editorInteractionState.currentSelectionRange() else { return }
        store.updateSelection(for: store.activeTabID, range: range)
    }

    private static var gap: CGFloat { 6 }
}

import SwiftUI

/// The notebook drawer's toolbar row: the tab pager on the left, the controls
/// the drawer always carries on the right.
///
/// A view of its own because the row is the one place where the tab strip's
/// width and the controls beside it are decided together — the strip is the only
/// part that grows with the user's data, and `NotebookToolbarLayout` is the only
/// place that knows what the rest of the row costs. Keeping the row in one file
/// also lets `Scripts/toolbar-layout-probe.sh` compile the real thing and measure
/// it, rather than a copy that can drift.
struct NotebookToolbar: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var settingsStore: AppSettingsStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    let editorInteractionState: EditorInteractionState
    let layout: NotebookToolbarLayout
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: NotebookToolbarLayout.itemSpacing) {
            // G7: the tab pager belongs to the notes surface. Hiding it in
            // other modes is what keeps the toolbar from overflowing on a
            // narrow drawer once the mode toggle is added.
            if layout.isNotesMode {
                TabPagerControl(
                    store: store,
                    editorInteractionState: editorInteractionState,
                    layout: layout
                )
            }

            Spacer(minLength: 0)

            DrawerModeToggle(
                mode: layout.mode,
                showsLabels: layout.showsModeToggleLabels
            ) { mode in
                workspaceState.fileDragForcesNotesMode = false
                settingsStore.drawerMode = mode
            }

            // G6: "Clear" means clear the note, so it has no meaning while
            // another surface is showing.
            if layout.isNotesMode {
                Button(action: store.clear) {
                    Image(systemName: "trash")
                        .frame(width: NotebookToolbarLayout.iconButton, height: NotebookToolbarLayout.iconButton)
                }
                .buttonStyle(DarkIconButtonStyle())
                .help("Clear")
            }

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .frame(width: NotebookToolbarLayout.iconButton, height: NotebookToolbarLayout.iconButton)
            }
            .buttonStyle(DarkIconButtonStyle())
            .help("Settings")
        }
        .frame(height: DrawerMetrics.toolbarHeight, alignment: .center)
    }
}

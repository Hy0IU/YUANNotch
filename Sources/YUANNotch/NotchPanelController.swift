import AppKit
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class NotchPanelController: NSObject {
    private let notesLibrary: NotesLibrary
    /// The app's one update check, handed in rather than owned here.
    ///
    /// It exists so the settings window can offer a second entry point to it.
    /// The menu-bar item that also runs it can be hidden — a menu-bar manager
    /// can park it off-screen — so an entry point that lives only in that menu
    /// is one the user may not be able to reach.
    private let onCheckForUpdates: () -> Void
    private let store: NoteStore
    private let settingsStore = AppSettingsStore()
    private let imageStore: LocalImageStore
    private let fileShelfStore = FileShelfStore()
    private var libraryCancellables: Set<AnyCancellable> = []
    private let workspaceState = NotebookWorkspaceState()
    /// Drawer animation state is per display: when the mouse jumps to
    /// another screen mid-collapse, the outgoing drawer finishes its
    /// collapse animation while the incoming one expands — a single shared
    /// state would snap the outgoing panel back open for a frame.
    private var drawerStates: [String: DrawerState] = [:]

    private func drawerState(for key: String) -> DrawerState {
        if let existing = drawerStates[key] { return existing }
        // A state can only be made for a display that is here (or for the
        // not-yet-known key, which falls back to whatever is current), because
        // its layout is derived from that display's geometry.
        let screen = NSScreen.screens.first { $0.uniqueID == key } ?? currentScreen
        let state = DrawerState(layout: drawerLayout(for: screen))
        drawerStates[key] = state
        return state
    }

    /// The one derivation of a display's drawer geometry.
    ///
    /// `NotchGeometry.layout` is the only thing that decides it; every caller
    /// goes through here so the persisted size, the panel frame and what the
    /// view draws can never disagree about what the drawer's size is.
    private func drawerLayout(for screen: NSScreen?) -> NotchLayout {
        NotchGeometry.layout(for: screen, customSize: settingsStore.customExpandedSize)
    }

    /// A display's layout from a size the caller supplies — an in-flight resize,
    /// or a preference that has just changed. `nil` is the built-in default size,
    /// and is deliberately *not* resolved to the preference: a caller holding a
    /// size must not be silently overruled by a property that, during a
    /// `@Published` delivery, has not been updated yet.
    ///
    /// Callers that only need the compact block pass `nil` and get it without
    /// the persisted drawer size being read at all — the compact sizes come from
    /// the display's notch, not from the drawer.
    private func drawerLayout(for screen: NSScreen?, size: CGSize?) -> NotchLayout {
        NotchGeometry.layout(for: screen, customSize: size)
    }

    /// Publishes a display's layout to that display's drawer, deriving it from
    /// the persisted size.
    ///
    /// This replaces rebuilding the panel's content: the drawer's geometry is
    /// state its view reads, so a size change is a value assignment instead of
    /// a teardown. The equality guard keeps a no-op resize (or a re-applied
    /// preference) from invalidating the view for nothing.
    @discardableResult
    private func applyLayout(to screen: NSScreen?) -> NotchLayout {
        applyLayout(drawerLayout(for: screen), to: drawerState(for: screen?.uniqueID ?? "unknown-screen"))
    }

    /// Publishes a layout to one drawer.
    ///
    /// Separate from the display-scoped call because a floating drawer is no
    /// longer one of a display's states — it carries its own, and a resize
    /// while detached has to reach *that* one.
    @discardableResult
    private func applyLayout(_ layout: NotchLayout, to state: DrawerState) -> NotchLayout {
        if state.layout != layout {
            state.layout = layout
        }
        return layout
    }

    /// Publishes a size every display's drawer should take, because that size
    /// is what the preference now holds.
    ///
    /// The size is carried in rather than read back from `settingsStore`: this
    /// runs from the preference's `@Published` sink, which combine delivers in
    /// `willSet`, so the property still holds its *previous* value at that
    /// moment. Reading it there — as an earlier version of this did — published
    /// the layout the drawer had before the change, and a resize that had just
    /// been committed visibly rolled back.
    private func publishDrawerLayouts(customSize: CGSize?) {
        for screen in NSScreen.screens {
            applyLayout(drawerLayout(for: screen, size: customSize), to: drawerState(for: screen.uniqueID))
        }
    }

    /// Re-derives every connected display's drawer layout from the preference.
    ///
    /// Used where the *displays* changed rather than the size: each drawer's
    /// geometry comes from its own screen, so a screen that appeared, moved or
    /// resized moves the drawer it hosts.
    private func refreshAllDrawerLayouts() {
        for screen in NSScreen.screens {
            applyLayout(to: screen)
        }
    }

    private let editorInteractionState = EditorInteractionState()
    private lazy var reminderStore = ReminderStore(settingsStore: settingsStore)
    private let dailyPlanStore = DailyPlanStore(
        onPhaseCompleted: { InterfaceSound.focusPhaseCompleted() }
    )
    private lazy var settingsWindowController = SettingsWindowController(
        settingsStore: settingsStore,
        reminderStore: reminderStore,
        notesLibrary: notesLibrary,
        noteStore: store,
        onCheckForUpdates: onCheckForUpdates
    )
    private let displayPanelRegistry = DisplayPanelRegistry()
    private var fileDragTrackingState = FileDragTrackingState()
    /// One drawer panel per display, keyed by screen uniqueID. A window that
    /// has been key on one display gets asynchronously "returned" to it by
    /// the Window Server when later shown on another display — so a drawer
    /// panel never leaves its own display.
    /// The drawer panel currently shown (on `drawerScreen`) while expanded.
    private var activeDrawerPanel: NotchPanel?
    /// Each drawer panel owns its content view permanently. Moving one
    /// shared view between windows makes the Window Server relocate the
    /// receiving window onto the screen where the view was last visible.
    private var activeHostingView: FirstMouseHostingView<NotebookView>?
    private var mousePollingTimer: Timer?
    private var mouseEventMonitor: MouseEventMonitor?
    private var isExpanded = false
    /// True while the drawer is open only as a preview for an incoming file
    /// drag, with the compact panel deliberately still on screen because it
    /// owns the live drag session.
    private var isRevealedForFileDrag = false
    private var currentScreen: NSScreen?
    private var drawerScreen: NSScreen?
    private var activeMenuTrackingCount = 0
    private var collapseTask: DispatchWorkItem?
    /// When the shelf last failed its reveal conditions, so the hide can be
    /// held off for a grace period instead of retracting on a single odd
    /// sample while a drag is running. Nil while conditions hold.
    private var pendingHideStartedAt: TimeInterval?
    /// ~0.33s of grace before the shelf retracts, so travelling from the notch
    /// down to the shelf does not blink it while parking over the editor does
    /// dismiss it.
    private static let hideGraceInterval: TimeInterval = 0.33
    /// Set from the compact notch panel's AppKit drag callbacks: a file drag
    /// over the notch strip is what reveals the shelf on its way in.
    private var isCompactDragTargeted = false
    /// Last time the editor file-drop guard was swept; the sweep runs on the
    /// wall clock so its cadence is independent of the polling rate.
    private var lastDisarmSweepAt: TimeInterval?
    private static let disarmSweepInterval: TimeInterval = 0.5
    private var hoverActivationCandidate: (screenID: String, startedAt: TimeInterval)?
    private var floatingPanel: NotchPanel?
    private var floatingHostingView: FirstMouseHostingView<NotebookView>?
    private var floatingDrawerState: DrawerState?
    private var panelDragSession: PanelDragSession?
    private var isDockingPanel = false
    private var backgroundDragLastFrame: NSRect?
    private var isDraggingFloatingPanelBackground = false

    private struct PanelDragSession {
        let panel: NotchPanel
        let drawerState: DrawerState
        let startMouseLocation: NSPoint
        let startPanelFrame: NSRect
        let sourceScreenID: String?
        var isDetached: Bool
        var dockingScreenID: String?
    }

    private static let detachmentThreshold: CGFloat = 52

    init(notesLibrary: NotesLibrary, onCheckForUpdates: @escaping () -> Void) {
        self.notesLibrary = notesLibrary
        self.onCheckForUpdates = onCheckForUpdates
        store = NoteStore(library: notesLibrary)
        imageStore = LocalImageStore(notesDirectoryURL: notesLibrary.directoryURL)
        super.init()

        // The images live inside the notes folder, so they move with it. Capturing the
        // store rather than `self` keeps this a plain call on a plain object: the
        // folder signal is sent from the notes library, which is already on the main
        // actor.
        let imageStore = self.imageStore
        notesLibrary.folderChanged
            .sink { imageStore.moveTo(notesDirectoryURL: $0) }
            .store(in: &libraryCancellables)

        // The persisted size is the preference; each display's drawer layout is
        // the geometry in force. A change to one therefore has to reach the
        // other, and this is that edge — it is what makes the settings page (or
        // a resize's own commit) able to move the drawer without the panel
        // rebuilding its content.
        //
        // The emitted value is carried into the call on purpose: `@Published`
        // publishes in `willSet`, so re-reading the property here would hand
        // over the size the drawer had *before* this change.
        settingsStore.$customExpandedSize
            .dropFirst()
            .sink { [weak self] size in self?.publishDrawerLayouts(customSize: size) }
            .store(in: &libraryCancellables)

        startMousePolling()
        observeScreenChanges()
        observeGlobalSelectionMouseEvents()
        observeMenuTracking()
    }

    private func makeDrawerPanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            // Atoll-style window recipe: .borderless + .nonactivatingPanel,
            // no .fullSizeContentView. Two effects with tiling WMs
            // (AeroSpace):
            // 1. No usable AX fullscreen button -> AeroSpace's
            //    isDialogHeuristic floats the drawer instead of tiling it
            //    (previously it dragged the drawer onto the focused
            //    workspace's display).
            // 2. Unlike an AX subrole masquerade, the drawer stays a real
            //    (floating) window in the WM's tree, so focusing it updates
            //    the WM's focus model and its click-arbitration
            //    (clickedMonitor.activeWorkspace != focus.workspace ->
            //    focusWorkspace) no longer yanks keyboard focus back right
            //    after the first click.
            // .nonactivatingPanel (Spotlight-style): the drawer can become
            // key for typing WITHOUT making the app frontmost. Activating
            // the app would emit an AX focus event that window managers
            // answer by summoning the workspace that last held one of our
            // normal windows — visibly switching workspaces on another
            // display.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel(panel)
        panel.onMouseEvent = { [weak self, weak panel] event in
            guard let self, let panel else { return }
            if self.handlePanelDragEvent(event, panel: panel) { return }
            if self.handleResizeMouseEvent(event) { return }
            self.editorInteractionState.handleMouseEvent(event, searchingIn: panel.contentView)
        }
        return panel
    }

    private func drawerPanel(for screen: NSScreen?) -> NotchPanel {
        let key = screen?.uniqueID ?? "unknown-screen"
        if let existing = displayPanelRegistry.drawerPanel(for: key) { return existing }
        let panel = makeDrawerPanel()
        displayPanelRegistry.setDrawerPanel(panel, for: key)
        return panel
    }

    func flushPendingSave() {
        store.flushPendingSave()
        dailyPlanStore.flushPendingSave()
    }

    func showDocked() {
        currentScreen = NotchGeometry.targetScreen()
        applyLayout(to: currentScreen)
        // The launch path: hot panels come into existence here, and only here
        // or on a display change — their geometry is the compact block, which
        // the drawer's own size does not enter.
        rebuildAllHotPanels()
        isExpanded = false
        isRevealedForFileDrag = false
        for state in drawerStates.values {
            state.isExpanded = false
            state.revealProgress = 0
        }
    }

    /// Shows the drawer on the screen containing `currentScreen`, using the
    /// drawer panel dedicated to that display.
    ///
    /// The drawer is ONLY ever ordered front, never programmatically made
    /// key or activated — programmatic focus changes on multi-display setups
    /// cause erratic window placement. The drawer becomes key naturally when
    /// the user clicks into it (first-mouse is accepted).
    func expand(animated: Bool) {
        if let floatingPanel {
            floatingPanel.orderFrontRegardless()
            return
        }
        resetHoverActivationCandidate()
        if isExpanded {
            // Already open on this display: nothing to do.
            guard drawerScreen?.uniqueID != currentScreen?.uniqueID else { return }
            // Hovering/clicking another display's notch hands off: the
            // outgoing drawer keeps playing its collapse animation (its
            // state is per-display) while the new one expands on top.
            handoffCollapse()
        }
        let layout = applyLayout(to: currentScreen)
        cancelCollapse()
        isExpanded = true
        drawerScreen = currentScreen
        workspaceState.isShelfDropTargeted = false
        let panel = drawerPanel(for: currentScreen)
        activeDrawerPanel = panel
        activeHostingView = hostingView(for: currentScreen)
        panel.setFrame(drawerFrame(for: layout, screen: currentScreen), display: true)
        panel.orderFrontRegardless()
        // Never take the compact panel away while it is the window AppKit is
        // delivering the file drag to: ordering out the live drag destination
        // mid-session makes the drag feedback flap between the two windows and
        // the drop is lost. On a file-drag reveal the compact panel therefore
        // stays on screen — above the drawer — and stands down when the drag
        // has moved on or ended.
        if isFileDragInProgress() {
            isRevealedForFileDrag = true
            // G3: the file shelf lives on the notes surface, so a file drag
            // that opens the drawer forces it. The override is what makes the
            // drag land at all — a drop is rejected outside the notes surface —
            // and it lasts only as long as the drag. If the drop succeeds the
            // mode is then changed for real in `receiveDroppedFiles`; if the
            // drag is cancelled, the user's own mode comes back untouched.
            workspaceState.fileDragForcesNotesMode = true
            hotPanelForScreen(currentScreen)?.orderFrontRegardless()
        } else {
            isRevealedForFileDrag = false
            workspaceState.fileDragForcesNotesMode = false
            hotPanelForScreen(currentScreen)?.orderOut(nil)
        }
        setDrawerExpanded(true, animated: animated, for: currentScreen?.uniqueID ?? "unknown-screen")
    }

    /// Cross-display handoff: unlike `collapse`, the outgoing panel stays
    /// visible until its collapse animation has played out, so the two
    /// displays animate independently.
    private func handoffCollapse() {
        let oldPanel = activeDrawerPanel
        let oldKey = drawerScreen?.uniqueID
        if let range = editorInteractionState.currentSelectionRange() {
            store.updateSelection(for: store.activeTabID, range: range)
        }
        isExpanded = false
        drawerScreen = nil
        if let oldKey {
            setDrawerExpanded(false, animated: true, for: oldKey)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            // The user may have switched back to this display meanwhile
            // (A→B→A within the animation window) — don't kill its panel.
            let reclaimed = self.isExpanded && self.drawerScreen?.uniqueID == oldKey
            if !reclaimed {
                oldPanel?.orderOut(nil)
            }
            if !reclaimed, let oldKey, let screen = NSScreen.screens.first(where: { $0.uniqueID == oldKey }) {
                self.hotPanelForScreen(screen)?.orderFrontRegardless()
            }
        }
    }

    func collapse(animated: Bool) {
        if let floatingPanel {
            floatingPanel.orderOut(nil)
            return
        }
        guard isExpanded else { return }
        resetHoverActivationCandidate()
        if let range = editorInteractionState.currentSelectionRange() {
            store.updateSelection(for: store.activeTabID, range: range)
        }
        isExpanded = false
        isRevealedForFileDrag = false
        let collapsingKey = drawerScreen?.uniqueID
        drawerScreen = nil
        setDrawerExpanded(false, animated: animated, for: collapsingKey ?? "unknown-screen")

        if animated {
            // SwiftUI animation: easeOut 0.16s
            // Order out drawer right as animation completes, then show hot panels
            // SwiftUI easeOut is 0.16s; use 0.20s to ensure animation is fully complete
            let collapsingPanel = activeDrawerPanel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                guard let self else { return }
                if self.isExpanded {
                    // Re-expanded meanwhile; only hide the collapsing panel if
                    // the new expansion uses a different display's panel
                    if self.activeDrawerPanel !== collapsingPanel {
                        collapsingPanel?.orderOut(nil)
                        // The collapsing display's hot panel must come back
                        // even though a new drawer opened on another display
                        // (rebuildAllHotPanels does not re-show existing
                        // hidden panels — only this restores it).
                        self.showAllHotPanels()
                        self.hotPanelForScreen(self.drawerScreen)?.orderOut(nil)
                    }
                    return
                }
                // Show hot panels before removing the drawer so the handoff
                // overlaps instead of leaving a one-frame gap
                self.showAllHotPanels()
                collapsingPanel?.orderOut(nil)
            }
        } else {
            activeDrawerPanel?.orderOut(nil)
            showAllHotPanels()
        }
    }

    private func configurePanel(_ panel: NotchPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
    }

    private func makeNotebookView(drawerState: DrawerState) -> NotebookView {
        NotebookView(
            store: store,
            settingsStore: settingsStore,
            imageStore: imageStore,
            fileShelfStore: fileShelfStore,
            reminderStore: reminderStore,
            dailyPlanStore: dailyPlanStore,
            workspaceState: workspaceState,
            drawerState: drawerState,
            editorInteractionState: editorInteractionState,
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
    }

    /// Get-or-create the drawer content for a display. Each panel keeps its
    /// own hosting view for its entire lifetime — views never move between
    /// windows (doing so makes the Window Server relocate the receiving
    /// window onto the screen where the view was last visible).
    ///
    /// "Entire lifetime" is literal: the root view is built once here. A size
    /// change reaches the drawer through `DrawerState.layout`, never by
    /// handing this hosting view a different root view.
    private func hostingView(for screen: NSScreen?) -> FirstMouseHostingView<NotebookView> {
        let key = screen?.uniqueID ?? "unknown-screen"
        if let existing = displayPanelRegistry.drawerHostingView(for: key) { return existing }
        let host = DrawerFileDropHostingView(rootView: makeNotebookView(drawerState: drawerState(for: key)))
        host.autoresizingMask = [.width, .height]
        // This panel's geometry is the controller's to decide, and every frame
        // it gets comes from the layout. A hosting view on its default sizing
        // options also publishes its content's min/max size to the window as
        // `contentMinSize`/`contentMaxSize`, which makes AppKit resize the panel
        // from a content size that lags a layout change by a pass — a feedback
        // loop against the frame that was just set. Opting out leaves the window
        // size one-way: controller to view.
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        configureDrawerFileDrop(host)
        displayPanelRegistry.setDrawerHostingView(host, for: key)
        displayPanelRegistry.drawerPanel(for: key)?.contentView = host
        primeEditor(in: host)
        return host
    }

    /// Points this display's editor at the caret that was in use and makes its
    /// text view the panel's first responder — once, when the drawer's content
    /// comes into existence.
    ///
    /// This ran on every `expand()` until the drawer stopped rebuilding its
    /// content: a rebuild installed a fresh editor, so the caret and the
    /// responder had to be re-established every time the drawer opened. The
    /// drawer publishes a layout now and the editor outlives a collapse, so only
    /// a newly created one needs priming — and `expand()` no longer has to know
    /// anything about the editor.
    ///
    /// Two things the priming still buys:
    ///
    /// - the caret comes back where the user left it (`restoreSelection` reads
    ///   the range the store persisted for the active page);
    /// - the text view is the panel's first responder *before* the panel is key,
    ///   so clicking anywhere in the drawer — the background included, not just
    ///   the text — starts typing in the editor. The panel is deliberately never
    ///   keyed or activated programmatically; it becomes key when the user clicks
    ///   into it (`EditorInteractionState.focusEditor`, and `cc06e0e` for why).
    ///
    /// Delayed because the view has not joined a window at this point; the calls
    /// themselves retry, this is the outer margin. The drag-type sweep is *not*
    /// repeated here — `mousePollingTick` already narrows the editor's drop types
    /// every half second, which is what actually catches the text view arming
    /// itself when it joins a window.
    private func primeEditor(in host: FirstMouseHostingView<NotebookView>) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self, weak host] in
            guard let self, let host else { return }
            self.editorInteractionState.restoreSelection(
                self.store.selectionRange(for: self.store.activeTabID),
                searchingIn: host
            )
            self.editorInteractionState.requestFocus(searchingIn: host)
            self.editorInteractionState.requestLayoutRefresh(searchingIn: host)
        }
    }

    private func rebuildAllHotPanels() {
        let screens = NSScreen.screens
        var activeScreenIDs = Set<String>()

        for screen in screens {
            let id = screen.uniqueID
            activeScreenIDs.insert(id)

            // Per-screen layout: each display gets its own compact size
            // (notched built-in vs. fallback for external displays).
            let layout = drawerLayout(for: screen, size: nil)
            let frame = hotFrame(for: layout, screen: screen)
            let hotView = CompactNotchView(layout: layout, onTap: { [weak self, weak screen] in
                guard let self, let screen else { return }
                self.currentScreen = screen
                self.expand(animated: true)
            })
            if let existing = displayPanelRegistry.hotHostingView(for: id),
               let panel = displayPanelRegistry.hotPanel(for: id) {
                existing.rootView = hotView
                panel.setFrame(frame, display: true)
            } else {
                let panel = NotchPanel(
                    contentRect: .zero,
                    // .nonactivatingPanel: clicking the compact notch must
                    // not activate the app either (see makeDrawerPanel).
                    styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.allowsKeyboardFocus = false
                configurePanel(panel)
                panel.onMouseEvent = { [weak self, weak screen] event in
                    guard let self, let screen else { return }
                    self.currentScreen = screen
                    guard event.type == .leftMouseDown else { return }
                    self.expand(animated: true)
                }
                let host = CompactFileDropHostingView(rootView: hotView)
                host.translatesAutoresizingMaskIntoConstraints = false
                // Same reason as the drawer's hosting view: the compact panel's
                // frame is set here, and the content must not resize it back.
                host.sizingOptions = []
                host.wantsLayer = true
                host.layer?.masksToBounds = true
                configureCompactFileDrop(host, screen: screen)
                panel.contentView = host
                panel.setFrame(frame, display: true)
                panel.orderFrontRegardless()
                displayPanelRegistry.setHotPanel(panel, for: id)
                displayPanelRegistry.setHotHostingView(host, for: id)
            }
        }

        for (id, panel) in displayPanelRegistry.hotPanelEntries where !activeScreenIDs.contains(id) {
            panel.orderOut(nil)
            displayPanelRegistry.removeHotPanel(for: id)
            displayPanelRegistry.removeHotHostingView(for: id)
        }
    }

    private func hotPanelForScreen(_ screen: NSScreen?) -> NotchPanel? {
        guard let screen else { return nil }
        return displayPanelRegistry.hotPanel(for: screen.uniqueID)
    }

    private func configureCompactFileDrop(_ host: CompactFileDropHostingView<CompactNotchView>, screen: NSScreen) {
        host.onFileDragTargeted = { [weak self, weak screen] targeted in
            guard let self, let screen else { return }
            self.isCompactDragTargeted = targeted

            guard targeted else {
                // The drag has left the compact panel. Whatever is under it
                // now owns the session, so the compact panel may stand down —
                // but only after AppKit has finished re-targeting, hence the
                // async hop.
                DispatchQueue.main.async { [weak self] in
                    self?.finishFileDragRevealIfNeeded()
                }
                return
            }

            // A file drag brings the drawer up whatever the shelf setting is:
            // the same gesture also carries a path the user may want to work
            // with, and the shelf keeps itself hidden when it is disabled.
            // On the drawer's own display this callback can't fire while the
            // drawer is expanded (its hot panel is ordered out); on another
            // display, hand the drawer over mid-drag.
            guard !self.isExpanded || self.drawerScreen?.uniqueID != screen.uniqueID else { return }
            self.currentScreen = screen
            self.expand(animated: true)
        }
        host.onFilesDropped = { [weak self] urls in
            self?.receiveDroppedFiles(urls) ?? false
        }
    }

    private func configureDrawerFileDrop(_ host: DrawerFileDropHostingView<NotebookView>) {
        // Claim external file drags only when the shelf can actually accept
        // them, and never claim drags that originate from the shelf itself
        // (dragging chips out writes file URLs to the drag pasteboard too).
        host.isFileDragActive = { [weak self] in
            guard let self else { return false }
            return self.settingsStore.isFileShelfEnabled
                && self.isFileDragInProgress()
                && !self.workspaceState.isDraggingShelfItem
        }
        host.onFileDragTargeted = { [weak self] targeted in
            guard let self, targeted else { return }
            // Reveal-only, for the same reason as the SwiftUI callback: the
            // show/hide decision must not flap with the cursor position.
            FileDragDiagnostics.log("drawer drag entered -> reveal shelf")
            // G3: an external file drag also arrives this way (the compact
            // panel's drag callbacks), so the session override is applied here
            // too rather than only in expand(animated:).
            if self.isFileDragInProgress() {
                self.workspaceState.fileDragForcesNotesMode = true
            }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                self.workspaceState.isShelfDropTargeted = true
            }
        }
        host.onFilesDropped = { [weak self] urls in
            self?.receiveDroppedFiles(urls) ?? false
        }
    }

    private func receiveDroppedFiles(_ urls: [URL]) -> Bool {
        // G5: the drawer's own file-drop target only exists on the notes
        // surface. During an external drag the session override has already
        // forced that surface, so this only rejects drops made while the user
        // is deliberately looking at another surface.
        guard workspaceState.effectiveMode(persistedMode: settingsStore.drawerMode) == .notes else {
            FileDragDiagnostics.log("panel receiveDroppedFiles rejected: non-notes surface")
            return false
        }

        let accepted = fileShelfStore.acceptDrop(urls)
        FileDragDiagnostics.log(
            "panel receiveDroppedFiles accepted=\(accepted) items=\(fileShelfStore.items.count)"
        )
        guard settingsStore.isFileShelfEnabled, accepted else { return false }

        // A drop that landed is the user saying which surface they are working
        // on: they have just put a file into a shelf that only exists on the
        // notes side. Without this the drag override would hand them back to
        // reminders the instant the drag ended, which reads as the drawer
        // forgetting what they just did.
        workspaceState.commitLandedFileDrop(to: &settingsStore.drawerMode)

        // Reveal the shelf as drop feedback. Defer so AppKit can finish the
        // drop callback before the window order changes — replacing the
        // window that owns an active dragging destination is not allowed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isExpanded else {
                self.finishFileDragRevealIfNeeded()
                return
            }
            self.expand(animated: true)
        }
        return true
    }

    private func showAllHotPanels() {
        for (_, panel) in displayPanelRegistry.hotPanelEntries {
            panel.orderFrontRegardless()
        }
    }

    private func setDrawerExpanded(_ expanded: Bool, animated: Bool, for key: String) {
        let state = drawerState(for: key)
        guard animated else {
            state.isExpanded = expanded
            state.revealProgress = expanded ? 1 : 0
            return
        }

        let animation: Animation = expanded
            ? .spring(response: 0.28, dampingFraction: 0.86)
            : .easeOut(duration: 0.16)

        withAnimation(animation) {
            state.isExpanded = expanded
            state.revealProgress = expanded ? 1 : 0
        }
    }

    private func startMousePolling() {
        // 30 Hz is enough for everything this tick drives: the hover delay,
        // the hide grace, and the disarm sweep are all ≥0.3s and measured on
        // the wall clock, so the extra 33ms of sampling latency is invisible
        // next to them — while halving the timer wakeups and the drag
        // pasteboard reads.
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(mousePollingTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        mousePollingTimer = timer
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }



    /// Global monitors for the mouse *gestures* that can start outside our
    /// windows and still affect the drawer. The file-drag detector does not
    /// depend on these anymore — it polls the drag pasteboard instead, so a
    /// monitor that never fires (sandboxed or unauthorized process) can no
    /// longer silently disable it.
    private func observeGlobalSelectionMouseEvents() {
        mouseEventMonitor = MouseEventMonitor(
            onMouseDragged: { [weak self] _ in
                Task { @MainActor in
                    self?.editorInteractionState.noteGlobalMouseDragged()
                }
            },
            onMouseUp: { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.editorInteractionState.noteGlobalMouseUp()
                    self.workspaceState.isDraggingShelfItem = false
                }
            }
        )
    }

    private func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        cancelCollapse()
        resetHoverActivationCandidate()
        // If the drawer was open on a display that disappeared, fall back
        if let drawerScreen, !NSScreen.screens.contains(where: { $0.uniqueID == drawerScreen.uniqueID }) {
            self.drawerScreen = nil
        }
        let screen = drawerScreen ?? currentScreen ?? NotchGeometry.targetScreen()
        // Drop drawer panels belonging to displays that are gone
        let connectedIDs = Set(NSScreen.screens.map(\.uniqueID))
        for (key, panel) in displayPanelRegistry.drawerPanelEntries where !connectedIDs.contains(key) {
            if activeDrawerPanel === panel {
                activeDrawerPanel = nil
                activeHostingView = nil
            }
            panel.orderOut(nil)
            displayPanelRegistry.removeDrawerPanel(for: key)
            displayPanelRegistry.removeDrawerHostingView(for: key)
            drawerStates.removeValue(forKey: key)
        }
        rebuildAllHotPanels()
        // Every connected display's drawer geometry is derived from its own
        // screen, so a change to any screen's frame moves them all — not just
        // the display the drawer happens to be open on.
        refreshAllDrawerLayouts()
        if isExpanded {
            activeDrawerPanel?.setFrame(drawerFrame(for: drawerLayout(for: screen), screen: screen), display: true)
        }
        // The notification can fire while display frames are still mid-transition;
        // rebuild once more after the geometry settles so panels never keep
        // stale (possibly off-screen) frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.rebuildAllHotPanels()
        }
    }

    @objc private func mousePollingTick(_ timer: Timer) {
        // Keep the drag-pasteboard baseline up to date while no button is
        // held; during a drag the baseline stays frozen so the session's
        // pasteboard write keeps reading as "changed".
        let pasteboard = NSPasteboard(name: .drag)
        if !Self.isLeftMouseButtonDown {
            fileDragTrackingState.markPasteboardSettled(pasteboard)
        }
        updateFloatingBackgroundDrag()
        let now = ProcessInfo.processInfo.systemUptime
        updateShelfReveal(at: now)
        if !isFileDragInProgress() {
            isCompactDragTargeted = false
            finishFileDragRevealIfNeeded()
        }
        // The editor's text view arms itself as a file-drop destination
        // shortly after it joins a window; sweep often enough that a file
        // drag can never find it armed.
        if lastDisarmSweepAt == nil || now - lastDisarmSweepAt! >= Self.disarmSweepInterval {
            lastDisarmSweepAt = now
            EditorFileDropGuard.disarm(in: activeHostingView)
        }
        handleMouseLocation(NSEvent.mouseLocation)
    }

    /// Shows the shelf while a file drag is over the shelf's own strip (or
    /// over the compact notch, which is where a drag toward the notch lands),
    /// and hides it once the drag has been elsewhere for a moment.
    ///
    /// Both edges are derived from the *panel frame* and the cursor position,
    /// so they stand still during a drag — the shelf changing the editor's
    /// height cannot move the trigger region out from under the cursor, which
    /// is what made the shelf oscillate before. The hide is held off by a
    /// grace period so travelling from the notch down to the shelf does not
    /// blink it, while parking the drag over the editor does dismiss it.
    private func updateShelfReveal(at now: TimeInterval) {
        guard !workspaceState.isPreviewingShelfItem else { return }

        let isFileDrag = settingsStore.isFileShelfEnabled && isFileDragInProgress()
        if isFileDrag,
           workspaceState.effectiveMode(persistedMode: settingsStore.drawerMode) != .notes {
            // G4: revealing the shelf over a non-notes surface would put it
            // above a panel that refuses drops. Force the notes surface for
            // this session instead of suppressing the reveal, so the drop the
            // user is already performing still lands.
            workspaceState.fileDragForcesNotesMode = true
        }
        let mouseLocation = NSEvent.mouseLocation
        let isOverShelfStrip = activeDrawerPanel.map {
            shelfRevealStrip(for: $0.frame).contains(mouseLocation)
        } ?? false
        let shouldReveal = isFileDrag
            && (isOverShelfStrip || isCompactDragTargeted)
            && !workspaceState.isDraggingShelfItem

        if shouldReveal {
            pendingHideStartedAt = nil
        } else if workspaceState.isShelfDropTargeted {
            if pendingHideStartedAt == nil {
                pendingHideStartedAt = now
            }
        } else {
            pendingHideStartedAt = nil
        }

        let isHideGraceExpired = pendingHideStartedAt.map {
            now - $0 >= Self.hideGraceInterval
        } ?? false
        let keepRevealed = shouldReveal
            || (workspaceState.isShelfDropTargeted && !isHideGraceExpired)
        guard keepRevealed != workspaceState.isShelfDropTargeted else { return }

        FileDragDiagnostics.log(
            """
            shelf reveal=\(keepRevealed) fileDrag=\(isFileDrag) overShelfStrip=\(isOverShelfStrip) \
            compactTargeted=\(isCompactDragTargeted) mouse=\(Int(mouseLocation.x)),\(Int(mouseLocation.y))
            """
        )
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            workspaceState.isShelfDropTargeted = keepRevealed
        }
    }

    /// The shelf's strip in screen coordinates: its own height plus the
    /// content padding and slack above it, anchored to the panel's bottom.
    private func shelfRevealStrip(for panelFrame: NSRect) -> NSRect {
        let height = ShelfMetrics.shelfHeight(forDrawerHeight: panelFrame.height)
            + ShelfMetrics.revealBandSlack
        return NSRect(
            x: panelFrame.minX,
            y: panelFrame.minY,
            width: panelFrame.width,
            height: height
        )
    }

    @objc private func menuTrackingDidBegin(_ notification: Notification) {
        activeMenuTrackingCount += 1
        cancelCollapse()
    }

    @objc private func menuTrackingDidEnd(_ notification: Notification) {
        activeMenuTrackingCount = max(0, activeMenuTrackingCount - 1)
        guard activeMenuTrackingCount == 0, isExpanded else { return }
        handleMouseLocation(NSEvent.mouseLocation)
    }

    /// Stands the compact panel down once it is no longer the drag's owner.
    ///
    /// Called only from moments where the drag has already moved off the
    /// compact panel (or the session is over), or after an async hop out of a
    /// drop callback — never while the compact panel is still the active
    /// drag destination.
    private func finishFileDragRevealIfNeeded() {
        guard isRevealedForFileDrag else { return }
        isRevealedForFileDrag = false
        // G3: the drag is over, so the session override goes away and the
        // drawer shows the persisted mode. After a drop that landed that mode
        // is already notes — `receiveDroppedFiles` changed it; after a
        // cancelled drag it is whatever the user had chosen.
        workspaceState.fileDragForcesNotesMode = false
        guard isExpanded else { return }
        FileDragDiagnostics.log("file-drag reveal finished: compact panel stands down")
        hotPanelForScreen(drawerScreen)?.orderOut(nil)
    }

    private func handleMouseLocation(_ point: NSPoint) {
        if floatingPanel != nil || panelDragSession != nil || isDockingPanel {
            resetHoverActivationCandidate()
            cancelCollapse()
            return
        }

        if isExpanded {
            if activeMenuTrackingCount > 0 {
                resetHoverActivationCandidate()
                cancelCollapse()
                return
            }

            if editorInteractionState.isDraggingSelection {
                resetHoverActivationCandidate()
                cancelCollapse()
                return
            }

            if isResizingDrawer {
                resetHoverActivationCandidate()
                cancelCollapse()
                return
            }

            if workspaceState.isDraggingShelfItem {
                resetHoverActivationCandidate()
                cancelCollapse()
                return
            }

            if workspaceState.isPreviewingShelfItem {
                resetHoverActivationCandidate()
                cancelCollapse()
                return
            }

            // An external file drag pins the drawer open: the drag wanders
            // in and out of the stay region while the user aims at the
            // shelf, and re-triggering expand/collapse on each crossing
            // reads as flicker. (Shelf-item drags already returned above.)
            if isFileDragInProgress() {
                resetHoverActivationCandidate()
                // Dragging toward another display's notch hands the drawer
                // over; the plain quick-handoff below requires an
                // unpressed button, which a drag never satisfies.
                for screenID in displayPanelRegistry.hotDisplayIDs where screenID != drawerScreen?.uniqueID {
                    guard let screen = NSScreen.screens.first(where: { $0.uniqueID == screenID }) else { continue }
                    let layout = drawerLayout(for: screen, size: nil)
                    if fileDropFrame(for: layout, screen: screen).contains(point) {
                        currentScreen = screen
                        expand(animated: true)
                        return
                    }
                }
                cancelCollapse()
                return
            }

            // Keep the current drawer open while the pointer satisfies the
            // configured hover delay over another display's notch, then hand
            // off without an intermediate collapse.
            let hoverTarget = updateHoverActivationCandidate(
                at: point,
                excluding: drawerScreen?.uniqueID
            )
            if hoverTarget.isHovering {
                cancelCollapse()
                if let screen = hoverTarget.screen {
                    currentScreen = screen
                    expand(animated: true)
                }
                return
            }

            if isPointInExpandedStayRegion(point) {
                cancelCollapse()
            } else {
                scheduleCollapse()
            }
            return
        }

        // A file being dragged toward the notch brings the drawer up. This is
        // deliberately independent of the file-shelf setting: dragging a file
        // is also how a path is carried around, and the drawer is where it can
        // be worked with. The shelf itself only appears when it is enabled.
        if isFileDragInProgress() {
            resetHoverActivationCandidate()
            for screenID in displayPanelRegistry.hotDisplayIDs {
                guard let screen = NSScreen.screens.first(where: { $0.uniqueID == screenID }) else { continue }
                let layout = drawerLayout(for: screen, size: nil)
                if fileDropFrame(for: layout, screen: screen).contains(point) {
                    currentScreen = screen
                    expand(animated: true)
                    break
                }
            }
            return
        }

        if let screen = updateHoverActivationCandidate(at: point).screen {
            currentScreen = screen
            expand(animated: true)
        }
    }

    /// Tracks uninterrupted time over one compact notch. Moving away, moving
    /// to another display, changing trigger mode, or pressing the mouse resets
    /// the delay so separate brief passes never accumulate into an activation.
    private func updateHoverActivationCandidate(
        at point: NSPoint,
        excluding excludedScreenID: String? = nil
    ) -> (screen: NSScreen?, isHovering: Bool) {
        guard settingsStore.triggerMode == .hover, !Self.isLeftMouseButtonDown else {
            resetHoverActivationCandidate()
            return (nil, false)
        }

        guard let entry = displayPanelRegistry.hotPanelEntries.first(where: { screenID, panel in
            screenID != excludedScreenID
                && panel.frame.insetBy(dx: 0, dy: -6).contains(point)
        }),
        let screen = NSScreen.screens.first(where: { $0.uniqueID == entry.0 }) else {
            resetHoverActivationCandidate()
            return (nil, false)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if hoverActivationCandidate?.screenID != entry.0 {
            hoverActivationCandidate = (screenID: entry.0, startedAt: now)
        }

        guard let candidate = hoverActivationCandidate else {
            return (nil, true)
        }
        guard now - candidate.startedAt >= settingsStore.hoverActivationDelay else {
            return (nil, true)
        }

        resetHoverActivationCandidate()
        return (screen, true)
    }

    private func resetHoverActivationCandidate() {
        hoverActivationCandidate = nil
    }

    private func scheduleCollapse() {
        guard collapseTask == nil else { return }
        guard activeMenuTrackingCount == 0 else { return }
        guard panelDragSession == nil, floatingPanel == nil, !isDockingPanel else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseTask = nil
            guard self.activeMenuTrackingCount == 0 else { return }
            guard !self.editorInteractionState.isDraggingSelection else { return }
            guard !self.isResizingDrawer else { return }
            guard !self.workspaceState.isDraggingShelfItem else { return }
            guard !self.workspaceState.isPreviewingShelfItem else { return }
            guard !self.isFileDragInProgress() else { return }
            guard !self.isPointInExpandedStayRegion(NSEvent.mouseLocation) else { return }
            self.collapse(animated: true)
        }

        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: task)
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }



    private func isPointInExpandedStayRegion(_ point: NSPoint) -> Bool {
        let margin: CGFloat = 10
        let layout = drawerLayout(for: currentScreen, size: nil)
        let hotRect = hotFrame(for: layout, screen: currentScreen)
        if hotRect.contains(point) { return true }
        guard let panel = activeDrawerPanel else { return false }
        return panel.frame.insetBy(dx: -margin, dy: -margin).contains(point)
    }

    private var isResizingDrawer = false
    private var resizeGrabOffset: CGSize = .zero

    /// The grip sits at the bottom center, safely away from the physical
    /// MacBook notch and the resize corner. Pulling an attached drawer first
    /// morphs its silhouette; only after the threshold does the window follow
    /// the pointer. A floating drawer follows immediately.
    private func handlePanelDragEvent(_ event: NSEvent, panel: NotchPanel) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard panel === activeDrawerPanel,
                  (isExpanded || floatingPanel === panel),
                  let drawerState = activeDrawerState,
                  panelDragHandleRect(for: panel).contains(NSEvent.mouseLocation),
                  !isResizingDrawer,
                  !isDockingPanel else {
                return false
            }

            if floatingPanel === panel, event.clickCount >= 2 {
                panelDragSession = nil
                drawerState.isBeingDragged = false
                let screen = screen(containing: NSEvent.mouseLocation) ?? panel.screen ?? currentScreen
                if let screen {
                    dockFloatingPanel(to: screen)
                }
                return true
            }

            // Once detached, AppKit's native background dragging owns the
            // movement from the handle as well as other non-control regions.
            // Polling observes the resulting frame and drives edge-based
            // docking feedback without fighting the system drag session.
            if floatingPanel === panel {
                return false
            }

            cancelCollapse()
            drawerState.isBeingDragged = true
            panelDragSession = PanelDragSession(
                panel: panel,
                drawerState: drawerState,
                startMouseLocation: NSEvent.mouseLocation,
                startPanelFrame: panel.frame,
                sourceScreenID: drawerScreen?.uniqueID,
                isDetached: floatingPanel === panel,
                dockingScreenID: nil
            )
            return true

        case .leftMouseDragged:
            guard var session = panelDragSession, session.panel === panel else { return false }
            let mouseLocation = NSEvent.mouseLocation
            let delta = CGSize(
                width: mouseLocation.x - session.startMouseLocation.x,
                height: mouseLocation.y - session.startMouseLocation.y
            )

            if !session.isDetached {
                let pullDistance = max(0, -delta.height)
                session.drawerState.detachmentProgress = min(
                    pullDistance / Self.detachmentThreshold,
                    1
                )
                if pullDistance < Self.detachmentThreshold {
                    panelDragSession = session
                    return true
                }
                beginFloatingPanel(using: &session)
                guard session.isDetached else {
                    panelDragSession = session
                    return true
                }
            }

            moveFloatingPanel(using: &session, delta: delta)
            panelDragSession = session
            return true

        case .leftMouseUp:
            guard let session = panelDragSession, session.panel === panel else { return false }
            panelDragSession = nil
            session.drawerState.isBeingDragged = false

            if session.isDetached,
               let screenID = session.dockingScreenID,
               let screen = NSScreen.screens.first(where: { $0.uniqueID == screenID }) {
                dockFloatingPanel(to: screen)
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    session.drawerState.detachmentProgress = session.isDetached ? 1 : 0
                    session.drawerState.isDockingTargeted = false
                }
            }
            return true

        default:
            return false
        }
    }

    private var activeDrawerState: DrawerState? {
        if let floatingDrawerState { return floatingDrawerState }
        guard let key = drawerScreen?.uniqueID else { return nil }
        return drawerStates[key]
    }

    private func panelDragHandleRect(for panel: NotchPanel) -> NSRect {
        return NSRect(
            x: panel.frame.midX - 36,
            y: panel.frame.minY + 1,
            width: 72,
            height: 18
        )
    }

    private func beginFloatingPanel(using session: inout PanelDragSession) {
        guard !session.isDetached,
              let sourceScreenID = session.sourceScreenID,
              let host = activeHostingView else {
            return
        }

        displayPanelRegistry.removeDrawerPanel(for: sourceScreenID)
        displayPanelRegistry.removeDrawerHostingView(for: sourceScreenID)
        drawerStates.removeValue(forKey: sourceScreenID)

        isExpanded = false
        isRevealedForFileDrag = false
        drawerScreen = nil
        floatingPanel = session.panel
        floatingHostingView = host
        floatingDrawerState = session.drawerState
        session.isDetached = true

        session.panel.hasShadow = true
        session.panel.level = .statusBar
        session.panel.isMovable = true
        session.panel.isMovableByWindowBackground = true
        showAllHotPanels()
        session.panel.orderFrontRegardless()

        withAnimation(.spring(response: 0.24, dampingFraction: 0.80)) {
            session.drawerState.isDetached = true
            session.drawerState.detachmentProgress = 1
        }
    }

    private func moveFloatingPanel(
        using session: inout PanelDragSession,
        delta: CGSize
    ) {
        var frame = session.startPanelFrame.offsetBy(dx: delta.width, dy: delta.height)
        let dockingScreen = dockingTargetScreen(for: frame)
        session.dockingScreenID = dockingScreen?.uniqueID

        let isTargeted = dockingScreen != nil
        if session.drawerState.isDockingTargeted != isTargeted {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                session.drawerState.isDockingTargeted = isTargeted
            }
        }

        if let dockingScreen {
            let layout = drawerLayout(for: dockingScreen, size: nil)
            let target = drawerFrame(for: layout, screen: dockingScreen)
            let magnetism: CGFloat = 0.22
            frame.origin.x += (target.origin.x - frame.origin.x) * magnetism
            frame.origin.y += (target.origin.y - frame.origin.y) * magnetism
        }

        session.panel.setFrame(frame, display: true)
        session.panel.orderFrontRegardless()
    }

    /// A panel docks when any part of its top border enters the target band
    /// around a display's notch. This intentionally uses the window boundary,
    /// not the cursor or drag-handle position, so every drag surface behaves
    /// consistently.
    private func dockingTargetScreen(for panelFrame: NSRect) -> NSScreen? {
        let panelTopBoundary = NSRect(
            x: panelFrame.minX,
            y: panelFrame.maxY - 2,
            width: panelFrame.width,
            height: 4
        )

        return NSScreen.screens.first { screen in
            let layout = drawerLayout(for: screen, size: nil)
            let targetWidth = max(layout.compactSize.width + 72, 240)
            let targetRect = NSRect(
                x: screen.frame.midX - targetWidth / 2,
                y: screen.frame.maxY - 34,
                width: targetWidth,
                height: 42
            )
            return targetRect.intersects(panelTopBoundary)
        }
    }

    /// Observes AppKit's native `isMovableByWindowBackground` movement. The
    /// frame only changes when a non-control background region actually began
    /// a window drag, so editor selection and button clicks are left alone.
    private func updateFloatingBackgroundDrag() {
        guard let panel = floatingPanel,
              let drawerState = floatingDrawerState,
              panelDragSession == nil,
              !isResizingDrawer,
              !isDockingPanel else {
            backgroundDragLastFrame = floatingPanel?.frame
            return
        }

        let frame = panel.frame
        if Self.isLeftMouseButtonDown {
            if let lastFrame = backgroundDragLastFrame, lastFrame != frame {
                if !isDraggingFloatingPanelBackground {
                    isDraggingFloatingPanelBackground = true
                    drawerState.isBeingDragged = true
                }

                let dockingScreen = dockingTargetScreen(for: frame)
                let isTargeted = dockingScreen != nil
                if drawerState.isDockingTargeted != isTargeted {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                        drawerState.isDockingTargeted = isTargeted
                    }
                }
            }
            backgroundDragLastFrame = frame
            return
        }

        backgroundDragLastFrame = nil
        guard isDraggingFloatingPanelBackground else { return }
        isDraggingFloatingPanelBackground = false
        drawerState.isBeingDragged = false

        if let screen = dockingTargetScreen(for: panel.frame) {
            dockFloatingPanel(to: screen)
        } else {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                drawerState.isDockingTargeted = false
            }
            currentScreen = panel.screen ?? currentScreen
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func dockFloatingPanel(to screen: NSScreen) {
        guard let panel = floatingPanel,
              let host = floatingHostingView,
              let drawerState = floatingDrawerState else {
            return
        }

        let key = screen.uniqueID
        if let replacedPanel = displayPanelRegistry.drawerPanel(for: key), replacedPanel !== panel {
            replacedPanel.orderOut(nil)
            displayPanelRegistry.removeDrawerPanel(for: key)
            displayPanelRegistry.removeDrawerHostingView(for: key)
            drawerStates.removeValue(forKey: key)
        }

        // The panel is joining this display's registry with the state it
        // already had; registering first is what lets the shared publisher
        // below find it, so the layout it gets is this display's.
        displayPanelRegistry.setDrawerPanel(panel, for: key)
        displayPanelRegistry.setDrawerHostingView(host, for: key)
        drawerStates[key] = drawerState
        let layout = applyLayout(to: screen)

        floatingPanel = nil
        floatingHostingView = nil
        floatingDrawerState = nil
        backgroundDragLastFrame = nil
        isDraggingFloatingPanelBackground = false
        isExpanded = true
        isDockingPanel = true
        drawerScreen = screen
        currentScreen = screen
        activeDrawerPanel = panel
        activeHostingView = host
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        drawerState.isExpanded = true
        drawerState.revealProgress = 1
        drawerState.isBeingDragged = false

        showAllHotPanels()
        hotPanelForScreen(screen)?.orderOut(nil)
        panel.orderFrontRegardless()

        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            drawerState.isDockingTargeted = false
            drawerState.isDetached = false
            drawerState.detachmentProgress = 0
        }

        let targetFrame = drawerFrame(for: layout, screen: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.30
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel else { return }
                panel.hasShadow = false
                self.isDockingPanel = false
                self.editorInteractionState.requestLayoutRefresh(searchingIn: self.activeHostingView)
            }
        }
    }

    /// Bottom-right hot zone of the drawer panel, in screen coordinates.
    ///
    /// The grip's own metrics decide it (see `ResizeGripMetrics.grabRect`), so
    /// the zone cannot drift from the corner it grabs. It used to be a fixed
    /// `48 x 44` measured from the frame's right edge by a comment that assumed
    /// the default 10pt radius — at the 25pt radius this drawer runs, a fifth of
    /// it lay under the inner panel, and a click there started a resize instead
    /// of reaching what looked like the panel.
    private var drawerGripRect: NSRect {
        guard let panel = activeDrawerPanel else { return .zero }
        return ResizeGripMetrics.grabRect(
            in: panel.frame,
            sideInset: drawerPanelSideInset,
            contentBottomInset: DrawerMetrics.contentBottomPadding
        )
    }

    /// How far the panel being resized insets its silhouette inside its frame
    /// right now: the user's top-corner radius while docked, and nothing once the
    /// drawer floats, because the detach morph has given the inset back.
    private var drawerPanelSideInset: CGFloat {
        guard let panel = activeDrawerPanel else { return 0 }

        let progress: CGFloat
        if panel === floatingPanel {
            progress = floatingDrawerState?.detachmentProgress ?? 1
        } else {
            progress = drawerScreen.flatMap { drawerStates[$0.uniqueID] }?
                .detachmentProgress ?? 0
        }

        return DrawerMetrics.panelSideInset(
            topCornerRadius: CGFloat(settingsStore.expandedTopCornerRadius),
            detachmentProgress: progress
        )
    }

    /// Panel-level resize handling.
    ///
    /// This is deliberately *not* a SwiftUI gesture. It used to be forced out
    /// here because a resize rebuilt the view tree and that corrupted a
    /// `DragGesture`'s translation mid-drag; that reason is gone now that a
    /// resize only publishes a layout, and moving the grip into SwiftUI is a
    /// change worth making on its own terms rather than as a side effect of
    /// this one.
    private func handleResizeMouseEvent(_ event: NSEvent) -> Bool {
        guard (isExpanded || floatingPanel != nil), !isDockingPanel else {
            isResizingDrawer = false
            return false
        }

        switch event.type {
        case .leftMouseDown:
            let mouse = NSEvent.mouseLocation
            guard drawerGripRect.contains(mouse), let panel = activeDrawerPanel else { return false }
            isResizingDrawer = true
            let frame = panel.frame
            resizeGrabOffset = CGSize(width: frame.maxX - mouse.x, height: mouse.y - frame.minY)
            return true

        case .leftMouseDragged where isResizingDrawer:
            resizeDrawer(to: NSEvent.mouseLocation)
            return true

        case .leftMouseUp where isResizingDrawer:
            isResizingDrawer = false
            finishDrawerResize()
            return true

        default:
            return false
        }
    }

    /// Commits a finished resize.
    ///
    /// The drag itself only moves the layout (see `resizeDrawer`); persisting
    /// the size is this once-per-gesture step, so the preference is written
    /// when the user stops rather than on every drag tick. The editor's layout
    /// is refreshed here for the same reason: its text re-wraps against the
    /// width the drawer ended at, and a resize that never ends has no width
    /// worth re-wrapping for.
    ///
    /// What is committed is the *decided* geometry — the layout's expanded size —
    /// not the size read back from the window. The layout is the value every
    /// consumer derives from, so committing it makes the preference write a
    /// no-op for the layout already on screen (`applyLayout`'s equality guard),
    /// where committing `panel.frame.size` would persist whatever AppKit made of
    /// the frame and then derive a *different* layout from it.
    private func finishDrawerResize() {
        guard let panel = activeDrawerPanel else { return }
        settingsStore.customExpandedSize = activeDrawerState?.layout.expandedSize ?? panel.frame.size
        editorInteractionState.requestLayoutRefresh(searchingIn: activeHostingView)
    }

    private func resizeDrawer(to mouse: NSPoint) {
        guard let panel = activeDrawerPanel,
              let screen = panel.screen,
              let state = activeDrawerState else { return }
        let frame = panel.frame

        // Keep the grabbed point under the mouse. The panel stays horizontally
        // centered while attached; a floating panel keeps its left and top
        // edges fixed like a conventional bottom-right window resize.
        let targetRightEdge = mouse.x + resizeGrabOffset.width
        let targetBottomEdge = mouse.y - resizeGrabOffset.height
        let proposedWidth = floatingPanel == nil
            ? (targetRightEdge - screen.frame.midX) * 2
            : targetRightEdge - frame.minX
        let proposed = CGSize(
            width: proposedWidth,
            height: frame.maxY - targetBottomEdge
        )

        // Route through NotchGeometry so the panel frame always matches the layout
        // (including screen-edge clamping) — a mismatch shifts the collapse animation off-center
        let layout = applyLayout(drawerLayout(for: screen, size: proposed), to: state)
        let size = layout.expandedSize
        guard size != frame.size else { return }

        let newX = floatingPanel == nil ? screen.frame.midX - size.width / 2 : frame.minX
        let newY = frame.maxY - size.height
        panel.setFrame(NSRect(x: newX, y: newY, width: size.width, height: size.height), display: true)
    }

    func openSettings() {
        cancelCollapse()
        if isExpanded {
            collapse(animated: true)
        }
        settingsWindowController.show()
    }

    private func hotFrame(for layout: NotchLayout, screen: NSScreen?) -> NSRect {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return frame(for: layout.compactSize, topY: screenFrame.maxY + layout.compactTopOffset, in: screenFrame)
    }

    /// Extended drop target below the compact notch, so an approaching file
    /// drag reveals the drawer before the cursor reaches the tiny notch area.
    private func fileDropFrame(for layout: NotchLayout, screen: NSScreen?) -> NSRect {
        var frame = hotFrame(for: layout, screen: screen)
        frame.origin.y -= 28
        frame.size.height += 28
        return frame
    }

    private var lastLoggedDragActive = false

    private func isFileDragInProgress() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        let isButtonDown = Self.isLeftMouseButtonDown
        let isActive = fileDragTrackingState.isFileDragInProgress(
            isLeftMouseButtonDown: isButtonDown,
            pasteboard: pasteboard
        )
        if isActive != lastLoggedDragActive {
            lastLoggedDragActive = isActive
            FileDragDiagnostics.log(
                """
                dragActive=\(isActive) buttonDown=\(isButtonDown) \
                dragCC=\(pasteboard.changeCount) \
                hasFileURL=\(FileDropPasteboardReader.containsFileURLs(pasteboard))
                """
            )
        }
        return isActive
    }

    /// Whether the left mouse button is down, sampled from the session event
    /// state in addition to the physical button.
    ///
    /// `NSEvent.pressedMouseButtons` reports the physical HID button, which
    /// never goes down for gestures such as three-finger drag or
    /// tap-and-drag: the system synthesizes the mouse events without a
    /// physical press, so a drag driven that way was invisible to the file
    /// drag detector and every feature gated on it silently did nothing.
    /// The combined session state follows the synthesized events, so it
    /// recognises every gesture. Both are read live, so the state can never
    /// go stale and pin the drawer open.
    private static var isLeftMouseButtonDown: Bool {
        NSEvent.pressedMouseButtons & 1 == 1
            || CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    private func drawerFrame(for layout: NotchLayout, screen: NSScreen?) -> NSRect {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topY = screenFrame.maxY + layout.expandedTopOffset
        return frame(for: layout.expandedSize, topY: topY, in: screenFrame)
    }

    private func frame(for size: NSSize, topY: CGFloat, in screenFrame: NSRect) -> NSRect {
        let x = screenFrame.midX - size.width / 2
        let y = topY - size.height

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

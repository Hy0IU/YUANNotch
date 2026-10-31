import AppKit
import SwiftUI

// YUANNotch · notebook toolbar probe
//
// Measures the tab pager at the width the drawer really gives it. The probe is
// compiled together with the shipping toolbar — NotebookToolbar.swift,
// TabPagerControl.swift, DrawerModeToggle.swift, HorizontalWheelScroll.swift and
// NotebookToolbarLayout (NotchGeometry.swift) — so the widths, the squeeze and
// the wheel under test are the ones the app runs, not a second implementation.
//
// Why it exists: the strip used to be the row's only flexible item, so a row that
// ran out of space shrank the strip's *frame* while its dots kept their rigid
// 26pt slots and painted outside it — over the minus/plus buttons and the mode
// toggle. At the default 480pt drawer the row could hold three tabs, and a
// notebook with eight drew dots from x = −37pt onwards.
//
// Checks:
//   1. arithmetic: for every interface text size, drawer width and 1...40 tabs, the
//      pager's chrome plus its strip plus everything to its right adds up to no
//      more than the width it is given, and the strip is never narrower than one
//      dot — so a row can always show at least one tab and can never overrun.
//   2. rendered (real views): the strip's own NSView is exactly as wide as
//      NotebookToolbarLayout says — a squeeze would make it narrower — it sits
//      where the pager's chrome puts it, and the pager, the mode toggle, "Clear"
//      and the settings button do not intersect one another at any tab count.
//   3. rendered: at every interface text size, the widths NotebookToolbarLayout
//      reserves for the mode toggle cover every labelled and icon-only selection.
//   4. the wheel: one notch slides the strip exactly one dot, the ends clamp, and
//      the offset is reported back so the SwiftUI side stays in step.
//   5. reveal: switching tabs slides the strip only as far as the selected dot
//      needs, and never past either end.
//
// It writes nothing and needs no permissions.

// The toolbar talks to the notebook through a handful of members that come from
// types pulling the whole app in behind them, so the probe declares those
// members instead of compiling those files — the same trade Scripts/
// reminders-v1-probe.sh makes with AppleRemindersService.

struct NoteTab: Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var createdAt = Date()
    var selectionLocation: Int? = 0
    var selectionLength: Int? = 0
}

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var tabs: [NoteTab]
    @Published private(set) var activeTabID: UUID

    init(tabCount: Int) {
        let tabs = (0 ..< max(tabCount, 1)).map { _ in NoteTab() }
        self.tabs = tabs
        activeTabID = tabs[0].id
    }

    func addTab() {
        let tab = NoteTab()
        tabs.append(tab)
        activeTabID = tab.id
    }

    func removeActiveTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        tabs.remove(at: index)
        activeTabID = tabs[min(index, tabs.count - 1)].id
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    func updateSelection(for id: UUID, range: NSRange) {}
    func clear() {}
}

@MainActor
final class EditorInteractionState {
    func currentSelectionRange() -> NSRange? { nil }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var drawerMode: DrawerMode = .notes
}

@MainActor
final class NotebookWorkspaceState: ObservableObject {
    @Published var fileDragForcesNotesMode = false
}

// MARK: - Harness

private let rowSpace = "probe.toolbar"

@MainActor
enum Recorded {
    static var frames: [String: CGRect] = [:]
    static func reset() { frames.removeAll() }
}

/// Records where a child of the probe's copy of the row ended up. The row itself
/// is compiled, not copied, but its children cannot be measured from outside
/// SwiftUI — this is how script 1's "no two parts intersect" is observed.
private struct Measured<Content: View>: View {
    let name: String
    @ViewBuilder var content: Content

    var body: some View {
        content.background(
            GeometryReader { proxy in
                let rect = proxy.frame(in: .named(rowSpace))
                let _ = { Recorded.frames[name] = rect }()
                Color.clear
            }
        )
    }
}

private struct ProbeIconButton: View {
    let systemName: String

    var body: some View {
        Button {} label: {
            Image(systemName: systemName)
                .frame(width: NotebookToolbarLayout.iconButton, height: NotebookToolbarLayout.iconButton)
        }
        .buttonStyle(DarkIconButtonStyle())
    }
}

@MainActor
private func host<V: View>(
    _ view: V,
    width: CGFloat,
    typography: AppTypography = AppTypography()
) -> NSHostingView<AnyView> {
    let height = DrawerMetrics.toolbarHeight
    let root = AnyView(
        view
            .environment(\.appTypography, typography)
            .frame(width: width, height: height)
            .coordinateSpace(name: rowSpace)
    )
    let hostingView = NSHostingView(rootView: root)
    hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)

    let window = NSWindow(
        contentRect: hostingView.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
    hostingView.displayIfNeeded()
    return hostingView
}

/// The strip's own NSView, found the only way it can be: it is the single part of
/// the row that is AppKit rather than SwiftUI.
@MainActor
private func firstStrip(in view: NSView) -> WheelDrivenScrollView? {
    if let strip = view as? WheelDrivenScrollView { return strip }
    for subview in view.subviews {
        if let strip = firstStrip(in: subview) { return strip }
    }
    return nil
}

/// The strip's frame in row coordinates, with the origin at the row's top-left.
@MainActor
private func stripFrame(in hostingView: NSHostingView<AnyView>) -> CGRect? {
    guard let strip = firstStrip(in: hostingView) else { return nil }
    let rect = strip.convert(strip.bounds, to: hostingView)
    let top = hostingView.isFlipped ? rect.minY : hostingView.bounds.height - rect.maxY
    return CGRect(x: rect.minX, y: top, width: rect.width, height: rect.height)
}

private func fmt(_ value: CGFloat) -> String {
    String(format: "%.2f", value)
}

private func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 0.5) -> Bool {
    inner.minX >= outer.minX - tolerance
        && inner.maxX <= outer.maxX + tolerance
        && inner.minY >= outer.minY - tolerance
        && inner.maxY <= outer.maxY + tolerance
}

@MainActor
private var failures = 0

@MainActor
private func check(_ label: String, _ passed: Bool, _ detail: String) {
    print("\(passed ? "PASS" : "FAIL")  \(label)")
    print("      \(detail)")
    if !passed { failures += 1 }
}

// MARK: - What the drawer can be

/// The toolbar's width is the drawer's less the panel's side padding: the shape's
/// own side inset (the top-corner radius) plus `contentSideMargin`, which is 16
/// attached and 18 detached. The three cases below cover the radius extremes.
private struct DrawerCase {
    let label: String
    let width: CGFloat
}

private let drawerCases: [DrawerCase] = [
    DrawerCase(label: "shortest 360, radius 10", width: 360 - 52),
    DrawerCase(label: "shortest 360, radius 25", width: 360 - 82),
    DrawerCase(label: "default 480, radius 10", width: 480 - 52),
    DrawerCase(label: "default 480, detached", width: 480 - 36),
    DrawerCase(label: "widest 540, radius 10", width: 540 - 52),
    DrawerCase(label: "wide 1200, radius 10", width: 1200 - 52)
]

private let interfaceSizes = InterfaceTextSize.allCases

// MARK: - 1 · Arithmetic

@MainActor
private func checkArithmetic() {
    print("— 1 · every width and tab count adds up —")

    var worstStrip = CGFloat.greatestFiniteMagnitude
    var slack: CGFloat = .greatestFiniteMagnitude
    var firstBad = ""

    for interfaceSize in interfaceSizes {
        let typography = AppTypography(interfaceSize: interfaceSize)
        for drawer in drawerCases {
            for tabCount in 1 ... 40 {
                let layout = NotebookToolbarLayout(width: drawer.width, mode: .notes, typography: typography)
                let strip = layout.stripWidth(tabCount: tabCount)
                let reserve = NotebookToolbarLayout.trailingReserve(
                    showsClearButton: true,
                    showsModeToggleLabels: layout.showsModeToggleLabels,
                    typography: typography,
                    showsModeMenu: layout.showsModeMenu
                )
                let total = NotebookToolbarLayout.pagerChrome + strip + reserve
                let ideal = NotebookToolbarLayout.stripContentWidth(tabCount: tabCount)

                if strip > ideal + 0.001 || strip < 0 {
                    firstBad = "\(interfaceSize.title), \(drawer.label), \(tabCount) tabs: strip \(fmt(strip)) outside 0...\(fmt(ideal))"
                }
                if total > drawer.width + 0.001 {
                    firstBad = "\(interfaceSize.title), \(drawer.label), \(tabCount) tabs: parts add to \(fmt(total)) > \(fmt(drawer.width))"
                }
                if strip < NotebookToolbarLayout.dotSlot {
                    firstBad = "\(interfaceSize.title), \(drawer.label), \(tabCount) tabs: strip \(fmt(strip)) < one dot"
                }

                // The reveal rule must leave the selected dot's slot inside the view.
                let viewport = strip
                let content = ideal
                let limit = layout.maximumScrollOffset(tabCount: tabCount)
                var offset: CGFloat = 0
                for index in [0, tabCount - 1, tabCount / 2, 0, tabCount - 1] {
                    offset = layout.scrollOffset(keepingVisible: index, currentOffset: offset, tabCount: tabCount)
                    let slot = CGRect(
                        x: CGFloat(index) * NotebookToolbarLayout.dotStride,
                        y: 0,
                        width: NotebookToolbarLayout.dotSlot,
                        height: 1
                    )
                    let visible = CGRect(x: offset, y: 0, width: viewport, height: 1)
                    if offset < -0.001 || offset > limit + 0.001 {
                        firstBad = "\(interfaceSize.title), \(drawer.label), \(tabCount) tabs: offset \(fmt(offset)) outside 0...\(fmt(limit))"
                    }
                    if content > viewport, !contains(visible, slot, tolerance: 1) {
                        firstBad = "\(interfaceSize.title), \(drawer.label), \(tabCount) tabs: dot \(index) at \(fmt(slot.minX)) not inside \(fmt(offset))...\(fmt(offset + viewport))"
                    }
                }

                worstStrip = min(worstStrip, strip)
                slack = min(slack, drawer.width - total)
            }
        }
    }

    check(
        "the row's parts never exceed the width it is given",
        firstBad.isEmpty,
        firstBad.isEmpty
            ? "3 interface sizes x 6 drawer cases x 40 tab counts: least slack \(fmt(slack))pt, narrowest strip \(fmt(worstStrip))pt (one dot needs \(fmt(NotebookToolbarLayout.dotSlot))pt)"
            : firstBad
    )

    // Non-notes surfaces have no pager and no "Clear": the toggle and settings
    // button must fit, falling back to icons if a future label grows too wide.
    var standaloneBad = ""
    for interfaceSize in interfaceSizes {
        let typography = AppTypography(interfaceSize: interfaceSize)
        for drawer in drawerCases {
            for mode in [DrawerMode.reminders, .schedule, .plans] {
                let layout = NotebookToolbarLayout(width: drawer.width, mode: mode, typography: typography)
                let toggle = layout.showsModeToggleLabels
                    ? NotebookToolbarLayout.labelledModeToggleWidth(for: typography)
                    : NotebookToolbarLayout.modeToggleIconWidth
                let total = NotebookToolbarLayout.itemSpacing
                    + toggle
                    + NotebookToolbarLayout.itemSpacing
                    + NotebookToolbarLayout.iconButton
                if total > drawer.width + 0.001 {
                    standaloneBad = "\(interfaceSize.title), \(drawer.label), \(mode.title): toggle + settings = \(fmt(total)) of \(fmt(drawer.width))"
                }
            }
        }
    }
    check(
        "standalone mode rows fit every drawer width",
        standaloneBad.isEmpty,
        standaloneBad.isEmpty
            ? "3 interface sizes x 6 drawer cases x 3 modes: toggle and settings stay inside the row"
            : standaloneBad
    )
}

// MARK: - 2 · The rendered row

@MainActor
private func checkRenderedRow() {
    print("")
    print("— 2 · the real toolbar, measured —")

    var badSqueeze = ""
    var badPlacement = ""
    var badOverlap = ""
    var rowChecked = 0
    var standaloneChecked = 0

    for drawer in drawerCases {
        for tabCount in [1, 2, 3, 4, 6, 10, 24, 40] {
            let layout = NotebookToolbarLayout(width: drawer.width, mode: .notes)
            let expectedStrip = layout.stripWidth(tabCount: tabCount)
            let store = NoteStore(tabCount: tabCount)
            let settings = AppSettingsStore()
            let workspace = NotebookWorkspaceState()
            let interaction = EditorInteractionState()

            // The shipping row.
            let realHost = host(
                NotebookToolbar(
                    store: store,
                    settingsStore: settings,
                    workspaceState: workspace,
                    editorInteractionState: interaction,
                    layout: layout,
                    onOpenSettings: {}
                ),
                width: drawer.width
            )
            let realStrip = withExtendedLifetime(realHost) { stripFrame(in: realHost) }
            guard let realStrip else {
                badSqueeze = "\(drawer.label), \(tabCount) tabs: the strip's view is missing"
                continue
            }

            // A row assembled from the same real parts, so every child's frame can
            // be read. Its strip has to land where the real row's did, or the
            // assembly is not the row.
            Recorded.reset()
            let probeHost = host(
                ProbeRow(store: store, layout: layout, interaction: interaction),
                width: drawer.width
            )
            let probeStrip = withExtendedLifetime(probeHost) { stripFrame(in: probeHost) }
            let frames = Recorded.frames
            rowChecked += 1

            guard let probeStrip, let pager = frames["pager"] else {
                badSqueeze = "\(drawer.label), \(tabCount) tabs: the probe's row did not lay out"
                continue
            }
            if abs(probeStrip.minX - realStrip.minX) > 0.5 || abs(probeStrip.width - realStrip.width) > 0.5 {
                badPlacement = """
                    \(drawer.label), \(tabCount) tabs: the probe's strip is at \
                    \(fmt(probeStrip.minX))/\(fmt(probeStrip.width)) but the row's is at \
                    \(fmt(realStrip.minX))/\(fmt(realStrip.width))
                    """
            }

            // The strip's width is what the layout asked for — a squeezed frame
            // was the original bug.
            if abs(realStrip.width - expectedStrip) > 0.5 {
                badSqueeze = """
                    \(drawer.label), \(tabCount) tabs: strip is \(fmt(realStrip.width))pt wide, \
                    the layout asked for \(fmt(expectedStrip))pt
                    """
            }

            // The pager's own chrome: 2pt of pill padding, the minus button, then
            // the gap before the strip.
            let expectedStripX: CGFloat = 2 + NotebookToolbarLayout.iconButton + 6
            if abs(realStrip.minX - expectedStripX) > 0.5 {
                badPlacement = """
                    \(drawer.label), \(tabCount) tabs: strip starts at \(fmt(realStrip.minX)), \
                    the pager's chrome puts it at \(fmt(expectedStripX))
                    """
            }
            if !contains(pager, realStrip, tolerance: 0.5) {
                badOverlap = """
                    \(drawer.label), \(tabCount) tabs: the strip \(fmt(realStrip.minX))...\
                    \(fmt(realStrip.maxX)) leaves the pager \(fmt(pager.minX))...\(fmt(pager.maxX))
                    """
            }

            // Nothing drawn in the row may sit on anything else.
            let parts = ["pager", "modeToggle", "clear", "settings"].compactMap { name -> (String, CGRect)? in
                frames[name].map { (name, $0) }
            }
            for i in parts.indices {
                for j in parts.indices where j > i {
                    let hit = parts[i].1.intersection(parts[j].1)
                    if !hit.isNull, hit.width > 0.5, hit.height > 0.5 {
                        badOverlap = """
                            \(drawer.label), \(tabCount) tabs: \(parts[i].0) and \(parts[j].0) overlap \
                            by \(fmt(hit.width))pt at x = \(fmt(hit.minX))
                            """
                    }
                }
            }
            for (name, rect) in parts where rect.maxX > drawer.width + 0.5 {
                badOverlap = """
                    \(drawer.label), \(tabCount) tabs: \(name) ends at \(fmt(rect.maxX)), \
                    past the row's \(fmt(drawer.width))
                    """
            }
        }
    }

    for drawer in drawerCases {
        for mode in [DrawerMode.reminders, .schedule, .plans] {
            let layout = NotebookToolbarLayout(width: drawer.width, mode: mode)
            Recorded.reset()
            let store = NoteStore(tabCount: 1)
            let interaction = EditorInteractionState()
            let probeHost = host(
                ProbeRow(store: store, layout: layout, interaction: interaction),
                width: drawer.width
            )
            withExtendedLifetime(probeHost) { probeHost.layoutSubtreeIfNeeded() }
            let frames = Recorded.frames
            standaloneChecked += 1

            if frames["pager"] != nil || frames["clear"] != nil {
                badOverlap = "\(drawer.label), \(mode.title): a notes-only control was rendered"
            }
            guard let toggle = frames["modeToggle"], let settings = frames["settings"] else {
                badOverlap = "\(drawer.label), \(mode.title): toggle or settings is missing"
                continue
            }
            let hit = toggle.intersection(settings)
            if (!hit.isNull && hit.width > 0.5) || settings.maxX > drawer.width + 0.5 {
                badOverlap = "\(drawer.label), \(mode.title): standalone controls overlap or leave the row"
            }
        }
    }

    check(
        "the strip is exactly as wide as the layout says",
        badSqueeze.isEmpty,
        badSqueeze.isEmpty ? "\(rowChecked) rendered rows: no strip frame was squeezed" : badSqueeze
    )
    check(
        "the strip sits inside the pager's own chrome",
        badPlacement.isEmpty,
        badPlacement.isEmpty ? "\(rowChecked) rendered rows: strip at x = 36, as the chrome puts it" : badPlacement
    )
    check(
        "no part of the row touches another",
        badOverlap.isEmpty,
        badOverlap.isEmpty
            ? "\(rowChecked) notes rows + \(standaloneChecked) standalone rows: every control is disjoint and inside the row"
            : badOverlap
    )
}

/// The row from NotebookToolbar.swift, assembled from the same real parts so that
/// each child can be measured. Check 2 fails if its strip does not land on the
/// real row's.
private struct ProbeRow: View {
    @ObservedObject var store: NoteStore
    let layout: NotebookToolbarLayout
    let interaction: EditorInteractionState

    var body: some View {
        HStack(alignment: .center, spacing: NotebookToolbarLayout.itemSpacing) {
            if layout.isNotesMode {
                Measured(name: "pager") {
                    TabPagerControl(store: store, editorInteractionState: interaction, layout: layout)
                }
            }

            Spacer(minLength: 0)

            Measured(name: "modeToggle") {
                DrawerModeToggle(
                    mode: layout.mode, showsLabels: layout.showsModeToggleLabels,
                    usesMenu: layout.showsModeMenu
                ) { _ in }
            }

            if layout.isNotesMode {
                Measured(name: "clear") { ProbeIconButton(systemName: "trash") }
            }
            Measured(name: "settings") { ProbeIconButton(systemName: "gearshape") }
        }
        .frame(height: DrawerMetrics.toolbarHeight, alignment: .center)
    }
}

/// Exercise the live row and the measured assembly at all three interface
/// scales. The standard path above keeps its exhaustive tab sweep; this pass
/// checks each size with a few tab counts, all drawer widths and all modes.
@MainActor
private func checkTypographyRows() {
    print("")
    print("— 2b · interface sizes keep rendered rows inside the drawer —")

    for interfaceSize in interfaceSizes {
        let typography = AppTypography(interfaceSize: interfaceSize)
        var failure = ""
        var rowsChecked = 0

        for drawer in drawerCases {
            for mode in DrawerMode.allCases {
                let tabCounts: [Int] = mode == .notes ? [1, 8, 40] : [1]
                for tabCount in tabCounts {
                    let layout = NotebookToolbarLayout(
                        width: drawer.width,
                        mode: mode,
                        typography: typography
                    )
                    let store = NoteStore(tabCount: tabCount)
                    let settings = AppSettingsStore()
                    let workspace = NotebookWorkspaceState()
                    let interaction = EditorInteractionState()

                    let liveHost = host(
                        NotebookToolbar(
                            store: store,
                            settingsStore: settings,
                            workspaceState: workspace,
                            editorInteractionState: interaction,
                            layout: layout,
                            onOpenSettings: {}
                        ),
                        width: drawer.width,
                        typography: typography
                    )

                    Recorded.reset()
                    let measuredHost = host(
                        ProbeRow(store: store, layout: layout, interaction: interaction),
                        width: drawer.width,
                        typography: typography
                    )
                    let frames = Recorded.frames
                    rowsChecked += 1

                    if mode == .notes {
                        guard let actualStrip = stripFrame(in: liveHost) else {
                            failure = "\(drawer.label), \(tabCount) tabs: the live strip is missing"
                            continue
                        }
                        let expectedStrip = layout.stripWidth(tabCount: tabCount)
                        if abs(actualStrip.width - expectedStrip) > 0.5 {
                            failure = "\(drawer.label), \(tabCount) tabs: live strip \(fmt(actualStrip.width))pt, expected \(fmt(expectedStrip))pt"
                        }
                    }

                    let parts = ["pager", "modeToggle", "clear", "settings"].compactMap { name -> (String, CGRect)? in
                        frames[name].map { (name, $0) }
                    }
                    for i in parts.indices {
                        for j in parts.indices where j > i {
                            let hit = parts[i].1.intersection(parts[j].1)
                            if !hit.isNull, hit.width > 0.5, hit.height > 0.5 {
                                failure = "\(drawer.label), \(mode.title), \(tabCount) tabs: \(parts[i].0) and \(parts[j].0) overlap by \(fmt(hit.width))pt"
                            }
                        }
                    }
                    for (name, rect) in parts where rect.minX < -0.5 || rect.maxX > drawer.width + 0.5 {
                        failure = "\(drawer.label), \(mode.title), \(tabCount) tabs: \(name) at \(fmt(rect.minX))...\(fmt(rect.maxX)) leaves the row"
                    }
                    for (name, rect) in parts where rect.minY < -0.5 || rect.maxY > DrawerMetrics.toolbarHeight + 0.5 {
                        failure = "\(drawer.label), \(mode.title), \(tabCount) tabs: \(name) reaches y=\(fmt(rect.minY))...\(fmt(rect.maxY)), outside the \(fmt(DrawerMetrics.toolbarHeight))pt toolbar"
                    }
                    if let toggle = frames["modeToggle"] {
                        let reserve = layout.showsModeMenu ? NotebookToolbarLayout.modeMenuWidth : (
                            layout.showsModeToggleLabels
                                ? NotebookToolbarLayout.labelledModeToggleWidth(for: typography)
                                : NotebookToolbarLayout.modeToggleIconWidth
                        )
                        if toggle.width > reserve + 0.5 {
                            failure = "\(drawer.label), \(mode.title), \(tabCount) tabs: toggle is \(fmt(toggle.width))pt, reserve is \(fmt(reserve))pt"
                        }
                    }

                    _ = liveHost
                    _ = measuredHost
                }
            }
        }

        check(
            "\(interfaceSize.title) toolbar rows stay inside and do not overlap",
            failure.isEmpty,
            failure.isEmpty ? "\(rowsChecked) rendered rows across 6 drawer widths and all modes" : failure
        )
    }
}

// MARK: - 3 · The toggle's real width

@MainActor
private func checkModeToggleWidths() {
    print("")
    print("— 3 · what the mode toggle actually costs —")
    let scale = NSScreen.main?.backingScaleFactor ?? -1
    print("    measured on \(NSScreen.screens.count) screen(s), backing scale \(fmt(scale))"
        + "")

    for interfaceSize in interfaceSizes {
        let typography = AppTypography(interfaceSize: interfaceSize)
        for showsLabels in [false, true] {
            let reserve = showsLabels
                ? NotebookToolbarLayout.labelledModeToggleWidth(for: typography)
                : NotebookToolbarLayout.modeToggleIconWidth

            var widest: CGFloat = -1
            var widestSelection = DrawerMode.notes
            for selection in DrawerMode.allCases {
                let hostedToggle = host(
                    Measured(name: "toggle") {
                        DrawerModeToggle(mode: selection, showsLabels: showsLabels) { _ in }
                    },
                    width: 600,
                    typography: typography
                )
                let measured = withExtendedLifetime(hostedToggle) { Recorded.frames["toggle"] }
                Recorded.reset()

                let width = measured?.width ?? -1
                if width > widest {
                    widest = width
                    widestSelection = selection
                }
            }

            // A reserve may have safe slack, but it must cover every rendered
            // selection at this interface size.
            let slack = reserve - widest
            check(
                "\(interfaceSize.title) \(showsLabels ? "labelled" : "icons only") reserve covers the toggle",
                slack >= -0.5,
                "widest \(fmt(widest))pt with \(widestSelection.title.lowercased()) selected, "
                    + "reserve \(fmt(reserve))pt, slack \(fmt(slack))pt"
            )
        }
    }
}

// MARK: - 4 · The wheel

@MainActor
private func sendWheel(to strip: WheelDrivenScrollView, notches: Int32) {
    guard let cgEvent = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 1,
        wheel1: notches,
        wheel2: 0,
        wheel3: 0
    ), let event = NSEvent(cgEvent: cgEvent) else { return }
    strip.scrollWheel(with: event)
}

@MainActor
private func checkWheel() {
    print("")
    print("— 4 · one wheel notch, one dot —")

    let tabCount = 12
    let content = NotebookToolbarLayout.stripContentWidth(tabCount: tabCount)
    let viewport: CGFloat = 100
    var offset: CGFloat = 0
    let binding = Binding(get: { offset }, set: { offset = $0 })

    let host = host(
        HorizontalWheelScroll(offset: binding, contentWidth: content, height: DrawerMetrics.toolbarHeight) {
            HStack(spacing: NotebookToolbarLayout.dotSpacing) {
                ForEach(0 ..< tabCount, id: \.self) { _ in
                    Color.white.opacity(0.3)
                        .frame(width: NotebookToolbarLayout.dotSlot, height: 6)
                        .frame(width: NotebookToolbarLayout.dotSlot, height: 24)
                }
            }
        }
        .frame(width: viewport, height: DrawerMetrics.toolbarHeight),
        width: viewport
    )

    guard let strip = firstStrip(in: host) else {
        check("the strip's scroller exists", false, "no WheelDrivenScrollView in the hosted pager")
        _ = host
        return
    }

    let documentWidth = strip.documentView?.frame.width ?? -1
    check(
        "the scroller's viewport is the strip's width",
        abs(strip.contentView.bounds.width - viewport) <= 0.5 && abs(documentWidth - content) <= 0.5,
        "clip view \(fmt(strip.contentView.bounds.width))pt wide, document \(fmt(documentWidth))pt for \(tabCount) dots"
    )

    let limit = max(content - viewport, 0)

    sendWheel(to: strip, notches: -1)
    check(
        "one notch slides one dot",
        abs(offset - NotebookToolbarLayout.dotStride) <= 0.5,
        "offset \(fmt(offset))pt, one dot is \(fmt(NotebookToolbarLayout.dotStride))pt"
    )
    check(
        "the wheel reports its position back",
        abs(strip.contentView.bounds.origin.x - offset) <= 0.5,
        "scroller at \(fmt(strip.contentView.bounds.origin.x))pt, SwiftUI holds \(fmt(offset))pt"
    )

    sendWheel(to: strip, notches: -1000)
    check(
        "the far end clamps",
        abs(offset - limit) <= 0.5 && abs(strip.contentView.bounds.origin.x - limit) <= 0.5,
        "offset \(fmt(offset))pt, the last dot's limit is \(fmt(limit))pt"
    )

    sendWheel(to: strip, notches: 1000)
    check(
        "the near end clamps",
        abs(offset) <= 0.5 && abs(strip.contentView.bounds.origin.x) <= 0.5,
        "offset \(fmt(offset))pt after scrolling back"
    )

    _ = host
}

// MARK: - 5 · Reveal

@MainActor
private func checkReveal() {
    print("")
    print("— 5 · revealing the selected dot —")

    let layout = NotebookToolbarLayout(width: 480 - 52, mode: .notes)
    let tabCount = 40
    let viewport = layout.stripWidth(tabCount: tabCount)

    var offset: CGFloat = 0
    offset = layout.scrollOffset(keepingVisible: tabCount - 1, currentOffset: offset, tabCount: tabCount)
    let lastSlot = CGFloat(tabCount - 1) * NotebookToolbarLayout.dotStride
    check(
        "switching to the last tab brings it into view",
        offset <= lastSlot + 0.5 && lastSlot + NotebookToolbarLayout.dotSlot <= offset + viewport + 0.5,
        "offset \(fmt(offset))pt, last dot at \(fmt(lastSlot))...\(fmt(lastSlot + NotebookToolbarLayout.dotSlot)), viewport \(fmt(offset))...\(fmt(offset + viewport))"
    )

    let beforeFirst = offset
    offset = layout.scrollOffset(keepingVisible: 0, currentOffset: offset, tabCount: tabCount)
    check(
        "switching back to the first tab returns to the start",
        abs(offset) <= 0.5 && beforeFirst > 0,
        "offset went from \(fmt(beforeFirst))pt back to \(fmt(offset))pt"
    )

    // A drawer resized narrow while a late tab is selected: the offset has to be
    // clamped into the new, smaller limit, and the selected dot has to survive it.
    let narrow = NotebookToolbarLayout(width: 360 - 52, mode: .notes)
    let narrowViewport = narrow.stripWidth(tabCount: tabCount)
    let narrowLimit = narrow.maximumScrollOffset(tabCount: tabCount)
    offset = layout.scrollOffset(keepingVisible: 20, currentOffset: 0, tabCount: tabCount)
    let clamped = narrow.scrollOffset(keepingVisible: 20, currentOffset: offset, tabCount: tabCount)
    let selectedSlot = CGRect(
        x: 20 * NotebookToolbarLayout.dotStride,
        y: 0,
        width: NotebookToolbarLayout.dotSlot,
        height: 1
    )
    let narrowVisible = CGRect(x: clamped, y: 0, width: narrowViewport, height: 1)
    check(
        "a narrower drawer clamps the offset and keeps the dot",
        clamped >= 0
            && clamped <= narrowLimit + 0.5
            && contains(narrowVisible, selectedSlot, tolerance: 1),
        "offset \(fmt(offset))pt clamped to \(fmt(clamped))pt in a \(fmt(narrowViewport))pt viewport (limit \(fmt(narrowLimit))pt), dot 20 at \(fmt(selectedSlot.minX))...\(fmt(selectedSlot.maxX))"
    )
}

// MARK: - Entry point

// A main.swift's top-level code is only main-actor isolated in Swift 6 language
// mode; the probe compiles under Swift 5, so it says so here.
MainActor.assumeIsolated {
    _ = NSApplication.shared

    print("=== YUANNotch · notebook toolbar probe ===")
    print("")
    checkArithmetic()
    checkRenderedRow()
    checkTypographyRows()
    checkModeToggleWidths()
    checkWheel()
    checkReveal()

    print("")
    print(failures == 0 ? "every check passed" : "\(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}

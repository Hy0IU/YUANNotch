import AppKit
import MarkdownEngine
import SwiftUI

@MainActor
final class DrawerState: ObservableObject {
    @Published var isExpanded = false
    @Published var revealProgress: CGFloat = 0
}

struct NotebookView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var settingsStore: AppSettingsStore
    let imageStore: LocalImageStore
    @ObservedObject var fileShelfStore: FileShelfStore
    @ObservedObject var workspaceState: NotebookWorkspaceState
    @ObservedObject var drawerState: DrawerState
    @ObservedObject var editorInteractionState: EditorInteractionState
    let layout: NotchLayout
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            drawer
        }
        // Fill the panel and center the drawer inside it, so the collapse
        // animation always converges to the panel's center even if the panel
        // frame and the layout size ever disagree
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dropDestination(for: URL.self) { urls, _ in
            guard settingsStore.isFileShelfEnabled, !workspaceState.isDraggingShelfItem else {
                workspaceState.isShelfDropTargeted = false
                return false
            }
            return receiveDroppedFiles(urls)
        } isTargeted: { isTargeted in
            withAnimation(shelfAnimation) {
                workspaceState.isShelfDropTargeted = settingsStore.isFileShelfEnabled
                    && isTargeted
                    && !workspaceState.isDraggingShelfItem
            }
        }
    }

    private var drawer: some View {
        ZStack(alignment: .top) {
            expandedContent
                .frame(width: layout.expandedSize.width, height: layout.expandedSize.height)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .opacity(expandedContentOpacity)

            compactIcon
        }
        .frame(width: layout.expandedSize.width, height: layout.expandedSize.height, alignment: .top)
        .background(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98))
        .mask(alignment: .top) {
            NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
                .frame(width: revealWidth, height: revealHeight)
        }
        .overlay(alignment: .top) {
            NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
                .stroke(.white.opacity(0.09), lineWidth: 1)
                .frame(width: revealWidth, height: revealHeight)
        }
        .contentShape(Rectangle())
        .allowsHitTesting(drawerState.isExpanded)
        .overlay(alignment: .bottomTrailing) {
            // Visual indicator only — dragging is handled at the panel level
            // (see NotchPanelController.handleResizeMouseEvent).
            // Trailing padding tracks the visible (inset) right edge of the shape.
            if drawerState.isExpanded {
                ResizeGrip()
                    .padding(.trailing, topCornerRadius + 8)
                    .padding(.bottom, 9)
            }
        }
    }

    private var expandedContent: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    TabPagerControl(store: store, editorInteractionState: editorInteractionState)

                    Spacer()

                    Button(action: store.clear) {
                        Image(systemName: "trash")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(DarkIconButtonStyle())
                    .help("Clear")

                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(DarkIconButtonStyle())
                    .help("Settings")
                }
                .frame(height: toolbarHeight, alignment: .center)

                VStack(spacing: shelfSpacing) {
                    MarkdownEditorPanel(
                        store: store,
                        imageStore: imageStore,
                        editorInteractionState: editorInteractionState,
                        size: editorSize
                    )
                    .frame(width: editorSize.width, height: editorSize.height)
                    .background(Color(red: 0.06, green: 0.06, blue: 0.07))

                    if isFileShelfVisible {
                        FileShelfView(
                            store: fileShelfStore,
                            workspaceState: workspaceState,
                            size: fileShelfSize
                        )
                        .frame(width: fileShelfSize.width, height: fileShelfSize.height)
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.97, anchor: .bottom))
                        )
                    }
                }
                .animation(shelfAnimation, value: isFileShelfVisible)
            }
        }
        .padding(.top, toolbarTopPadding)
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.bottom, contentBottomPadding)
        .onAppear {
            editorInteractionState.onSelectionChange = { [weak store] range in
                guard let store else { return }
                store.updateSelection(for: store.activeTabID, range: range)
            }
            editorInteractionState.restoreSelection(store.selectionRange(for: store.activeTabID))
        }
        .onChange(of: store.activeTabID) { _, newTabID in
            editorInteractionState.restoreSelection(store.selectionRange(for: newTabID))
            editorInteractionState.requestLayoutRefresh(resetScroll: false)
        }
        .onDisappear {
            workspaceState.isShelfDropTargeted = false
            workspaceState.isDraggingShelfItem = false
        }
    }

    private var compactIcon: some View {
        Image(systemName: "note.text")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.82))
            .frame(width: layout.compactSize.width, height: layout.compactSize.height)
            .opacity(1 - drawerState.revealProgress)
    }

    private var revealWidth: CGFloat {
        interpolate(from: layout.compactSize.width, to: layout.expandedSize.width)
    }

    private var revealHeight: CGFloat {
        interpolate(from: layout.compactSize.height, to: layout.expandedSize.height)
    }

    private var topCornerRadius: CGFloat {
        interpolate(from: 0, to: 10)
    }

    private var bottomCornerRadius: CGFloat {
        interpolate(from: 12, to: 20)
    }

    private var expandedContentOpacity: CGFloat {
        let progress = drawerState.revealProgress
        return min(max((progress - 0.42) / 0.34, 0), 1)
    }

    private var editorSize: CGSize {
        CGSize(
            width: layout.expandedSize.width - contentHorizontalPadding * 2,
            height: max(
                layout.expandedSize.height
                    - toolbarTopPadding
                    - contentBottomPadding
                    - toolbarHeight
                    - editorSpacing
                    - (isFileShelfVisible ? fileShelfHeight + shelfSpacing : 0),
                160
            )
        )
    }

    private var fileShelfSize: CGSize {
        CGSize(
            width: layout.expandedSize.width - contentHorizontalPadding * 2,
            height: fileShelfHeight
        )
    }

    private var fileShelfHeight: CGFloat {
        72
    }

    private var shelfSpacing: CGFloat {
        8
    }

    private var isFileShelfVisible: Bool {
        settingsStore.isFileShelfEnabled
            && (workspaceState.isShelfDropTargeted || !fileShelfStore.items.isEmpty)
    }

    private var shelfAnimation: Animation {
        .spring(response: 0.30, dampingFraction: 0.84)
    }

    private func receiveDroppedFiles(_ urls: [URL]) -> Bool {
        let didAcceptDrop = fileShelfStore.acceptDrop(urls)
        workspaceState.isShelfDropTargeted = false
        return didAcceptDrop
    }

    private var toolbarTopPadding: CGFloat {
        layout.compactSize.height + 6
    }

    private var contentHorizontalPadding: CGFloat {
        // The NotchShape insets both side edges by the expanded top corner
        // radius (10), so add it back to keep a comfortable visible margin
        26
    }

    private var contentBottomPadding: CGFloat {
        18
    }

    private var toolbarHeight: CGFloat {
        28
    }

    private var editorSpacing: CGFloat {
        12
    }

    private func interpolate(from start: CGFloat, to end: CGFloat) -> CGFloat {
        start + (end - start) * drawerState.revealProgress
    }
}

struct MarkdownEditorPanel: View {
    @ObservedObject var store: NoteStore
    let imageStore: LocalImageStore
    let editorInteractionState: EditorInteractionState
    let size: CGSize

    private let toolbarHeight: CGFloat = 34
    private let separatorHeight: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            MarkdownNoteEditor(
                store: store,
                imageStore: imageStore,
                editorInteractionState: editorInteractionState
            )
            .frame(width: size.width, height: editorHeight)

            Rectangle()
                .fill(.white.opacity(0.045))
                .frame(width: size.width, height: separatorHeight)

            MarkdownShortcutToolbar(editorInteractionState: editorInteractionState)
                .frame(width: size.width, height: toolbarHeight)
                .background(Color(red: 0.055, green: 0.055, blue: 0.065))
        }
    }

    private var editorHeight: CGFloat {
        max(size.height - toolbarHeight - separatorHeight, 120)
    }
}

struct MarkdownShortcutToolbar: View {
    let editorInteractionState: EditorInteractionState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MarkdownCommand.allCases) { command in
                Button {
                    editorInteractionState.applyMarkdownCommand(command)
                } label: {
                    MarkdownCommandLabel(command: command)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MarkdownToolbarButtonStyle())
                .help(command.help)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }
}

struct MarkdownCommandLabel: View {
    let command: MarkdownCommand

    var body: some View {
        switch command {
        case .bold:
            Image(systemName: "bold")
        case .italic:
            Image(systemName: "italic")
        case .strikethrough:
            Image(systemName: "strikethrough")
        case .inlineCode:
            Text("`")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
        case .link:
            Image(systemName: "link")
        case .quote:
            Image(systemName: "quote.opening")
        case .unorderedList:
            Image(systemName: "list.bullet")
        case .orderedList:
            Image(systemName: "list.number")
        case .todoList:
            Image(systemName: "checklist")
        }
    }
}

struct TabPagerControl: View {
    @ObservedObject var store: NoteStore
    let editorInteractionState: EditorInteractionState
    @Namespace private var tabAnimation

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button {
                rememberCurrentSelection()
                withAnimation(tabSwitchAnimation) {
                    store.removeActiveTab()
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabIconButtonStyle())
            .disabled(store.tabs.count <= 1)
            .help("Remove current tab")

            HStack(spacing: 6) {
                ForEach(store.tabs) { tab in
                    let isSelected = tab.id == store.activeTabID
                    Button {
                        rememberCurrentSelection()
                        withAnimation(tabSwitchAnimation) {
                            store.selectTab(tab.id)
                        }
                    } label: {
                        Capsule()
                            .fill(isSelected ? Color.white.opacity(0.82) : Color.white.opacity(0.34))
                            .frame(width: isSelected ? 20 : 6, height: 6)
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                            .matchedGeometryEffect(id: tab.id, in: tabAnimation)
                            .animation(tabSwitchAnimation, value: isSelected)
                    }
                    .buttonStyle(TabDotButtonStyle(isSelected: isSelected))
                    .help("Switch tab")
                }
            }
            .frame(minWidth: 20, alignment: .center)
            .frame(height: 28, alignment: .center)

            Button {
                rememberCurrentSelection()
                withAnimation(tabSwitchAnimation) {
                    store.addTab()
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
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
    }

    private var tabSwitchAnimation: Animation {
        .spring(response: 0.26, dampingFraction: 0.82)
    }

    private func rememberCurrentSelection() {
        guard let range = editorInteractionState.currentSelectionRange() else { return }
        store.updateSelection(for: store.activeTabID, range: range)
    }
}

struct CompactNotchView: View {
    let layout: NotchLayout
    var onTap: (() -> Void)? = nil

    var body: some View {
        Image(systemName: "note.text")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.82))
            .frame(width: layout.compactSize.width, height: layout.compactSize.height)
            .background(Color(red: 0.02, green: 0.02, blue: 0.025).opacity(0.98))
            .clipShape(NotchShape(topCornerRadius: 0, bottomCornerRadius: 12))
            .overlay(
                NotchShape(topCornerRadius: 0, bottomCornerRadius: 12)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .pointingHandCursor()
    }
}

struct MarkdownNoteEditor: View {
    @ObservedObject var store: NoteStore
    let imageStore: LocalImageStore
    let editorInteractionState: EditorInteractionState
    @State private var isWikiLinkActive = false
    @State private var pendingInlineReplacement: InlineReplacementRequest?

    var body: some View {
        NativeTextViewWrapper(
            text: Binding(
                get: { store.text },
                set: { store.updateText($0) }
            ),
            isWikiLinkActive: $isWikiLinkActive,
            pendingInlineReplacement: $pendingInlineReplacement,
            configuration: configuration,
            fontName: "SF Pro",
            fontSize: 15,
            documentId: store.activeTabID.uuidString,
            isEditable: true,
            onPasteImage: savePastedImage
        )
        .background {
            EditorFocusBinder(state: editorInteractionState)
        }
    }

    private func savePastedImage(_ pasteboard: NSPasteboard) -> String? {
        imageStore.saveImage(from: pasteboard)
    }

    private var configuration: MarkdownEditorConfiguration {
        let theme = MarkdownEditorTheme(
            bodyText: NSColor(white: 0.92, alpha: 1),
            mutedText: NSColor(white: 0.58, alpha: 1),
            disabledText: NSColor(white: 0.38, alpha: 1),
            headingMarker: NSColor(white: 0.44, alpha: 1),
            link: NSColor.systemBlue,
            incompleteLink: NSColor.systemBlue.withAlphaComponent(0.75),
            findMatchHighlight: NSColor.systemYellow.withAlphaComponent(0.55),
            findCurrentMatchHighlight: NSColor.systemYellow,
            latexLightModeText: .white,
            latexDarkModeText: .white,
            strikethroughColor: NSColor(white: 0.62, alpha: 1)
        )

        let services = MarkdownEditorServices(images: imageStore)

        return MarkdownEditorConfiguration(
            theme: theme,
            services: services,
            lists: ListStyle(indentPerLevel: 18, extraLineHeight: 1),
            imageEmbed: ImageEmbedStyle(fallbackMaxWidth: 440, paragraphSpacing: 6, imageGap: 6),
            overscroll: OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0),
            dragSelection: DragSelectionPolicy(movementThreshold: 8, edgeTriggerDistance: 8, scrollStepPerTick: 4, ticksPerSecond: 30),
            scrollers: .vertical,
            textInsets: TextInsets(horizontal: 12, vertical: 12)
        )
    }
}

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

struct DarkIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 13, weight: .semibold),
            normalOpacity: 0.055,
            hoverOpacity: 0.085,
            pressedOpacity: 0.12,
            strokeOpacity: 0.06,
            foregroundOpacity: 0.76,
            pressedForegroundOpacity: 0.55
        )
    }
}

struct TabIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 11, weight: .bold),
            normalOpacity: 0,
            hoverOpacity: 0.065,
            pressedOpacity: 0.10,
            strokeOpacity: 0,
            foregroundOpacity: 0.72,
            pressedForegroundOpacity: 0.48
        )
    }
}

struct TabDotButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 11, weight: .semibold),
            normalOpacity: isSelected ? 0.045 : 0,
            hoverOpacity: isSelected ? 0.075 : 0.055,
            pressedOpacity: isSelected ? 0.10 : 0.08,
            strokeOpacity: 0,
            foregroundOpacity: 0.72,
            pressedForegroundOpacity: 0.58
        )
    }
}

struct MarkdownToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedHoverButtonBody(
            configuration: configuration,
            font: .system(size: 11, weight: .semibold),
            normalOpacity: 0,
            hoverOpacity: 0.065,
            pressedOpacity: 0.10,
            strokeOpacity: 0,
            foregroundOpacity: 0.66,
            hoverForegroundOpacity: 0.84,
            pressedForegroundOpacity: 0.54
        )
    }
}

private struct RoundedHoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let font: Font?
    let normalOpacity: CGFloat
    let hoverOpacity: CGFloat
    let pressedOpacity: CGFloat
    let strokeOpacity: CGFloat
    let foregroundOpacity: CGFloat
    let hoverForegroundOpacity: CGFloat
    let pressedForegroundOpacity: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    init(
        configuration: ButtonStyle.Configuration,
        font: Font?,
        normalOpacity: CGFloat,
        hoverOpacity: CGFloat,
        pressedOpacity: CGFloat,
        strokeOpacity: CGFloat,
        foregroundOpacity: CGFloat,
        hoverForegroundOpacity: CGFloat? = nil,
        pressedForegroundOpacity: CGFloat
    ) {
        self.configuration = configuration
        self.font = font
        self.normalOpacity = normalOpacity
        self.hoverOpacity = hoverOpacity
        self.pressedOpacity = pressedOpacity
        self.strokeOpacity = strokeOpacity
        self.foregroundOpacity = foregroundOpacity
        self.hoverForegroundOpacity = hoverForegroundOpacity ?? foregroundOpacity
        self.pressedForegroundOpacity = pressedForegroundOpacity
    }

    var body: some View {
        configuration.label
            .font(font)
            .foregroundStyle(.white.opacity(currentForegroundOpacity))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(currentBackgroundOpacity))
            )
            .animation(.easeOut(duration: 0.10), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                guard isEnabled else { return }
                isHovering = hovering
            }
            .pointingHandCursor(isEnabled: isEnabled)
    }

    private var currentBackgroundOpacity: CGFloat {
        guard isEnabled else { return 0 }
        if configuration.isPressed {
            return pressedOpacity
        }
        return isHovering ? hoverOpacity : normalOpacity
    }

    private var currentForegroundOpacity: CGFloat {
        guard isEnabled else { return 0.22 }
        if configuration.isPressed {
            return pressedForegroundOpacity
        }
        return isHovering ? hoverForegroundOpacity : foregroundOpacity
    }
}

private extension View {
    func pointingHandCursor(isEnabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(isEnabled: isEnabled))
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    let isEnabled: Bool
    @State private var isCursorActive = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, isEnabled, !isCursorActive {
                    NSCursor.pointingHand.push()
                    isCursorActive = true
                } else if (!hovering || !isEnabled), isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled, isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
            .onDisappear {
                if isCursorActive {
                    NSCursor.pop()
                    isCursorActive = false
                }
            }
    }
}

struct ResizeGrip: View {
    var body: some View {
        Canvas { context, size in
            let dotSize: CGFloat = 2.5
            let spacing: CGFloat = 5
            for row in 0..<3 {
                for col in 0..<3 where row + col >= 2 {
                    let x = size.width - CGFloat(3 - col) * spacing
                    let y = size.height - CGFloat(3 - row) * spacing
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.25)))
                }
            }
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
    }
}

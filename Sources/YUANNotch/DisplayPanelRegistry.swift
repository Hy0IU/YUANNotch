import AppKit

@MainActor
final class DisplayPanelRegistry {
    private var hotPanels: [String: NotchPanel] = [:]
    private var hotHostingViews: [String: CompactFileDropHostingView<CompactNotchView>] = [:]
    private var drawerPanels: [String: NotchPanel] = [:]
    private var drawerHostingViews: [String: FirstMouseHostingView<NotebookView>] = [:]

    func hotPanel(for displayID: String) -> NotchPanel? {
        hotPanels[displayID]
    }

    func setHotPanel(_ panel: NotchPanel, for displayID: String) {
        hotPanels[displayID] = panel
    }

    func removeHotPanel(for displayID: String) {
        hotPanels.removeValue(forKey: displayID)
    }

    var hotPanelEntries: [(String, NotchPanel)] {
        Array(hotPanels)
    }

    var hotDisplayIDs: [String] {
        Array(hotPanels.keys)
    }

    func hotHostingView(for displayID: String) -> CompactFileDropHostingView<CompactNotchView>? {
        hotHostingViews[displayID]
    }

    func setHotHostingView(
        _ hostingView: CompactFileDropHostingView<CompactNotchView>,
        for displayID: String
    ) {
        hotHostingViews[displayID] = hostingView
    }

    func removeHotHostingView(for displayID: String) {
        hotHostingViews.removeValue(forKey: displayID)
    }

    func drawerPanel(for displayID: String) -> NotchPanel? {
        drawerPanels[displayID]
    }

    func setDrawerPanel(_ panel: NotchPanel, for displayID: String) {
        drawerPanels[displayID] = panel
    }

    func removeDrawerPanel(for displayID: String) {
        drawerPanels.removeValue(forKey: displayID)
    }

    var drawerPanelEntries: [(String, NotchPanel)] {
        Array(drawerPanels)
    }

    func drawerHostingView(for displayID: String) -> FirstMouseHostingView<NotebookView>? {
        drawerHostingViews[displayID]
    }

    func setDrawerHostingView(
        _ hostingView: FirstMouseHostingView<NotebookView>,
        for displayID: String
    ) {
        drawerHostingViews[displayID] = hostingView
    }

    func removeDrawerHostingView(for displayID: String) {
        drawerHostingViews.removeValue(forKey: displayID)
    }
}

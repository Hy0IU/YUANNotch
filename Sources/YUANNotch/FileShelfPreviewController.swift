import AppKit
import Combine
import QuickLookUI

@MainActor
final class FileShelfPreviewController: NSObject, ObservableObject,
    @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []
    private var onVisibilityChanged: ((Bool) -> Void)?

    func toggle(
        urls: [URL],
        preferredURL: URL?,
        onVisibilityChanged: @escaping (Bool) -> Void
    ) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible, panel.dataSource === self {
            close()
            return
        }

        self.urls = urls
        self.onVisibilityChanged = onVisibilityChanged
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if let preferredURL, let index = urls.firstIndex(of: preferredURL) {
            panel.currentPreviewItemIndex = index
        } else {
            panel.currentPreviewItemIndex = 0
        }
        panel.makeKeyAndOrderFront(nil)
        onVisibilityChanged(true)
    }

    func close() {
        guard let panel = QLPreviewPanel.shared(), panel.dataSource === self else {
            onVisibilityChanged?(false)
            return
        }
        panel.orderOut(nil)
        onVisibilityChanged?(false)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        onVisibilityChanged?(false)
    }
}

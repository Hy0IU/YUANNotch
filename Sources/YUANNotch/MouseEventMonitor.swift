import AppKit

final class MouseEventMonitor {
    private let onMouseDragged: (NSEvent) -> Void
    private let onMouseUp: (NSEvent) -> Void
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?

    init(
        onMouseDragged: @escaping (NSEvent) -> Void,
        onMouseUp: @escaping (NSEvent) -> Void
    ) {
        self.onMouseDragged = onMouseDragged
        self.onMouseUp = onMouseUp

        mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            self?.onMouseDragged(event)
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.onMouseUp(event)
        }
    }

    deinit {
        if let mouseDraggedMonitor {
            NSEvent.removeMonitor(mouseDraggedMonitor)
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
    }
}

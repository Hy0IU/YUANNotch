import AppKit

final class MouseEventMonitor {
    private let onMouseDown: (NSEvent) -> Void
    private let onMouseDragged: (NSEvent) -> Void
    private let onMouseUp: (NSEvent) -> Void
    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?

    init(
        onMouseDown: @escaping (NSEvent) -> Void,
        onMouseDragged: @escaping (NSEvent) -> Void,
        onMouseUp: @escaping (NSEvent) -> Void
    ) {
        self.onMouseDown = onMouseDown
        self.onMouseDragged = onMouseDragged
        self.onMouseUp = onMouseUp

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.onMouseDown(event)
        }
        mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            self?.onMouseDragged(event)
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.onMouseUp(event)
        }
    }

    deinit {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
        }
        if let mouseDraggedMonitor {
            NSEvent.removeMonitor(mouseDraggedMonitor)
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
    }
}

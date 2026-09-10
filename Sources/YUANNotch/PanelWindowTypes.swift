import AppKit
import SwiftUI

@MainActor
final class NotchPanel: NSPanel {
    var onMouseEvent: ((NSEvent) -> Void)?
    /// Hot (compact) panels should never take keyboard focus; if they stay
    /// in the window cycle, app activation can make the Window Server drag
    /// them onto the active display.
    var allowsKeyboardFocus = true

    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { allowsKeyboardFocus }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
            onMouseEvent?(event)
        }

        super.sendEvent(event)
    }
}

@MainActor
class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

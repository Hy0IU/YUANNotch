import Foundation

/// Opt-in diagnostics for the file-drag pipeline.
///
/// Start the app with `YUANNOTCH_DRAG_DEBUG=1` and it appends one line per
/// state change to `/tmp/yuannotch-drag.log`. Without the variable nothing
/// is written and no file is created.
///
/// The pipeline depends on state that cannot be observed from outside the
/// process — AppKit drag-destination resolution, the drag pasteboard, and
/// the event-source button state — so without this a failure can only be
/// guessed at. `OSLog` would also work, but a plain file is far easier to
/// read back during a debugging session.
enum FileDragDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["YUANNOTCH_DRAG_DEBUG"] == "1"

    private static let logURL = URL(fileURLWithPath: "/tmp/yuannotch-drag.log")
    private static let queue = DispatchQueue(label: "io.github.hy0iu.YUANNotch.drag-diagnostics")
    private static let start = Date()
    private static let handle: FileHandle? = {
        guard isEnabled else { return nil }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        return try? FileHandle(forWritingTo: logURL)
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard let handle else { return }
        let line = String(format: "[%8.2f] %@\n", Date().timeIntervalSince(start), message())
        queue.async {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        }
    }
}

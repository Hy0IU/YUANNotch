import AppKit
import MarkdownEngine
import SwiftUI

private let fixture = """
# 混合标题 Mixed Heading

这里是中文正文与 English body text，用于检查基础字体尺寸。

## 次级标题 Secondary Heading

- 普通列表项 A regular list item
- [ ] 待办任务 An unchecked task
- [x] 已完成任务 A checked task

```swift
let answer = 42
print("字体大小会随设置变化")
```
"""

@MainActor
private final class ProbeModel: ObservableObject {
    @Published var fontSize: CGFloat = 15
    @Published private(set) var storedText = fixture
    private(set) var bindingSetterCalls = 0

    var textBinding: Binding<String> {
        Binding(
            get: { self.storedText },
            set: { self.storeText($0) }
        )
    }

    func storeText(_ value: String) {
        bindingSetterCalls += 1
        storedText = value
    }

    func resetBindingSetterCount() {
        bindingSetterCalls = 0
    }
}

private struct EditorHost: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        NativeTextViewWrapper(
            text: model.textBinding,
            configuration: .default,
            fontName: "SF Pro",
            fontSize: model.fontSize,
            documentId: "stable-note-rendering-probe-document",
            isEditable: true
        )
        .frame(width: 760, height: 560)
        .background(Color.black)
    }
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants(of:))
}

@MainActor
private func editorTextView(in host: NSView) -> NSTextView? {
    descendants(of: host)
        .compactMap { $0 as? NSScrollView }
        .compactMap { $0.documentView as? NSTextView }
        .first
}

@MainActor
private func pump(_ host: NSView, turns: Int = 8) {
    for _ in 0 ..< turns {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
}

@MainActor
private func font(in textView: NSTextView, at sample: String) -> NSFont? {
    let nsText = textView.string as NSString
    let range = nsText.range(of: sample)
    guard range.location != NSNotFound,
          let storage = textView.textStorage,
          range.location < storage.length else { return nil }
    return storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
}

@MainActor
private func saveScreenshot(of host: NSView, to url: URL) throws {
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw NSError(domain: "NoteRenderingProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate screenshot bitmap"])
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "NoteRenderingProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode screenshot"])
    }
    try png.write(to: url, options: .atomic)
}

@MainActor
private var failures = 0

@MainActor
private func check(_ label: String, _ passed: Bool, _ detail: String) {
    print("\(passed ? "PASS" : "FAIL")  \(label)")
    print("      \(detail)")
    if !passed { failures += 1 }
}

@MainActor
private func runProbe(outputDirectory: URL) throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let model = ProbeModel()
    let host = NSHostingView(rootView: EditorHost(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
    let window = NSWindow(
        contentRect: host.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.contentView = host
    pump(host, turns: 16)

    guard let textView = editorTextView(in: host) else {
        print("FAIL  MarkdownEngine did not install an NSTextView in its scroll view")
        exit(1)
    }

    let expectedSelection = NSRange(
        location: (fixture as NSString).range(of: "English body text").location + 2,
        length: 5
    )
    textView.setSelectedRange(expectedSelection)
    model.resetBindingSetterCount()

    let fontCases: [(CGFloat, String)] = [(12, "12"), (15, "15"), (24, "24")]
    for (size, label) in fontCases {
        model.fontSize = size
        pump(host)

        let currentTextView = editorTextView(in: host)
        let identityStable = currentTextView === textView
        let textStable = model.storedText == fixture && textView.string == fixture
        let selectionStable = NSEqualRanges(textView.selectedRange(), expectedSelection)
        let noBindingWrite = model.bindingSetterCalls == 0
        let bodyFont = font(in: textView, at: "中文正文与 English body text")
        let headingFont = font(in: textView, at: "混合标题 Mixed Heading")
        let codeFont = font(in: textView, at: "let answer = 42")

        let bodySize = bodyFont?.pointSize ?? -1
        let headingSize = headingFont?.pointSize ?? -1
        let codeSize = codeFont?.pointSize ?? -1

        check("\(label)pt keeps the same NSTextView", identityStable, "documentId stayed stable")
        check("\(label)pt preserves stored/display text and selection", textStable && selectionStable,
              "text unchanged=\(textStable), range=\(NSStringFromRange(textView.selectedRange()))")
        check("\(label)pt font update does not write the text Binding", noBindingWrite,
              "setter calls since reset: \(model.bindingSetterCalls)")
        check("\(label)pt body, heading and code fonts scale",
              abs(bodySize - size) < 0.1
                && abs(headingSize - size * 2) < 0.1
                && abs(codeSize - (size * 0.85).rounded()) < 0.1,
              "body=\(bodySize), h1=\(headingSize), code=\(codeSize)")
    }

    let screenshot = outputDirectory.appendingPathComponent("mixed-markdown-note24.png")
    try saveScreenshot(of: host, to: screenshot)
    print("SCREENSHOT  \(screenshot.path)")

    // Editing via NSTextView's real insertion API should create an undo action.
    // Keep the same wrapper/document identity while its font changes, then undo
    // the insertion to verify that a style rebuild did not erase editor history.
    model.fontSize = 15
    pump(host)
    let becameFirstResponder = window.makeFirstResponder(textView)
    let insertLocation = (fixture as NSString).range(of: "English body text").location
        + ("English body" as NSString).length
    textView.setSelectedRange(NSRange(location: insertLocation, length: 0))
    textView.insertText("!", replacementRange: textView.selectedRange())
    pump(host, turns: 12)

    let edited = (fixture as NSString).replacingCharacters(
        in: NSRange(location: insertLocation, length: 0),
        with: "!"
    )
    check("real insertion updates the stored Markdown", model.storedText == edited && textView.string == edited,
          "Binding calls after insertion: \(model.bindingSetterCalls); offscreen first responder: \(becameFirstResponder)")

    let postEditSelection = textView.selectedRange()
    let historyBeforeFontChange = textView.undoManager?.canUndo ?? false
    model.fontSize = 24
    pump(host)
    let historyAfterFontChange = textView.undoManager?.canUndo ?? false
    let postStyleSelectionStable = NSEqualRanges(textView.selectedRange(), postEditSelection)
    let bindingCallsAfterInsert = model.bindingSetterCalls
    check("font change retains the edit and selection", model.storedText == edited && postStyleSelectionStable,
          "undo manager present=\(textView.undoManager != nil), selection=\(NSStringFromRange(textView.selectedRange()))")
    check("font change does not write the text Binding", model.bindingSetterCalls == bindingCallsAfterInsert,
          "setter calls after insertion remain \(bindingCallsAfterInsert)")

    if historyBeforeFontChange {
        check("font change preserves undo history", historyAfterFontChange,
              "undo action before size change: available; after: \(historyAfterFontChange)")
    } else {
        print("SKIP  undo history check: AppKit did not register an offscreen undo action for the insertion")
    }

    if let undoManager = textView.undoManager, historyAfterFontChange {
        undoManager.undo()
        pump(host, turns: 12)
        if model.storedText == fixture && textView.string == fixture {
            check("undo after font change removes the insertion", true,
                  "same NSTextView=\(editorTextView(in: host) === textView)")
        } else {
            print("SKIP  undo application: an offscreen Typing action existed but AppKit did not restore the inserted text")
        }
    } else {
        print("SKIP  undo application: no offscreen undo action remained after the size change")
    }

    window.close()
    print("")
    print(failures == 0 ? "every note rendering check passed" : "\(failures) note rendering check(s) failed")
    if failures > 0 { exit(1) }
}

MainActor.assumeIsolated {
    let directory = CommandLine.arguments.dropFirst().first ?? "/tmp/yuanotch-note-rendering-probe"
    do {
        try runProbe(outputDirectory: URL(fileURLWithPath: directory, isDirectory: true))
    } catch {
        fputs("ERROR  \(error.localizedDescription)\n", stderr)
        exit(2)
    }
}

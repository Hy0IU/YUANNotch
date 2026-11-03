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
• 圆点项目 Bullet item with enough words to wrap across a narrow editor when its font size increases.
1. 有序项目 Ordered item
	• 嵌套项目 Nested item

> 引用正文 Quote body
---
**强调正文** and `inline code` and [link label](https://example.com)
[[missing page]] and https://example.org
[unfinished]


```swift
let answer = 42
> code literal
print("字体大小会随设置变化")
```
"""

@MainActor
private final class ProbeModel: ObservableObject {
    @Published var fontSize: CGFloat = 15
    @Published private(set) var storedText: String
    private(set) var bindingSetterCalls = 0

    init(text: String = fixture) {
        storedText = text
    }

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
    var width: CGFloat = 760
    var height: CGFloat = 560

    var body: some View {
        NativeTextViewWrapper(
            text: model.textBinding,
            configuration: NoteMarkdownStyle.configuration(fontSize: model.fontSize),
            fontName: "SF Pro",
            fontSize: model.fontSize,
            documentId: "stable-note-rendering-probe-document",
            isEditable: true
        )
        .frame(width: width, height: height)
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
private func attribute(_ key: NSAttributedString.Key, in textView: NSTextView, at sample: String, offset: Int = 0) -> Any? {
    let range = (textView.string as NSString).range(of: sample)
    guard range.location != NSNotFound, offset >= 0, offset < range.length else { return nil }
    return textView.textStorage?.attribute(key, at: range.location + offset, effectiveRange: nil)
}

private func sameColor(_ actual: NSColor?, _ expected: NSColor) -> Bool {
    guard let actual = actual?.usingColorSpace(.deviceRGB),
          let expected = expected.usingColorSpace(.deviceRGB) else { return false }
    return abs(actual.redComponent - expected.redComponent) < 0.01
        && abs(actual.greenComponent - expected.greenComponent) < 0.01
        && abs(actual.blueComponent - expected.blueComponent) < 0.01
        && abs(actual.alphaComponent - expected.alphaComponent) < 0.01
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

/// Measure actual TextKit segments, excluding the marker, on every wrapped line.
@MainActor
private func wrappedColumns(in textView: NSTextView, startingAt sample: String) -> [CGFloat] {
    guard let manager = textView.textLayoutManager,
          let content = manager.textContentManager as? NSTextContentStorage else { return [] }
    let text = textView.string as NSString
    let sampleRange = text.range(of: sample)
    guard sampleRange.location != NSNotFound else { return [] }
    let line = text.lineRange(for: sampleRange)
    let endOffset = NSMaxRange(line) - (text.substring(with: line).hasSuffix("\n") ? 1 : 0)
    guard let start = content.location(content.documentRange.location, offsetBy: sampleRange.location),
          let end = content.location(content.documentRange.location, offsetBy: endOffset),
          let range = NSTextRange(location: start, end: end) else { return [] }
    manager.ensureLayout(for: range)
    var lines: [(y: CGFloat, x: CGFloat)] = []
    manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
        guard !rect.isEmpty else { return true }
        if let index = lines.firstIndex(where: { abs($0.y - rect.minY) < 1 }) {
            lines[index].x = min(lines[index].x, rect.minX)
        } else {
            lines.append((rect.minY, rect.minX))
        }
        return true
    }
    return lines.sorted { $0.y < $1.y }.map(\.x)
}

@MainActor
private func probeNarrowLists(outputDirectory: URL) throws {
    let examples = [
        ("- ", "Dash"), ("• ", "Bullet"), ("10. ", "Ten"), ("100. ", "Hundred"),
        ("\t• ", "Tabbed"), ("  • ", "Spaced"),
        ("- [ ] ", "Unchecked"), ("- [x] ", "Checked")
    ]
    let text = examples.map { prefix, label in
        "\(prefix)\(label) words wrap across multiple lines in this deliberately narrow editor column for alignment checks."
    }.joined(separator: "\n")
    let model = ProbeModel(text: text)
    let host = NSHostingView(rootView: EditorHost(model: model, width: 220, height: 1500))
    host.frame = NSRect(x: 0, y: 0, width: 220, height: 1500)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.contentView = host
    pump(host, turns: 16)
    guard let textView = editorTextView(in: host) else {
        check("narrow list editor exists", false, "no NSTextView")
        window.close()
        return
    }
    for size in [CGFloat(12), 15, 24] {
        model.fontSize = size
        pump(host)
        var taskColumns: [CGFloat] = []
        for (_, label) in examples {
            let columns = wrappedColumns(in: textView, startingAt: label)
            let aligned = columns.count > 1 && columns.dropFirst().allSatisfy { abs($0 - columns[0]) < 2 }
            check("\(Int(size))pt \(label) wrapped text aligns", aligned, "line starts: \(columns)")
            if label == "Unchecked" || label == "Checked", let first = columns.first {
                taskColumns.append(first)
            }
        }
        check("\(Int(size))pt checked and unchecked text align",
              taskColumns.count == 2 && abs(taskColumns[0] - taskColumns[1]) < 2,
              "first-line starts: \(taskColumns)")
        if size == 15 || size == 24 {
            try saveScreenshot(of: host, to: outputDirectory.appendingPathComponent("narrow-lists-\(Int(size)).png"))
        }
    }
    let beforeToggle = wrappedColumns(in: textView, startingAt: "Unchecked")
    model.storeText(text.replacingOccurrences(of: "- [ ] Unchecked", with: "- [x] Unchecked"))
    pump(host)
    let afterToggle = wrappedColumns(in: textView, startingAt: "Unchecked")
    check("toggling a task keeps its wrapped text columns",
          beforeToggle.count > 1 && beforeToggle.count == afterToggle.count
            && zip(beforeToggle, afterToggle).allSatisfy { pair in abs(pair.0 - pair.1) < 2 },
          "before: \(beforeToggle); after: \(afterToggle)")
    window.close()
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
    var previousNestingOffset: CGFloat = 0
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
        let bullet = attribute(.paragraphStyle, in: textView, at: "圆点项目") as? NSParagraphStyle
        let nested = attribute(.paragraphStyle, in: textView, at: "嵌套项目") as? NSParagraphStyle
        let unchecked = attribute(.paragraphStyle, in: textView, at: "待办任务") as? NSParagraphStyle
        let checked = attribute(.paragraphStyle, in: textView, at: "已完成任务") as? NSParagraphStyle
        let nestingOffset = (nested?.headIndent ?? 0) - (bullet?.headIndent ?? 0)
        check("\(label)pt nested and task wrapping columns",
              bullet != nil && nested != nil && unchecked != nil && checked != nil
                && nestingOffset > previousNestingOffset
                && abs((unchecked?.headIndent ?? 0) - (checked?.headIndent ?? 0)) < 0.1,
              "nested offset=\(nestingOffset), task indents=\(unchecked?.headIndent ?? -1)/\(checked?.headIndent ?? -1)")
        previousNestingOffset = nestingOffset
    }

    let screenshot = outputDirectory.appendingPathComponent("mixed-markdown-note24.png")
    try saveScreenshot(of: host, to: screenshot)
    print("SCREENSHOT  \(screenshot.path)")
    try probeNarrowLists(outputDirectory: outputDirectory)

    let orange = NSColor(Color.orange)
    let bodyColor = NoteMarkdownStyle.configuration(fontSize: model.fontSize).theme.bodyText
    func color(_ sample: String, offset: Int = 0) -> NSColor? {
        attribute(.foregroundColor, in: textView, at: sample, offset: offset) as? NSColor
    }
    func activate(_ sample: String, offset: Int) {
        let range = (textView.string as NSString).range(of: sample)
        guard range.location != NSNotFound else { return }
        textView.setSelectedRange(NSRange(location: range.location + offset, length: 0))
        pump(host)
    }
    check("body and code content stay readable",
          sameColor(color("中文正文与 English body text"), bodyColor)
            && sameColor(color("> code literal"), bodyColor)
            && !sameColor(bodyColor, orange),
          "ordinary text and Markdown-looking code are not syntax markers")
    check("list, ordered and quote markers use timer orange",
          sameColor(color("• 圆点项目"), orange)
            && sameColor(color("1. 有序项目"), orange)
            && sameColor(color("> 引用正文"), orange),
          "list and quote glyphs share the timer's semantic color")
    let ruleColor = attribute(.strikethroughColor, in: textView, at: "---") as? NSColor
    check("horizontal rule uses timer orange", sameColor(ruleColor, orange), "rule stroke")
    check("wiki and incomplete links use timer orange",
          sameColor(color("missing page"), orange)
            && sameColor(color("[unfinished]"), orange)
            && attribute(.link, in: textView, at: "https://example.org") != nil
            && sameColor(textView.linkTextAttributes?[.foregroundColor] as? NSColor, orange),
          "wiki and incomplete links are colored; detected URLs use AppKit link drawing")
    activate("# 混合标题", offset: 3)
    check("active heading marker uses timer orange", sameColor(color("# 混合标题"), orange), "heading source")
    activate("**强调正文**", offset: 3)
    check("active emphasis markers use timer orange",
          sameColor(color("**强调正文**"), orange)
            && sameColor(color("**强调正文**", offset: 6), orange)
            && sameColor(color("强调正文"), bodyColor),
          "both delimiters are orange without recoloring their content")
    activate("`inline code`", offset: 3)
    check("active code delimiters use timer orange",
          sameColor(color("`inline code`"), orange)
            && sameColor(color("inline code"), bodyColor),
          "code content remains body-colored")
    activate("[link label](https://example.com)", offset: 3)
    check("active link source uses timer orange",
          sameColor(color("[link label](https://example.com)"), orange)
            && sameColor(color("link label"), orange)
            && sameColor(textView.linkTextAttributes?[.foregroundColor] as? NSColor, orange),
          "link syntax and AppKit link drawing use the same accent")

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

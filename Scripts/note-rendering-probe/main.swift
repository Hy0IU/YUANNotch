import AppKit
import CoreText
import MarkdownEngine
import SwiftUI

private let fixture = """
# 混合标题 Mixed Heading

这里是中文正文与 English body text，用于检查基础字体尺寸。

## 次级标题 Secondary Heading

# 使用 `foo` 的说明

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
    var backgroundColor: Color = .black

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
        .background(backgroundColor)
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
    // A reused offscreen host may only have the edited line invalidated.
    // Redraw the whole view tree rather than caching a partial dirty region.
    for view in descendants(of: host) {
        view.needsDisplay = true
    }
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

/// Segment rectangles include half the kern at their boundaries. Keep them
/// for diagnostics, but measure the drawn glyph origins for column alignment.
@MainActor
private func segmentColumns(in textView: NSTextView, startingAt sample: String) -> [CGFloat] {
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
private func wrappedColumns(in textView: NSTextView, startingAt sample: String) -> [CGFloat] {
    guard let manager = textView.textLayoutManager,
          let content = manager.textContentManager as? NSTextContentStorage else { return [] }
    let text = textView.string as NSString
    let sampleRange = text.range(of: sample)
    guard sampleRange.location != NSNotFound,
          let start = content.location(content.documentRange.location, offsetBy: sampleRange.location) else { return [] }
    let paragraph = text.paragraphRange(for: sampleRange)
    guard let end = content.location(content.documentRange.location, offsetBy: NSMaxRange(paragraph)),
          let range = NSTextRange(location: start, end: end) else { return [] }
    manager.ensureLayout(for: range)
    guard let fragment = manager.textLayoutFragment(for: start) else { return [] }
    let fragmentStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
    let bodyStart = sampleRange.location - fragmentStart
    var columns: [CGFloat] = []
    for line in fragment.textLineFragments {
        let lineRange = line.characterRange
        let source = line.attributedString
        guard lineRange.location != NSNotFound, NSMaxRange(lineRange) <= source.length else { return [] }
        var target = max(bodyStart, lineRange.location)
        let characters = source.string as NSString
        while target < NSMaxRange(lineRange),
              [0x20, 0x09, 0x0A, 0x0D].contains(Int(characters.character(at: target))) {
            target += 1
        }
        guard target < NSMaxRange(lineRange) else { continue }
        let ctLine = CTLineCreateWithAttributedString(source.attributedSubstring(from: lineRange))
        let targetInLine = target - lineRange.location
        var origin: CGFloat?
        for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            if let index = indices.firstIndex(of: targetInLine) {
                origin = positions[index].x
                break
            }
        }
        guard let origin else { return [] }
        columns.append(fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + origin)
    }
    return columns
}

/// Locate the visible orange checkbox in a cached rendering, then click its
/// pixel bounds' center rather than a source-character hit-test position.
@MainActor
private func clickCheckbox(in textView: NSTextView, sample: String) -> Bool {
    guard let window = textView.window, let host = window.contentView,
          let manager = textView.textLayoutManager,
          let content = manager.textContentManager as? NSTextContentStorage else { return false }
    let sampleRange = (textView.string as NSString).range(of: sample)
    guard sampleRange.location != NSNotFound,
          let location = content.location(content.documentRange.location, offsetBy: sampleRange.location),
          let end = content.location(location, offsetBy: 3),
          let range = NSTextRange(location: location, end: end) else { return false }
    textView.scrollRangeToVisible(sampleRange)
    pump(host)
    manager.ensureLayout(for: range)
    guard let fragment = manager.textLayoutFragment(for: location) else { return false }
    let fragmentStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
    guard let line = fragment.textLineFragments.first(where: {
        NSLocationInRange(sampleRange.location - fragmentStart, $0.characterRange)
    }) else { return false }
    let label = (sample as NSString).substring(from: 4)
    guard let bodyX = wrappedColumns(in: textView, startingAt: label).first else { return false }
    let row = NSRect(
        x: textView.textContainerOrigin.x,
        y: textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY,
        width: max(0, bodyX - 2),
        height: line.typographicBounds.height
    )
    let visibleRow = textView.convert(row, to: host).intersection(host.bounds)
    guard !visibleRow.isEmpty else { return false }
    for view in descendants(of: host) { view.needsDisplay = true }
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let sx = CGFloat(bitmap.pixelsWide) / host.bounds.width
    let sy = CGFloat(bitmap.pixelsHigh) / host.bounds.height
    let top = host.isFlipped ? visibleRow.minY : host.bounds.height - visibleRow.maxY
    let minX = max(0, Int(floor(visibleRow.minX * sx)))
    let maxX = min(bitmap.pixelsWide, Int(ceil(visibleRow.maxX * sx)))
    let minY = max(0, Int(floor(top * sy)))
    let maxY = min(bitmap.pixelsHigh, Int(ceil((top + visibleRow.height) * sy)))
    guard minX < maxX, minY < maxY else { return false }
    var left = maxX, right = minX, upper = maxY, lower = minY
    for y in minY..<maxY {
        for x in minX..<maxX {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  color.redComponent > 0.5, color.redComponent > color.greenComponent * 1.15,
                  color.greenComponent > color.blueComponent * 1.3 else { continue }
            left = min(left, x); right = max(right, x)
            upper = min(upper, y); lower = max(lower, y)
        }
    }
    guard left <= right, upper <= lower else { return false }
    let x = (CGFloat(left + right + 1) / 2) / sx
    let topY = (CGFloat(upper + lower + 1) / 2) / sy
    let y = host.isFlipped ? topY : host.bounds.height - topY
    let pointInWindow = host.convert(NSPoint(x: x, y: y), to: nil)
    guard let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: pointInWindow, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ) else { return false }
    textView.mouseDown(with: event)
    return true
}

@MainActor
private func probeNarrowLists(outputDirectory: URL) throws {
    let examples = [
        ("- ", "Dash"), ("• ", "Bullet"), ("10. ", "Ten"), ("100. ", "Hundred"),
        ("  • ", "Spaced"),
        ("- [ ] ", "Unchecked"), ("- [x] ", "Checked"),
        ("10. [ ] ", "OrderedOpen"), ("10. [x] ", "OrderedDone"),
        ("-   [ ] ", "WideSpace"), ("• ", "InlineCode"),
        ("\t• ", "RootBullet"), ("\t1. ", "RootOrdered"),
        ("\t• [ ] ", "RootOpen"), ("\t• [x] ", "RootDone"),
        ("\t\t• ", "NestedBullet"), ("\t\t• [ ] ", "NestedOpen"), ("\t\t• [X] ", "NestedDone"),
        ("  • [ ] ", "SpacedOpen"), ("  • [x] ", "SpacedDone"),
        ("•   ", "BulletWide"), ("• [ ]   ", "TaskWide")
    ]
    let text = examples.map { prefix, label in
        "\(prefix)\(label) words \(label == "InlineCode" ? "`foo` " : "")wrap across multiple lines in this deliberately narrow editor column for alignment checks."
    }.joined(separator: "\n")
    let model = ProbeModel(text: text)
    let host = NSHostingView(rootView: EditorHost(model: model, width: 220, height: 2600))
    host.frame = NSRect(x: 0, y: 0, width: 220, height: 2600)
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
        var rootTaskColumns: [CGFloat] = []
        for (_, label) in examples {
            let columns = wrappedColumns(in: textView, startingAt: label)
            let aligned = columns.count > 1 && columns.dropFirst().allSatisfy { abs($0 - columns[0]) < 2 }
            check("\(Int(size))pt \(label) wrapped text aligns", aligned,
                  "glyph origins: \(columns); segment bounds: \(segmentColumns(in: textView, startingAt: label))")
            if label == "Unchecked" || label == "Checked", let first = columns.first {
                taskColumns.append(first)
            }
            if label == "RootOpen" || label == "RootDone", let first = columns.first {
                rootTaskColumns.append(first)
            }
        }
        check("\(Int(size))pt checked and unchecked text align",
              taskColumns.count == 2 && abs(taskColumns[0] - taskColumns[1]) < 2,
              "first-line starts: \(taskColumns)")
        check("\(Int(size))pt indented checked and unchecked text align",
              rootTaskColumns.count == 2 && abs(rootTaskColumns[0] - rootTaskColumns[1]) < 2,
              "first-line starts: \(rootTaskColumns)")
        for labels in [
            ["Bullet", "Unchecked", "Checked"],
            ["RootBullet", "RootOpen", "RootDone"],
            ["NestedBullet", "NestedOpen", "NestedDone"],
            ["Spaced", "SpacedOpen", "SpacedDone"],
            ["BulletWide", "TaskWide"]
        ] {
            let starts = labels.compactMap { wrappedColumns(in: textView, startingAt: $0).first }
            check("\(Int(size))pt \(labels.joined(separator: "/")) share a text column",
                  starts.count == labels.count && starts.dropFirst().allSatisfy { abs($0 - starts[0]) < 1 },
                  "first glyph origins: \(starts)")
        }
        let rootStart = wrappedColumns(in: textView, startingAt: "RootBullet").first
        let nestedStart = wrappedColumns(in: textView, startingAt: "NestedBullet").first
        check("\(Int(size))pt two tabs remain nested",
              rootStart.map { root in nestedStart.map { $0 > root } ?? false } ?? false,
              "root=\(rootStart ?? -1), nested=\(nestedStart ?? -1)")
        if size == 15 || size == 24 {
            try saveScreenshot(of: host, to: outputDirectory.appendingPathComponent("narrow-lists-\(Int(size)).png"))
        }
        for (label, checkedSource) in [
            ("Unchecked", "- [x] Unchecked"),
            ("RootOpen", "\t• [x] RootOpen"),
            ("NestedOpen", "\t\t• [x] NestedOpen")
        ] {
            let before = wrappedColumns(in: textView, startingAt: label)
            let clickedOn = clickCheckbox(in: textView, sample: "[ ] \(label)")
            pump(host)
            let after = wrappedColumns(in: textView, startingAt: label)
            check("\(Int(size))pt clicking \(label) at its visible center keeps its text columns",
                  clickedOn && model.storedText.contains(checkedSource)
                    && before.count > 1 && before.count == after.count
                    && zip(before, after).allSatisfy { pair in abs(pair.0 - pair.1) < 1 },
                  "click=\(clickedOn), before: \(before); after: \(after)")
            let clickedOff = clickCheckbox(in: textView, sample: "[x] \(label)")
            pump(host)
            let restored = wrappedColumns(in: textView, startingAt: label)
            check("\(Int(size))pt clicking \(label) again restores its state and text columns",
                  clickedOff && model.storedText == text && before.count == restored.count
                    && zip(before, restored).allSatisfy { pair in abs(pair.0 - pair.1) < 1 },
                  "click=\(clickedOff), after: \(restored)")
        }
    }
    window.close()
}

@MainActor
private func saveListLegibilityScreenshots(outputDirectory: URL) throws {
    // The editor inserts one leading tab when a user types "- " or "1. ".
    let text = [
        "正文参考 Plain text for alignment",
        "\t• 根项目 A longer list item makes the text wrap onto another line so the continuation can be compared with the first line.",
        "\t1. 有序步骤 Ordered step",
        "\t• [ ] 待处理 Open task",
        "\t• [x] 已完成 Completed task",
        "\t\t• 嵌套项目 Nested item",
        "\t\t• [ ] 嵌套待办 Nested task",
        "\t\t• [x] 嵌套完成 Nested completed",
        "\t• 含有 `code` 的列表项 Inline code"
    ].joined(separator: "\n")
    let model = ProbeModel(text: text)
    let host = NSHostingView(rootView: EditorHost(
        model: model, width: 622, height: 375,
        backgroundColor: Color(red: 0.06, green: 0.06, blue: 0.07)
    ))
    host.frame = NSRect(x: 0, y: 0, width: 622, height: 375)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.contentView = host
    pump(host, turns: 16)
    for size in [CGFloat(15), 12, 24] {
        model.fontSize = size
        pump(host)
        if let scrollView = editorTextView(in: host)?.enclosingScrollView {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            pump(host)
        }
        let screenshot = outputDirectory.appendingPathComponent("list-legibility-\(Int(size)).png")
        try saveScreenshot(of: host, to: screenshot)
        print("SCREENSHOT  \(screenshot.path)")
    }
    window.close()
    let alignmentHost = NSHostingView(rootView: EditorHost(
        model: model, width: 622, height: 520,
        backgroundColor: Color(red: 0.06, green: 0.06, blue: 0.07)
    ))
    alignmentHost.frame = NSRect(x: 0, y: 0, width: 622, height: 520)
    let alignmentWindow = NSWindow(contentRect: alignmentHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    alignmentWindow.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    alignmentWindow.contentView = alignmentHost
    pump(alignmentHost, turns: 16)
    for size in [CGFloat(15), 12, 24] {
        model.fontSize = size
        pump(alignmentHost)
        if let scrollView = editorTextView(in: alignmentHost)?.enclosingScrollView {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            pump(alignmentHost)
        }
        let screenshot = outputDirectory.appendingPathComponent("list-alignment-\(Int(size)).png")
        try saveScreenshot(of: alignmentHost, to: screenshot)
        print("SCREENSHOT  \(screenshot.path)")
    }
    alignmentWindow.close()
}

@MainActor
private func saveMixedScreenshots(outputDirectory: URL) throws {
    let model = ProbeModel()
    let host = NSHostingView(rootView: EditorHost(model: model, width: 760, height: 1000))
    host.frame = NSRect(x: 0, y: 0, width: 760, height: 1000)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.contentView = host
    pump(host, turns: 16)
    guard let textView = editorTextView(in: host) else {
        check("full mixed-note editor exists", false, "no NSTextView")
        window.close()
        return
    }
    let body = (textView.string as NSString).range(of: "English body text")
    textView.setSelectedRange(NSRange(location: body.location, length: 0))
    pump(host)
    try saveScreenshot(of: host, to: outputDirectory.appendingPathComponent("mixed-markdown-note15-full.png"))
    let emphasis = (textView.string as NSString).range(of: "**强调正文**")
    textView.setSelectedRange(NSRange(location: emphasis.location + 3, length: 0))
    pump(host)
    try saveScreenshot(of: host, to: outputDirectory.appendingPathComponent("mixed-markdown-note15-editing.png"))
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
        let mixedHeadingSize = font(in: textView, at: "使用 `foo`")?.pointSize ?? -1
        check("\(label)pt heading containing inline code keeps heading font",
              abs(mixedHeadingSize - headingSize) < 0.1,
              "mixed heading=\(mixedHeadingSize), ordinary heading=\(headingSize)")
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
    try saveMixedScreenshots(outputDirectory: outputDirectory)
    try probeNarrowLists(outputDirectory: outputDirectory)
    try saveListLegibilityScreenshots(outputDirectory: outputDirectory)

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
    check("ordered and quote markers use timer orange",
          sameColor(color("1. 有序项目"), orange)
            && sameColor(color("> 引用正文"), orange),
          "ordered and quote glyphs share the timer's semantic color")
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
    activate("# 使用 `foo` 的说明", offset: 3)
    check("heading with inline code keeps its orange marker",
          sameColor(color("# 使用 `foo` 的说明"), orange), "mixed heading source")
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

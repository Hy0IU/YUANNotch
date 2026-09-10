//
//  MarkdownListHandler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Makes list editing feel natural by continuing items, handling indentation,
// and applying spacing/alignment that keeps lists easy to read.
import AppKit

struct MarkdownLists {
    static func performEdit(_ textView: NSTextView, replace range: NSRange, with string: String) {
        let ns = textView.string as NSString
        let loc = min(range.location, ns.length)
        let maxLen = ns.length - loc
        let len = min(range.length, max(0, maxLen))
        let safeRange = NSRange(location: loc, length: len)

        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = true }
        defer {
            if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator { coord.isProgrammaticEdit = false }
        }

        guard textView.shouldChangeText(in: safeRange, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: safeRange, with: string)
        textView.didChangeText()
    }

    static let listRegex = try! NSRegularExpression(
        // Trailing whitespace after the marker is optional (end-of-line also
        // qualifies) so that a marker-only line keeps its list identity —
        // e.g. right after the user deletes the space following the marker.
        pattern: #"^\s*((?:(\d+)\.|[-•])(?:\s+\[[ xX]\])?(?:\s+|$))"#
    )
    static let dashNoSpaceRegex = try! NSRegularExpression(pattern: #"^\s*-(?!\s)"#)
    static let numberRegex = try! NSRegularExpression(pattern: #"^\s*(\d+)\.$"#)
    static let leadingWhitespaceRegex = try! NSRegularExpression(pattern: #"^\s*"#)

    static func indentLevel(from leadingWhitespace: String) -> Int {
        let tabCount = leadingWhitespace.filter { $0 == "\t" }.count
        let spaceCount = leadingWhitespace.filter { $0 == " " }.count
        return tabCount + (spaceCount / 2)
    }

    /// One-backspace marker removal (Notes/Typora style).
    ///
    /// A list marker is several characters (tab + bullet/number + space, plus
    /// a possible `[ ]`), so deleting item content normally leaves the user
    /// backspacing through the marker character by character. When a caret
    /// backspace lands strictly inside the marker range, we remove the whole
    /// marker (including leading whitespace) in a single edit and park the
    /// caret at the line start. Selection deletions and deletions at the very
    /// start of the marker are left alone so normal behavior is preserved.
    ///
    /// - Returns: `true` when the deletion was handled (the caller must veto
    ///   the original edit).
    static func handleDeletion(textView: NSTextView, affectedCharRange: NSRange) -> Bool {
        guard affectedCharRange.length > 0 else { return false }
        let nsText = textView.string as NSString
        let caret = affectedCharRange.location + affectedCharRange.length
        guard caret <= nsText.length, affectedCharRange.location < nsText.length else { return false }

        let lineRange = nsText.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
        let line = nsText.substring(with: lineRange)
        guard let match = listRegex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) else { return false }

        let markerStart = lineRange.location + match.range.location
        let markerEnd = markerStart + match.range.length
        // The deleted character(s) must sit strictly inside the marker: the
        // caret is at/within the marker end and the deletion does not cross
        // the line start. A caret exactly at markerStart is deleting the
        // previous line's newline — leave that alone.
        guard caret > markerStart, caret <= markerEnd, affectedCharRange.location >= markerStart else { return false }

        performEdit(textView, replace: NSRange(location: markerStart, length: markerEnd - markerStart), with: "")
        textView.setSelectedRange(NSRange(location: markerStart, length: 0))
        return true
    }

    // MARK: - Paragraph Attributes for List Styling

    static func paragraphAttributes(
        for text: String,
        baseFont: NSFont,
        nsText: NSString,
        fullRange: NSRange,
        listsEnabled: Bool,
        defaultLineHeight: CGFloat,
        defaultParagraphSpacing: CGFloat,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [(range: NSRange, attributes: [NSAttributedString.Key: Any])] {
        var attributesList: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        guard listsEnabled else { return attributesList }

        let indentPerLevel = configuration.lists.indentPerLevel
        let extraLineHeight = configuration.lists.extraLineHeight
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width

        func applyListMatches(_ matches: [NSTextCheckingResult]) {
            for match in matches {
                let ps = NSMutableParagraphStyle()
                ps.minimumLineHeight = defaultLineHeight + extraLineHeight
                ps.maximumLineHeight = defaultLineHeight + extraLineHeight
                ps.lineSpacing = 0
                ps.paragraphSpacing = defaultParagraphSpacing
                ps.paragraphSpacingBefore = 0
                let wsRange = match.range(at: 1)
                let markerRange = match.range(at: 2)
                let ws = nsText.substring(with: wsRange)
                let tabCount = ws.filter { $0 == "\t" }.count
                let spaceCount = ws.filter { $0 == " " }.count
                let depthIndent = CGFloat(tabCount) * indentPerLevel + CGFloat(spaceCount) * spaceWidth

                let markerString = nsText.substring(with: markerRange) as NSString
                let markerWidth = markerString.size(withAttributes: [.font: baseFont]).width
                let hasCheckbox = markerString.range(of: "[").location != NSNotFound
                let isChecked = markerString.range(of: "[x]", options: [.caseInsensitive]).location != NSNotFound
                let extraSpacing = (hasCheckbox && !isChecked)
                    ? HeadingHelpers.checkboxExtraSpacing(font: baseFont, configuration: configuration.checkbox)
                    : 0

                ps.tabStops = []
                ps.defaultTabInterval = indentPerLevel
                ps.firstLineHeadIndent = 0
                ps.headIndent = depthIndent + markerWidth + extraSpacing

                attributesList.append((match.range(at: 0), [.paragraphStyle: ps]))
            }
        }

        // Ordered lists. The trailing whitespace after the marker may also
        // be end-of-line: without that, deleting the space after a marker
        // briefly drops the list paragraph style and the leading tab falls
        // back to AppKit's default (wider) tab interval, making the marker
        // visibly jump right before the restyle recovers.
        let orderedListPattern = #"^([ \t]*)(\d+\.(?:[ \t]+\[[ xX]\])?(?:[ \t]+|$))(.*)$"#
        if let orderedListRegex = try? NSRegularExpression(pattern: orderedListPattern, options: [.anchorsMatchLines]) {
            applyListMatches(orderedListRegex.matches(in: text, options: [], range: fullRange))
        }

        // Bullet lists (same end-of-line tolerance as ordered lists).
        let bulletListPattern = #"^([ \t]*)([-•](?:[ \t]+\[[ xX]\])?(?:[ \t]+|$))(.*)$"#
        if let bulletListRegex = try? NSRegularExpression(pattern: bulletListPattern, options: [.anchorsMatchLines]) {
            applyListMatches(bulletListRegex.matches(in: text, options: [], range: fullRange))
        }
        return attributesList
    }

    // MARK: - Input Handling

    static func handleInsertion(textView: NSTextView, affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString = replacementString, !replacementString.isEmpty else {
            return !handleDeletion(textView: textView, affectedCharRange: affectedCharRange)
        }

        // Fast path: skip the expensive isInsideCodeBlock scan for ordinary typing.
        if replacementString.count == 1,
           let ch = replacementString.first,
           ch != ">" && ch != "[" && ch != "(" && ch != "{" &&
           ch != "\t" && ch != " " && ch != "\n" {
            return true
        }

        let activeConfig = (textView as? NativeTextView)?.configuration ?? .default
        let listsEnabled = activeConfig.lists.helpersEnabled
        let autoClosePairsEnabled = activeConfig.lists.autoClosePairsEnabled

        func insertAutoPair(open openChar: String, close closeChar: String) -> Bool {
            let insertionLocation = affectedCharRange.location
            MarkdownLists.performEdit(textView, replace: affectedCharRange, with: "\(openChar)\(closeChar)")
            textView.setSelectedRange(NSRange(location: insertionLocation + openChar.count, length: 0))
            return false
        }

        let isInCodeBlock = textView.string.contains("`")
            ? MarkdownDetection.isInsideCodeBlock(location: affectedCharRange.location, in: textView.string)
            : false
        if replacementString == ">" && affectedCharRange.length == 0 && !isInCodeBlock {
            let insertionLocation = affectedCharRange.location
            guard insertionLocation > 0 else { return true }
            let nsText = textView.string as NSString
            let previousCharRange = NSRange(location: insertionLocation - 1, length: 1)
            let previousChar = nsText.substring(with: previousCharRange)
            if previousChar == "-" {
                MarkdownLists.performEdit(textView, replace: previousCharRange, with: "→")
                textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
                return false
            }
        }

        // Autocomplete Obsidian-style node brackets and single square brackets
        if replacementString == "[" {
            let nsText = textView.string as NSString
            let insertionLocation = affectedCharRange.location
            if insertionLocation > 0 {
                let prevChar = nsText.substring(with: NSRange(location: insertionLocation - 1, length: 1))
                if prevChar == "[" {
                    let hasAutoCloseBracket = insertionLocation < nsText.length
                        && nsText.substring(with: NSRange(location: insertionLocation, length: 1)) == "]"
                    if hasAutoCloseBracket {
                        // Collapse auto-paired "[]" into "[[]]" without changing surrounding text.
                        MarkdownLists.performEdit(
                            textView,
                            replace: NSRange(location: insertionLocation - 1, length: 2),
                            with: "[[]]"
                        )
                    } else {
                        // If the char to the right is not "]" (e.g. newline), do not delete it.
                        MarkdownLists.performEdit(textView, replace: affectedCharRange, with: "[]]")
                    }
                    textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                    return false
                }
            }
            guard autoClosePairsEnabled else { return true }
            return insertAutoPair(open: "[", close: "]")
        }

        // Autocomplete parentheses / braces
        if replacementString == "(" || replacementString == "{" {
            guard autoClosePairsEnabled else { return true }
            let closeChar = (replacementString == "(") ? ")" : "}"
            return insertAutoPair(open: replacementString, close: closeChar)
        }

        // TAB: indent list items (skip in code blocks)
        if replacementString == "\t" && !isInCodeBlock {
            guard listsEnabled else { return true }
            let nsText = textView.string as NSString
            let insertionLocation = affectedCharRange.location
            let safeLocTAB = min(affectedCharRange.location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocTAB, length: 0))
            let currentLine = nsText.substring(with: currentLineRange)
            if MarkdownLists.listRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) != nil {
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                    let ws = (currentLine as NSString).substring(with: wsMatch.range)
                    let level = MarkdownLists.indentLevel(from: ws)
                    if level >= MarkdownEditorConfiguration.default.lists.maximumNestingLevel {
                        return false
                    }
                }
                MarkdownLists.performEdit(textView, replace: NSRange(location: currentLineRange.location, length: 0), with: "\t")
                textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                return false
            }
            if MarkdownLists.dashNoSpaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) != nil {
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                    let ws = (currentLine as NSString).substring(with: wsMatch.range)
                    let level = MarkdownLists.indentLevel(from: ws)
                    if level >= MarkdownEditorConfiguration.default.lists.maximumNestingLevel { return false }
                }
                MarkdownLists.performEdit(textView, replace: NSRange(location: currentLineRange.location, length: 0), with: "\t")
                textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                return false
            }
            return true
        }

        // SPACE: convert "-" or "1." to proper markers (skip in code blocks)
        if replacementString == " " && !isInCodeBlock {
            guard listsEnabled else { return true }
            let insertionLocation = affectedCharRange.location
            if insertionLocation > 0 {
                let nsText = textView.string as NSString
                let prevCharRange = NSRange(location: insertionLocation - 1, length: 1)
                let prevChar = nsText.substring(with: prevCharRange)
                let currentLineRange = nsText.lineRange(for: NSRange(location: insertionLocation - 1, length: 0))
                let currentLine = nsText.substring(with: currentLineRange)
                if let match = MarkdownLists.numberRegex.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) {
                    let numberRange = match.range(at: 1)
                    let numberString = (currentLine as NSString).substring(with: numberRange)
                    let markerRange = NSRange(location: currentLineRange.location + match.range.location, length: match.range.length)
                    MarkdownLists.performEdit(textView, replace: markerRange, with: "\t\(numberString). ")
                    return false
                }
                if prevChar == "-" {
                    let beforePrevIndex = insertionLocation - 2
                    let isAtLineStart: Bool = (beforePrevIndex < 0) || nsText.substring(with: NSRange(location: beforePrevIndex, length: 1)) == "\n"
                    if isAtLineStart {
                        MarkdownLists.performEdit(textView, replace: prevCharRange, with: "\t• ")
                        return false
                    }
                }
            }
        }

        // ENTER: HR expansion and list continuation/outdent
        if replacementString == "\n" {
            let nsText = textView.string as NSString
            let safeLocENTER = min(affectedCharRange.location, nsText.length)
            let currentLineRange = nsText.lineRange(for: NSRange(location: safeLocENTER, length: 0))
            let currentLine = nsText.substring(with: currentLineRange).trimmingCharacters(in: .whitespacesAndNewlines)

            // Horizontal rule expansion
            if currentLine.range(of: "^-{3,}$", options: .regularExpression) != nil {
                let hrFont = (textView as? NativeTextView)?.baseFont
                    ?? textView.font
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let hyphenWidth = ("-" as NSString).size(withAttributes: [.font: hrFont]).width
                let visibleWidth = textView.enclosingScrollView?.contentView.bounds.width
                                    ?? textView.textContainer?.containerSize.width
                                    ?? textView.bounds.width
                let count = Int(visibleWidth / hyphenWidth)
                let fullLine = String(repeating: "-", count: max(count, 3))
                let newString = fullLine + "\n"
                MarkdownLists.performEdit(textView, replace: currentLineRange, with: newString)
                textView.setSelectedRange(NSRange(location: currentLineRange.location + fullLine.count + 1, length: 0))
                return false
            }

            if currentLine.range(of: "^```\\w*$", options: .regularExpression) != nil {
                let textBeforeLine = nsText.substring(to: currentLineRange.location)
                let openingCount = textBeforeLine.components(separatedBy: "```").count - 1
                let afterLineStart = currentLineRange.location + currentLineRange.length
                let hasClosingAfter: Bool = {
                    guard afterLineStart < nsText.length else { return false }
                    return nsText.substring(from: afterLineStart).contains("```")
                }()
                let lineEnd = currentLineRange.location + max(0, currentLineRange.length - 1)
                let cursorAtLineEnd = affectedCharRange.location >= lineEnd

                if openingCount.isMultiple(of: 2) && cursorAtLineEnd && !hasClosingAfter {
                    let insertionLocation = affectedCharRange.location
                    let completion = "\n\n```"
                    MarkdownLists.performEdit(textView, replace: affectedCharRange, with: completion)
                    textView.setSelectedRange(NSRange(location: insertionLocation + 1, length: 0))
                    return false
                }
            }

            // Skip list continuation in code blocks
            guard listsEnabled && !isInCodeBlock else { return true }
            let listLine = nsText.substring(with: currentLineRange)
            if let match = MarkdownLists.listRegex.firstMatch(in: listLine, range: NSRange(location: 0, length: listLine.utf16.count)) {
                let contentStart = match.range.location + match.range.length
                let contentLength = listLine.utf16.count - contentStart
                let contentRangeLocal = NSRange(location: contentStart, length: contentLength)
                let contentText = (listLine as NSString).substring(with: contentRangeLocal).trimmingCharacters(in: .whitespacesAndNewlines)
                let coord = textView.delegate as? NativeTextViewWrapper.Coordinator
                // Exit the list only when Enter is pressed on a still-empty
                // item that was itself just created by an Enter continuation
                // (i.e. the second consecutive Enter on an empty item). The
                // first Enter on an empty item continues the list instead.
                let isFreshContinuation: Bool = {
                    guard let coord,
                          coord.freshListContinuationDocumentId == coord.documentId,
                          let lineStart = coord.freshListContinuationLineStart else {
                        return false
                    }
                    return lineStart == currentLineRange.location
                }()
                if contentText.isEmpty && isFreshContinuation {
                    coord?.freshListContinuationLineStart = nil
                    let removalLengthRaw = match.range.location + match.range.length
                    let lineEnd = currentLineRange.location + currentLineRange.length
                    let hasNewline = currentLineRange.length > 0 && (textView.string as NSString).substring(with: NSRange(location: lineEnd - 1, length: 1)) == "\n"
                    let maxBodyLen = hasNewline ? currentLineRange.length - 1 : currentLineRange.length
                    let removalLength = min(removalLengthRaw, maxBodyLen)
                    let removalRange = NSRange(location: currentLineRange.location, length: removalLength)
                    MarkdownLists.performEdit(textView, replace: removalRange, with: "")
                    textView.setSelectedRange(NSRange(location: currentLineRange.location, length: 0))
                    return false
                }
                let leadingWhitespace: String
                if let wsMatch = MarkdownLists.leadingWhitespaceRegex.firstMatch(in: listLine, range: NSRange(location: 0, length: listLine.utf16.count)) {
                    leadingWhitespace = (listLine as NSString).substring(with: wsMatch.range)
                } else {
                    leadingWhitespace = ""
                }
                let markerRaw = (listLine as NSString).substring(with: match.range(at: 1))
                let marker = markerRaw.trimmingCharacters(in: .whitespaces)
                let hasCheckbox = marker.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil
                let newListItem: String
                if match.range(at: 2).location != NSNotFound,
                   let number = Int((listLine as NSString).substring(with: match.range(at: 2))) {
                    if hasCheckbox {
                        newListItem = "\n" + leadingWhitespace + "\(number + 1). [ ] "
                    } else {
                        newListItem = "\n" + leadingWhitespace + "\(number + 1). "
                    }
                } else {
                    // Continue at the parent's indentation. (Previously an
                    // unindented parent forced two spaces here, so the
                    // continued item rendered deeper than its parent.)
                    let prefixIndent = leadingWhitespace
                    if hasCheckbox {
                        let bulletChar = marker.contains("•") ? "•" : "-"
                        newListItem = "\n" + prefixIndent + "\(bulletChar) [ ] "
                    } else {
                        newListItem = "\n" + prefixIndent + marker + " "
                    }
                }
                MarkdownLists.performEdit(textView, replace: affectedCharRange, with: newListItem)
                // Remember the continued line (starts right after the
                // inserted "\n") so a second Enter on it while still empty
                // exits the list instead of adding yet another item.
                coord?.freshListContinuationLineStart = affectedCharRange.location + 1
                coord?.freshListContinuationDocumentId = coord?.documentId
                return false
            }
        }

        return true
    }
}

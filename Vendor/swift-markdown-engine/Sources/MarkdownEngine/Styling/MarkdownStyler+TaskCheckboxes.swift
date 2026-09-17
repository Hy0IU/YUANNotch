//
//  MarkdownStyler+TaskCheckboxes.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  GitHub-style `- [ ] / - [x]` task checkbox styling and strike-through.
//
//  A task item renders as a drawn square that *replaces* its whole syntax: the
//  marker and the whitespace behind it are collapsed to zero advance, so the
//  square lands on the column every other list marker shares and the item text
//  follows right behind it. The syntax is never revealed — clicking the square
//  is how an item is toggled (`NativeTextView.toggleTaskCheckboxIfHit`).
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Task List Checkboxes

    static func styleTaskCheckboxes(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let taskMatches = MarkdownStyler.taskListRegex.matches(in: ctx.text, options: [], range: ctx.fullRange)
        for match in taskMatches {
            let markerRange = match.range(at: 2)
            let spacerRange = match.range(at: 3)
            let checkboxRange = match.range(at: 4)
            if checkboxRange.location == NSNotFound { continue }
            if MarkdownDetection.isInsideCodeBlock(range: checkboxRange, codeTokens: ctx.codeTokens) { continue }
            let checkboxText = ctx.nsText.substring(with: checkboxRange)
            let isChecked = checkboxText.range(of: "[x]", options: [.caseInsensitive]) != nil

            if markerRange.location != NSNotFound {
                if isChecked {
                    let lineRange = ctx.nsText.lineRange(for: checkboxRange)
                    var lineEnd = lineRange.location + lineRange.length
                    if lineEnd > lineRange.location {
                        let lastCharRange = NSRange(location: lineEnd - 1, length: 1)
                        if ctx.nsText.substring(with: lastCharRange) == "\n" {
                            lineEnd -= 1
                        }
                    }
                    var contentStart = checkboxRange.location + checkboxRange.length
                    while contentStart < lineEnd {
                        let charRange = NSRange(location: contentStart, length: 1)
                        let char = ctx.nsText.substring(with: charRange)
                        if char == " " || char == "\t" {
                            contentStart += 1
                            continue
                        }
                        break
                    }
                    if contentStart < lineEnd {
                        attrs.append((NSRange(location: contentStart, length: lineEnd - contentStart), [
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: ctx.configuration.theme.strikethroughColor
                        ]))
                    }
                }

                // The drawn square replaces the whole `- [ ]` syntax, so the
                // marker and the whitespace behind it are collapsed to zero
                // advance instead of merely being painted clear — otherwise the
                // square would sit a whole marker width to the right of the
                // column every other list marker shares.
                // `MarkdownLists.paragraphAttributes` measures the hanging
                // indent from the `[` onward for the same reason.
                for hiddenRange in [markerRange, spacerRange] where hiddenRange.location != NSNotFound {
                    let hiddenText = ctx.nsText.substring(with: hiddenRange)
                    attrs.append((hiddenRange, [
                        .foregroundColor: NSColor.clear,
                        .kern: -HeadingHelpers.textWidth(hiddenText, font: ctx.baseFont)
                    ]))
                }

                // A little air between the square and the item text.
                let afterCheckboxIndex = checkboxRange.location + checkboxRange.length
                if !isChecked, afterCheckboxIndex < ctx.nsText.length {
                    let spaceRange = NSRange(location: afterCheckboxIndex, length: 1)
                    if ctx.nsText.substring(with: spaceRange) == " " {
                        let extraSpacing = HeadingHelpers.checkboxExtraSpacing(
                            font: ctx.baseFont,
                            configuration: ctx.configuration.checkbox
                        )
                        attrs.append((spaceRange, [.kern: extraSpacing]))
                    }
                }
            }
            attrs.append((checkboxRange, [
                .taskCheckbox: isChecked,
                .foregroundColor: NSColor.clear
            ]))
        }
        return attrs
    }
}

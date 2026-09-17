//
//  MarkdownStyler+ListMarkers.swift
//  MarkdownEngine
//
//  Colors a list line's marker glyph (`-`, `•`, `1.`) and, for a bullet,
//  draws it larger than the body font.
//
//  Which runs are markers comes from `MarkdownLists.listLines`, the same
//  recognition the hanging indent is derived from — so the glyph this paints
//  is by construction the glyph the indent was measured against.
//
//  Growing the glyph is done by giving it a larger font, which also grows the
//  run's advance and would push the item's text off the column the paragraph
//  style puts every list item's text on. A negative kern of exactly that
//  growth cancels it: the glyph ends up larger on screen while the run keeps
//  the width the indent was measured from. The font's own metrics move the
//  glyph upward as it scales, so `HeadingHelpers.markerBaselineOffset` returns
//  it to the height the body-size glyph sat at.
//
//  A task item is skipped: its square replaces the whole marker zone (see
//  `MarkdownStyler+TaskCheckboxes`), so coloring the glyph would paint a
//  character the user is not meant to see.
//

import AppKit
import Foundation

extension MarkdownStyler {

    static func styleListMarkers(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        guard ctx.configuration.lists.helpersEnabled else { return attrs }

        for line in MarkdownLists.listLines(in: ctx.text, range: ctx.fullRange) {
            if line.isTaskItem { continue }
            if MarkdownDetection.isInsideCodeBlock(range: line.range, codeTokens: ctx.codeTokens) { continue }
            let glyph = ctx.nsText.substring(with: line.markerGlyph)
            guard !glyph.isEmpty else { continue }

            var markerAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: ctx.configuration.theme.listMarker
            ]
            // Only a bullet grows. An ordered marker opens with a digit; the
            // digits spell the item's position and are read as text, so they
            // keep the size the surrounding text is set in.
            if glyph.first?.isNumber != true, ctx.configuration.lists.bulletFontScale > 1 {
                let scaledFont = NSFont(
                    descriptor: ctx.baseFont.fontDescriptor,
                    size: ctx.baseFont.pointSize * ctx.configuration.lists.bulletFontScale
                ) ?? NSFont.systemFont(ofSize: ctx.baseFont.pointSize * ctx.configuration.lists.bulletFontScale)
                markerAttrs[.font] = scaledFont
                markerAttrs[.kern] = HeadingHelpers.textWidth(glyph, font: ctx.baseFont)
                    - HeadingHelpers.textWidth(glyph, font: scaledFont)
                markerAttrs[.baselineOffset] = HeadingHelpers.markerBaselineOffset(
                    glyph: glyph,
                    baseFont: ctx.baseFont,
                    scaledFont: scaledFont
                )
            }
            attrs.append((line.markerGlyph, markerAttrs))
        }
        return attrs
    }
}

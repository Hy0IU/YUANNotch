//
//  MarkdownStyler+ListMarkers.swift
//  MarkdownEngine
//
//  Unordered glyphs are drawn in the shared list-marker slot by the layout
//  fragment. Their source characters keep body-font metrics, so a large
//  marker cannot alter line height or move the text column.
//  Ordered numbers remain normal text and retain their full source width.
//  Task squares use the same slot instead of drawing their source glyph.
//

import AppKit
import Foundation

extension MarkdownStyler {

    static func styleListMarkers(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        guard ctx.configuration.lists.helpersEnabled else { return attrs }
        let lines = MarkdownLists.listLines(in: ctx.text, range: ctx.fullRange)
        guard !lines.isEmpty else { return attrs }
        let textOffset = HeadingHelpers.listTextOffset(font: ctx.baseFont, configuration: ctx.configuration)

        for line in lines {
            if line.isTaskItem { continue }
            if MarkdownDetection.isInsideCodeBlock(range: line.markerGlyph, codeTokens: ctx.codeTokens) { continue }
            let glyph = ctx.nsText.substring(with: line.markerGlyph)
            guard !glyph.isEmpty else { continue }

            if glyph.first?.isNumber == true {
                attrs.append((line.markerGlyph, [.foregroundColor: ctx.configuration.theme.listMarker]))
                if let spacing = MarkdownLists.markerSpacing(
                    for: line, in: ctx.nsText, font: ctx.baseFont, style: ctx.configuration.lists
                ) {
                    attrs.append((spacing.range, [.kern: spacing.width]))
                }
            } else {
                attrs.append((line.markerGlyph, [
                    .foregroundColor: NSColor.clear,
                    .listMarkerGlyph: glyph
                ]))
                if let adjustment = MarkdownLists.unorderedMarkerAdjustment(
                    for: line, in: ctx.nsText, font: ctx.baseFont, textOffset: textOffset
                ) {
                    attrs.append((adjustment.range, [.kern: adjustment.width]))
                }
            }
        }
        return attrs
    }
}

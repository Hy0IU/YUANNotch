//
//  HeadingHelpers.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Small helper values for heading size/spacing, plus shared text measurements.
import AppKit
import CoreText

enum HeadingHelpers {

    static func headingFontMultiplier(
        for level: Int,
        configuration: HeadingStyle = .default
    ) -> CGFloat {
        configuration.fontMultiplier(for: level)
    }

    static func headingTopSpacingEm(
        for level: Int,
        configuration: HeadingStyle = .default
    ) -> CGFloat {
        configuration.topSpacingEm(for: level)
    }

    /// Use heading context to scale LaTeX font size consistently with surrounding text.
    static func latexFontSize(
        for token: MarkdownToken,
        tokens: [MarkdownToken],
        baseFont: NSFont,
        configuration: HeadingStyle = .default
    ) -> CGFloat {
        if let headingToken = tokens.first(where: { $0.kind == .heading && NSLocationInRange(token.contentRange.location, $0.contentRange) }) {
            let level = headingToken.markerRanges.first?.length ?? 1
            return baseFont.pointSize * configuration.fontMultiplier(for: level)
        }
        return baseFont.pointSize
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Baseline offset that makes `glyph` drawn in `scaledFont` sit where the
    /// same glyph drawn in `baseFont` does.
    ///
    /// A font's own vertical metrics scale with its point size, and so does
    /// the glyph's ink box — which grows upward from the baseline. Drawing a
    /// marker glyph larger therefore lifts it as well as enlarging it, by the
    /// distance its ink centre travelled. Measuring that distance is the only
    /// way to enlarge a glyph in place: a constant would be wrong at any other
    /// font size.
    static func markerBaselineOffset(
        glyph: String,
        baseFont: NSFont,
        scaledFont: NSFont
    ) -> CGFloat {
        inkCenterAboveBaseline(glyph: glyph, font: baseFont)
            - inkCenterAboveBaseline(glyph: glyph, font: scaledFont)
    }

    /// Distance from the baseline to the centre of `glyph`'s ink box, in
    /// points. Zero when the font cannot map the character, which leaves the
    /// glyph where the font puts it rather than shifting it on a guess.
    private static func inkCenterAboveBaseline(glyph: String, font: NSFont) -> CGFloat {
        let utf16 = Array(glyph.utf16)
        guard !utf16.isEmpty else { return 0 }
        let ctFont = font as CTFont
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(ctFont, utf16, &glyphs, utf16.count) else { return 0 }
        let ink = CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, glyphs, nil, 1)
        return ink.origin.y + ink.height / 2
    }

    /// Air between a task item's square and its text. Not part of the square's
    /// own size — it is what keeps the two from touching.
    static func checkboxExtraSpacing(
        font: NSFont,
        configuration: CheckboxStyle = .default
    ) -> CGFloat {
        max(
            configuration.minimumExtraSpacing,
            ceil(font.pointSize * configuration.extraSpacingPerFontPointFraction)
        )
    }

    /// The `[ ]` slot a task item's square stands in for. Both the square's size
    /// and the column the item text starts at are measured from this slot —
    /// never from the brackets the source actually spells, because those are
    /// collapsed to zero advance and never drawn. Letting them reach the layout
    /// would move the text beside them every time an item is ticked.
    static let checkboxSlot = "[ ]"

    /// Side of a task square, in points: bounded by the line's font height and
    /// by the `[ ]` slot the square replaces.
    static func checkboxSize(
        font: NSFont,
        configuration: CheckboxStyle = .default
    ) -> CGFloat {
        let fontHeight = max(1, ceil(max(0, font.ascender) + max(0, -font.descender)))
        return max(
            1.0,
            min(
                floor(fontHeight * configuration.sizeFromFontHeightFactor),
                floor(textWidth(checkboxSlot, font: font) * configuration.sizeFromMarkerWidthFactor)
            )
        )
    }

    /// Width of a task item's marker zone, from the item's marker column to the
    /// column its text starts at: the `[ ]` slot the square stands in for, the
    /// space behind it, and the air between square and text. The list handler
    /// takes the hanging indent from it and the styler the advance behind the
    /// brackets — deriving it once is what keeps a ticked and an unticked item
    /// on the same text column.
    static func checkboxMarkerWidth(
        font: NSFont,
        configuration: CheckboxStyle = .default
    ) -> CGFloat {
        textWidth(checkboxSlot, font: font)
            + textWidth(" ", font: font)
            + checkboxExtraSpacing(font: font, configuration: configuration)
    }
}

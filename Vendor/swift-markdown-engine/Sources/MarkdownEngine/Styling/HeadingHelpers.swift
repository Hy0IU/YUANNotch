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

    /// Return a marker's glyph and its ink bounds in the same font mapping.
    static func markerGlyphAndInk(_ character: UniChar, font: NSFont) -> (glyph: CGGlyph, bounds: CGRect)? {
        var character = character
        var glyph: CGGlyph = 0
        let ctFont = font as CTFont
        guard CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) else { return nil }
        let bounds = CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, nil, 1)
        return (glyph, bounds)
    }

    /// Keep the scaled glyph's ink center at the body-sized glyph's height.
    static func markerBaselineOffset(character: UniChar, baseFont: NSFont, scaledInk: CGRect) -> CGFloat {
        (markerGlyphAndInk(character, font: baseFont)?.bounds.midY ?? 0) - scaledInk.midY
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

    /// A stable slot for sizing the square, independent of whether the source
    /// spells `[ ]` or `[x]`. The styler compensates for the actual brackets'
    /// advance so both states leave the item text in the same column.
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

    /// All unordered and task markers share this slot. Its width covers both
    /// the checkbox and the ink of either supported unordered glyph.
    static func listMarkerFont(baseFont: NSFont, configuration: ListStyle) -> NSFont {
        let size = baseFont.pointSize * max(1, configuration.bulletFontScale)
        return NSFont(descriptor: baseFont.fontDescriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    static func markerInkBounds(_ character: UniChar, font: NSFont) -> CGRect {
        markerGlyphAndInk(character, font: font)?.bounds ?? .zero
    }

    static func listMarkerSlotWidth(font: NSFont, configuration: MarkdownEditorConfiguration) -> CGFloat {
        let markerFont = listMarkerFont(baseFont: font, configuration: configuration.lists)
        let bulletWidth = markerInkBounds(0x2022, font: markerFont).width
        let dashWidth = markerInkBounds(0x002D, font: markerFont).width
        return max(checkboxSize(font: font, configuration: configuration.checkbox), ceil(max(bulletWidth, dashWidth)))
    }

    /// Share the checkbox's pixel-aligned center with the drawn glyph.
    static func listMarkerCenterX(origin: CGFloat, slotWidth: CGFloat, checkboxSize: CGFloat, scale: CGFloat) -> CGFloat {
        let left = origin + (slotWidth - checkboxSize) / 2
        return (left * scale).rounded(.toNearestOrAwayFromZero) / scale + checkboxSize / 2
    }

    /// The text column is measured once for both the hanging indent and the
    /// source runs that precede the text; wide separators retain their excess.
    static func listTextOffset(font: NSFont, configuration: MarkdownEditorConfiguration) -> CGFloat {
        let gap = max(
            font.pointSize * configuration.lists.markerSpacingEm,
            checkboxExtraSpacing(font: font, configuration: configuration.checkbox)
        )
        return listMarkerSlotWidth(font: font, configuration: configuration)
            + textWidth(" ", font: font) + gap
    }
}

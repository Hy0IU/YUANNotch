import AppKit
import MarkdownEngine
import SwiftUI

/// The same semantic orange used by the timer, resolved by AppKit at drawing time.
enum NoteMarkdownStyle {
    static func configuration(fontSize: CGFloat, services: MarkdownEditorServices = .default) -> MarkdownEditorConfiguration {
        let accent = NSColor(Color.orange)
        let theme = MarkdownEditorTheme(
            bodyText: NSColor(white: 0.92, alpha: 1),
            mutedText: accent,
            disabledText: accent,
            headingMarker: accent,
            listMarker: accent,
            link: accent,
            incompleteLink: accent,
            findMatchHighlight: NSColor.systemYellow.withAlphaComponent(0.55),
            findCurrentMatchHighlight: NSColor.systemYellow,
            latexLightModeText: .white,
            latexDarkModeText: .white,
            strikethroughColor: accent,
            checkboxBorder: accent,
            checkboxCheckedFill: accent
        )

        return MarkdownEditorConfiguration(
            theme: theme,
            services: services,
            lists: ListStyle(indentPerLevel: fontSize * 0.75, extraLineHeight: 1, bulletFontScale: 1.6, markerSpacingEm: 0.15),
            imageEmbed: ImageEmbedStyle(fallbackMaxWidth: 440, paragraphSpacing: 6, imageGap: 6),
            checkbox: CheckboxStyle(sizeFromFontHeightFactor: 1.0, sizeFromMarkerWidthFactor: 1.0),
            link: LinkStyle(activeLinkAlpha: 1, incompleteLinkAlpha: 1),
            overscroll: OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0),
            dragSelection: DragSelectionPolicy(movementThreshold: 8, edgeTriggerDistance: 8, scrollStepPerTick: 4, ticksPerSecond: 30),
            scrollers: .vertical,
            textInsets: TextInsets(horizontal: 12, vertical: 12)
        )
    }
}

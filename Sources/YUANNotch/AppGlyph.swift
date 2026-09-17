import AppKit
import SwiftUI

/// The app's mark, defined once for every surface that draws it.
///
/// The artwork is exported into the package resource bundle as `Glyph/Glyph.png`
/// (18 pt) and `Glyph/Glyph@2x.png` (36 pt), both monochrome on transparent.
/// Replacing those two files is the whole job — no call site names the artwork,
/// its point size, or its tint.
enum AppGlyph {

    /// Point box the artwork is authored in. The mark fills 16 of these 18
    /// points, which is the optical size of a menu-bar item beside the system
    /// ones.
    static let artworkPointSize: CGFloat = 18

    /// The compact notch is only 28–38 pt tall, so the mark sits smaller there.
    static let notchPointSize: CGFloat = 15

    /// Monochrome template: the menu bar lets AppKit supply the colour, and the
    /// notch tints it through `renderingMode(.template)`.
    @MainActor
    static let templateImage: NSImage = loadTemplateImage()

    @MainActor
    private static func loadTemplateImage() -> NSImage {
        let pointSize = NSSize(width: artworkPointSize, height: artworkPointSize)
        let image = NSImage(size: pointSize)

        for fileName in ["Glyph", "Glyph@2x"] {
            guard let url = resourceBundle().url(
                    forResource: fileName,
                    withExtension: "png",
                    subdirectory: "Glyph"
                  ),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data)
            else { continue }

            // Declaring the pixel size as `artworkPointSize` is what lets AppKit
            // pick the 36 px rep on a Retina display and the 18 px rep otherwise.
            representation.size = pointSize
            image.addRepresentation(representation)
        }

        // A template image with no representations draws nothing, which would
        // read as a deliberately blank icon. Fail loudly instead: the artwork is
        // compiled into the bundle, so absence means the bundle was not shipped.
        guard !image.representations.isEmpty else {
            fatalError("Glyph artwork is missing from \(resourceBundle().bundlePath)")
        }

        image.isTemplate = true
        return image
    }

    /// The executable's own directory: `.build/<config>/` under `swift run`,
    /// `Contents/MacOS/` once packaged.
    ///
    /// `Bundle.module` is deliberately not used. SwiftPM generates its lookup as
    /// `Bundle.main.bundleURL + "<name>.bundle"`, and inside a `.app` that
    /// resolves to the bundle's *root* — a location macOS allows only `Contents`
    /// in, so honouring it would mean shipping a non-conformant app bundle.
    /// Anchoring to the executable keeps the standard layout on both paths.
    @MainActor
    private static func resourceBundle() -> Bundle {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let url = executable.deletingLastPathComponent().appendingPathComponent(resourceBundleName)
        guard let bundle = Bundle(url: url) else {
            fatalError("Glyph resource bundle is missing: expected \(url.path)")
        }
        return bundle
    }

    /// SwiftPM names a target's resource bundle after the package and the target.
    private static let resourceBundleName = "YUANNotch_YUANNotch.bundle"
}

/// The mark, at a size chosen by the surrounding layout and tinted for the
/// surface it sits on.
struct AppGlyphMark: View {
    var pointSize: CGFloat = AppGlyph.notchPointSize

    /// The compact notch draws on its own near-black capsule, so the mark is
    /// white there rather than following the system appearance.
    var tint: Color = .white.opacity(0.82)

    var body: some View {
        Image(nsImage: AppGlyph.templateImage)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: pointSize, height: pointSize)
            .foregroundStyle(tint)
    }
}

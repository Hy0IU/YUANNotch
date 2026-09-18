import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// YUANNotch · app-mark generator
//
// The mark is a monoline drawing built from five primitives, so its weight, the
// inner ring's size and its height are each one number. This tool is the single
// source of truth for the geometry; it renders the three tracked PNGs and prints
// every clearance between parts, so a weight change can be judged before it is
// drawn.
//
// The fitted constants came from ray-casting the artwork that shipped before
// this tool existed. That raster's outer ring is a slight ellipse, 438.9 x 436.9,
// normalised here to a circle of 437.9; its inner ring is a true circle of
// centreline radius 156.5 whose centre sits 17.9 px above the outer ring's.
//
//   make-glyph <repo-root> [--baseline] [--out-dir <dir>]
//
//   --baseline  render the pre-existing weight and spacing, so the fit can be
//               re-verified against the artwork it was fitted to
//   --out-dir   write flat filenames into this directory instead of the tracked
//               paths under <repo-root>

// MARK: - geometry

/// Measured, not chosen.
private enum Fitted {
    static let canvas: CGFloat = 989
    static let centreX: CGFloat = 493.0
    static let centreY: CGFloat = 494.75
    /// Outer ring's outer edge. Pinned, so the mark keeps filling 16 of the 18
    /// authored points however thick the stroke gets.
    static let outerEdge: CGFloat = 437.9
    static let spineX: CGFloat = 493.0
    static let dashOffsetX: CGFloat = 188.25
    static let dashedCentreY: CGFloat = 697.5
    static let innerRadius: CGFloat = 156.5
    static let innerCentreY: CGFloat = 476.86
    static let dashLength: CGFloat = 156
    static let barLength: CGFloat = 161
    static let barThicknessRatio: CGFloat = 0.8966
}

/// The design: every value here is a decision.
private struct MarkDesign {
    var stroke: CGFloat
    var innerRadius: CGFloat
    var innerCentreY: CGFloat
    var dashCentreY: CGFloat
    var dashLength: CGFloat

    /// What shipped before the 2026-09-18 weight pass.
    static let original = MarkDesign(
        stroke: 43.5,
        innerRadius: Fitted.innerRadius,
        innerCentreY: Fitted.innerCentreY,
        dashCentreY: Fitted.dashedCentreY,
        dashLength: Fitted.dashLength
    )

    /// 1.25 pt of the 18 pt box — 2.49 px at 2x against 1.58 px before. The inner
    /// ring grows 15% and rises 48 master px (1.75 px at 2x, 8.8% of the exported
    /// width). At this weight the two dashes are the first thing to run out of
    /// room, so they keep their length and rise 13 px with the ring; see the
    /// clearance report this tool prints.
    static let current = MarkDesign(
        stroke: 68.5,
        innerRadius: Fitted.innerRadius * 1.15,
        innerCentreY: Fitted.innerCentreY - 48,
        dashCentreY: Fitted.dashedCentreY - 13,
        dashLength: Fitted.dashLength
    )

    var half: CGFloat { stroke / 2 }

    /// The bar's length follows the ring it sits in; its thickness follows the
    /// stroke, so the mark stays one family at any weight.
    var barLength: CGFloat { Fitted.barLength * innerRadius / Fitted.innerRadius }

    var barThickness: CGFloat { Fitted.barThicknessRatio * stroke }

    // MARK: clearances

    /// Boundary of a round-capped rectangle. Every gap below is the smallest
    /// ink-to-ink distance, measured from the shapes that are drawn.
    private static func capsuleOutline(cx: CGFloat, cy: CGFloat,
                                       halfWidth: CGFloat, halfHeight: CGFloat,
                                       samples: Int = 360) -> [CGPoint] {
        let r = min(halfWidth, halfHeight)
        let sx = halfWidth - r
        let sy = halfHeight - r
        return (0..<samples).map { i in
            let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(samples)
            let x = cos(t) * r
            let y = sin(t) * r
            return CGPoint(x: cx + x + (x > 0 ? sx : -sx),
                           y: cy + y + (y > 0 ? sy : -sy))
        }
    }

    private func dashOutline(sign: CGFloat) -> [CGPoint] {
        Self.capsuleOutline(cx: Fitted.centreX + sign * Fitted.dashOffsetX,
                            cy: dashCentreY, halfWidth: half, halfHeight: dashLength / 2)
    }

    private var barOutline: [CGPoint] {
        Self.capsuleOutline(cx: Fitted.centreX, cy: innerCentreY,
                            halfWidth: barLength / 2, halfHeight: barThickness / 2)
    }

    private func distance(_ p: CGPoint, to centre: CGPoint) -> CGFloat {
        let dx = p.x - centre.x
        let dy = p.y - centre.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Smallest ink-to-ink gap per facing pair, in master px.
    func clearances() -> [(name: String, gap: CGFloat)] {
        let outerInnerRadius = Fitted.outerEdge - stroke
        let innerOuterRadius = innerRadius + half
        let innerInnerRadius = innerRadius - half
        let ringCentre = CGPoint(x: Fitted.centreX, y: Fitted.centreY)
        let innerCentre = CGPoint(x: Fitted.centreX, y: innerCentreY)

        var toOuter = CGFloat.greatestFiniteMagnitude
        var toInner = CGFloat.greatestFiniteMagnitude
        var toSpine = CGFloat.greatestFiniteMagnitude
        for sign in [CGFloat(-1), CGFloat(1)] {
            for p in dashOutline(sign: sign) {
                toOuter = min(toOuter, outerInnerRadius - distance(p, to: ringCentre))
                toInner = min(toInner, distance(p, to: innerCentre) - innerOuterRadius)
                toSpine = min(toSpine, abs(p.x - Fitted.spineX) - half)
            }
        }
        let barReach = barOutline.map { distance($0, to: innerCentre) }.max() ?? 0
        return [
            ("短划线 → 外环", toOuter),
            ("短划线 → 内环", toInner),
            ("短划线 → 脊柱", toSpine),
            ("横杆   → 内环", innerInnerRadius - barReach),
            ("内环   → 外环", outerInnerRadius - innerOuterRadius),
        ]
    }

    /// Everything except the ring-to-ring gap, which is never the binding one.
    func minGap() -> CGFloat {
        clearances().dropLast().map(\.gap).min() ?? 0
    }

    // MARK: drawing

    /// Renders the mark at `size` px square. Coordinates are master units, so
    /// the exported rep is the geometry drawn at its own size — the artwork is
    /// never resampled down from the master.
    func draw(size: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setShouldAntialias(true)
        // A bitmap context has its origin at the bottom left; the geometry is
        // measured from the top left, as the artwork always was.
        ctx.translateBy(x: 0, y: CGFloat(size))
        let k = CGFloat(size) / Fitted.canvas
        ctx.scaleBy(x: k, y: -k)

        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let ringCentre = CGPoint(x: Fitted.centreX, y: Fitted.centreY)
        let innerCentre = CGPoint(x: Fitted.centreX, y: innerCentreY)

        fillRing(ctx, centre: ringCentre, radius: Fitted.outerEdge - half, width: stroke)
        fillCapsule(ctx, centre: CGPoint(x: Fitted.spineX, y: Fitted.centreY),
                    halfWidth: half, halfHeight: Fitted.outerEdge)
        // the inner ring's interior knocks the spine out
        ctx.setBlendMode(.clear)
        fillEllipse(ctx, centre: innerCentre, radius: innerRadius - half)
        ctx.setBlendMode(.normal)
        fillRing(ctx, centre: innerCentre, radius: innerRadius, width: stroke)
        fillCapsule(ctx, centre: innerCentre,
                    halfWidth: barLength / 2, halfHeight: barThickness / 2)
        for sign in [CGFloat(-1), CGFloat(1)] {
            fillCapsule(ctx, centre: CGPoint(x: Fitted.centreX + sign * Fitted.dashOffsetX,
                                             y: dashCentreY),
                        halfWidth: half, halfHeight: dashLength / 2)
        }
        return ctx.makeImage()
    }
}

// MARK: - drawing helpers

private func fillEllipse(_ ctx: CGContext, centre: CGPoint, radius: CGFloat) {
    ctx.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                               width: radius * 2, height: radius * 2))
}

/// Annulus: both edges of the stroke are centreline ± width/2, filled even-odd.
private func fillRing(_ ctx: CGContext, centre: CGPoint, radius: CGFloat, width: CGFloat) {
    let outer = radius + width / 2
    let inner = radius - width / 2
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: centre.x - outer, y: centre.y - outer,
                               width: outer * 2, height: outer * 2))
    path.addEllipse(in: CGRect(x: centre.x - inner, y: centre.y - inner,
                               width: inner * 2, height: inner * 2))
    ctx.addPath(path)
    ctx.fillPath(using: .evenOdd)
}

private func fillCapsule(_ ctx: CGContext, centre: CGPoint,
                         halfWidth: CGFloat, halfHeight: CGFloat) {
    let r = min(halfWidth, halfHeight)
    let path = CGPath(roundedRect: CGRect(x: centre.x - halfWidth, y: centre.y - halfHeight,
                                          width: halfWidth * 2, height: halfHeight * 2),
                      cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
}

// MARK: - output

private func write(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-glyph", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-glyph", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "cannot finalise \(url.path)"])
    }
}

private func report(_ design: MarkDesign, title: String) {
    print("=== \(title) ===")
    print(String(format: "  线宽    %.1f 母版 px = %.2f pt（18 pt 字框）= %.2f px @36",
                 design.stroke, design.stroke / Fitted.canvas * 18,
                 design.stroke * 36 / Fitted.canvas))
    print(String(format: "  内环    中心线半径 %.1f，外径 %.2f px @36；圆心 y %.2f（较外环中心 %+.1f px）",
                 design.innerRadius, (design.innerRadius * 2 + design.stroke) * 36 / Fitted.canvas,
                 design.innerCentreY, design.innerCentreY - Fitted.centreY))
    print(String(format: "  短划线  长 %.1f，y %.1f（较原始中心 %+.1f px）；横杆 长 %.1f 厚 %.1f",
                 design.dashLength, design.dashCentreY,
                 design.dashCentreY - Fitted.dashedCentreY,
                 design.barLength, design.barThickness))
    for (name, gap) in design.clearances() {
        print(String(format: "  %@  %6.1f px = %.2f px @36", name, gap, gap * 36 / Fitted.canvas))
    }
    print(String(format: "  最紧间隙 %.1f px = %.2f px @36",
                 design.minGap(), design.minGap() * 36 / Fitted.canvas))
    print("")
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
guard let root = args.first, !root.hasPrefix("-") else {
    FileHandle.standardError.write(
        "usage: make-glyph <repo-root> [--baseline] [--out-dir <dir>]\n".data(using: .utf8)!)
    exit(2)
}
let baseline = args.contains("--baseline")
var outDir: String? = nil
if let i = args.firstIndex(of: "--out-dir"), i + 1 < args.count {
    outDir = args[args.index(after: i)]
}
private let design = baseline ? MarkDesign.original : MarkDesign.current
let rootURL = URL(fileURLWithPath: root)

report(design, title: baseline ? "基线（本次改动之前的线宽与间距）" : "当前设计")

let targets: [(path: String, size: Int, flatName: String)] = [
    ("Resources/Glyph.png", 989, "Glyph-master.png"),
    ("Sources/YUANNotch/Glyph/Glyph.png", 18, "Glyph.png"),
    ("Sources/YUANNotch/Glyph/Glyph@2x.png", 36, "Glyph@2x.png"),
]

for target in targets {
    guard let image = design.draw(size: target.size) else {
        FileHandle.standardError.write("failed to render \(target.path)\n".data(using: .utf8)!)
        exit(1)
    }
    let url: URL = outDir.map {
        URL(fileURLWithPath: $0).appendingPathComponent(target.flatName)
    } ?? rootURL.appendingPathComponent(target.path)
    do {
        try write(image, to: url)
        print("wrote \(url.path)  \(target.size)x\(target.size)")
    } catch {
        FileHandle.standardError.write("failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

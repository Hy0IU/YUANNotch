//
//  EmbeddedImageCache.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//

import AppKit
import CoreGraphics

/// Parsed `![[name|optional-id|optional-width]]` reference.
public struct ImageEmbedReference: Sendable {
    private static let markdownRegex = try! NSRegularExpression(
        pattern: "!\\[\\[([^\\]\\r\\n]*)\\]\\]"
    )

    public let name: String
    public let nodeID: UUID?
    public let requestedWidth: CGFloat?

    public init(name: String, nodeID: UUID? = nil, requestedWidth: CGFloat? = nil) {
        self.name = name
        self.nodeID = nodeID
        self.requestedWidth = requestedWidth
    }

    public init?(content: String) {
        let parts = content
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let name = parts.first, !name.isEmpty else { return nil }

        var parsedID: UUID?
        var parsedWidth: CGFloat?

        for part in parts.dropFirst() where !part.isEmpty {
            if parsedID == nil, let id = UUID(uuidString: part) {
                parsedID = id
                continue
            }
            if parsedWidth == nil, let value = Double(part), value > 0 {
                parsedWidth = CGFloat(value)
            }
        }

        self.init(name: name, nodeID: parsedID, requestedWidth: parsedWidth)
    }

    public static func parse(markdown: String) -> ImageEmbedReference? {
        guard markdown.hasPrefix("![["), markdown.hasSuffix("]]") else { return nil }
        return ImageEmbedReference(content: String(markdown.dropFirst(3).dropLast(2)))
    }

    public static func replacingEmbeds(
        in text: String,
        transform: (ImageEmbedReference) -> String
    ) -> String {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let mutable = NSMutableString(string: text)
        let matches = markdownRegex.matches(in: text, range: fullRange).reversed()

        for match in matches {
            let rawContent = nsText.substring(with: match.range(at: 1))
            guard let reference = ImageEmbedReference(content: rawContent) else { continue }
            mutable.replaceCharacters(in: match.range, with: transform(reference))
        }

        return mutable as String
    }

    public var markdown: String {
        var parts = [name]
        if let nodeID {
            parts.append(nodeID.uuidString)
        }
        if let requestedWidth, requestedWidth > 0 {
            let widthValue = Double(requestedWidth)
            parts.append(widthValue.rounded() == widthValue ? String(Int(widthValue)) : String(widthValue))
        }
        return "![[\(parts.joined(separator: "|"))]]"
    }

    /// Convert to the engine-side request shape consumed by `EmbeddedImageProvider`.
    public var providerRequest: EmbeddedImageRequest {
        EmbeddedImageRequest(
            name: name,
            id: nodeID?.uuidString,
            requestedWidth: requestedWidth
        )
    }
}

/// Caches images returned by an ``EmbeddedImageProvider``. The cache
/// invalidates when the provider's fingerprint changes, so the engine
/// stays correct even when the embedder swaps out its data source.
///
/// The cache holds a copy scaled to the width the styler is about to draw
/// at, and it is bounded: entries are keyed by that width (quantised), cost
/// is accounted in decoded bytes, and ``NSCache`` evicts under pressure.
/// The styling pass asks for every image embed on every keystroke, so a
/// lookup has to be a hit; a miss costs one provider fetch plus one
/// downsample — never a full-resolution image retained for the process's
/// lifetime, which is what an unbounded dictionary of `NSImage`s amounts to
/// once a document embeds a few screenshots.
final class EmbeddedImageCache {
    static let shared = EmbeddedImageCache()
    private init() {}

    /// Decoded bytes the cache may hold before it starts evicting.
    ///
    /// Sized against the drawer this engine is embedded in: a full-width
    /// embed in a 480pt drawer is roughly 3 MB once decoded at Retina
    /// scale, so this holds about ten of them. Eviction is not a
    /// correctness event — the next styling pass fetches and rescales
    /// again.
    private static let totalCostLimit = 32 * 1024 * 1024
    private static let countLimit = 64

    /// Widths are quantised to this step so a window that is resized
    /// continuously converges on a handful of entries rather than one per
    /// pixel of drag.
    private static let widthBucketStep: CGFloat = 64

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = EmbeddedImageCache.countLimit
        cache.totalCostLimit = EmbeddedImageCache.totalCostLimit
        return cache
    }()
    private var lastFingerprint: AnyHashable?

    /// Returns the image for `reference`, re-rasterised so it is never
    /// wider than `targetWidth` points.
    ///
    /// An image whose natural width is already at or below `targetWidth` is
    /// returned as the provider gave it — this downsamples, never enlarges.
    /// The result's `size` is therefore the size to draw at, which is what
    /// lets a caller derive its layout from `image.size` as before.
    ///
    /// The copy is rasterised at the width *bucket*, not at `targetWidth`
    /// itself, so every request in the bucket is served by a copy at least
    /// as wide as it asked for. Scaling to the raw request instead would
    /// hand a widened drawer the narrower copy cached a moment earlier, and
    /// the image would stay small for the whole bucket.
    func image(
        for reference: ImageEmbedReference,
        targetWidth: CGFloat,
        services: MarkdownEditorServices
    ) -> NSImage? {
        let currentFingerprint = services.images.fingerprint()
        if currentFingerprint != lastFingerprint {
            cache.removeAllObjects()
            lastFingerprint = currentFingerprint
        }

        let bucket = Self.widthBucket(targetWidth)
        let key = Self.cacheKey(for: reference, bucket: bucket) as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let image = services.images.image(for: reference.providerRequest) else {
            return nil
        }

        let widthToRasterise = bucket > 0 ? CGFloat(bucket) : targetWidth
        let scaled = Self.downsampled(image, toWidth: widthToRasterise)
        cache.setObject(scaled, forKey: key, cost: Self.cost(of: scaled))
        return scaled
    }

    /// Identity plus the width bucket, so one embed scaled for two drawer
    /// widths is two entries rather than a silently wrong single one.
    private static func cacheKey(for reference: ImageEmbedReference, bucket: Int) -> String {
        let identity = reference.nodeID?.uuidString ?? reference.name
        return "\(identity)|\(bucket)"
    }

    /// Quantises a width upward, so a bucket never holds an image narrower
    /// than the width being drawn.
    static func widthBucket(_ width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 0 }
        let step = Int(widthBucketStep)
        return Int((width / widthBucketStep).rounded(.up)) * step
    }

    /// Decoded bytes the bitmap backing `image` occupies.
    static func cost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else {
            let size = image.size
            return max(0, Int(size.width * size.height)) * 4
        }

        return max(0, rep.pixelsWide * rep.pixelsHigh * 4)
    }

    /// Re-rasterises `image` at `width` points wide.
    ///
    /// The pixels are laid down at the backing store's scale so the result
    /// stays crisp, while `size` reports the point size — the two differ by
    /// design, because the drawing code sizes from `size` and the cache
    /// accounts from the pixels.
    static func downsampled(_ image: NSImage, toWidth width: CGFloat) -> NSImage {
        let naturalSize = image.size
        guard width.isFinite, width > 0, naturalSize.width > width else { return image }

        let scale = width / naturalSize.width
        let pointSize = NSSize(width: width, height: naturalSize.height * scale)
        let backingScale = Self.backingScale
        let pixelsWide = max(1, Int((pointSize.width * backingScale).rounded()))
        let pixelsHigh = max(1, Int((pointSize.height * backingScale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return image
        }

        rep.size = pointSize

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            image.draw(
                in: NSRect(origin: .zero, size: pointSize),
                from: NSRect(origin: .zero, size: naturalSize),
                operation: .copy,
                fraction: 1
            )
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        let scaled = NSImage(size: pointSize)
        scaled.addRepresentation(rep)
        return scaled
    }

    /// The pixel density to rasterise at. The engine has no window of its
    /// own, so it follows the main screen and clamps to the range AppKit
    /// actually produces.
    private static var backingScale: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return min(max(scale, 1), 3)
    }
}

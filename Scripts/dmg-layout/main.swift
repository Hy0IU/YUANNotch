import AppKit
import Foundation

// The window, background and icon positions share the same point coordinates.
enum InstallerLayout {
    static let width = 640
    static let height = 400
    static let iconSize = 80
    static let appPosition = (170, 205)
    static let applicationsPosition = (470, 205)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

extension Data {
    mutating func uint32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func fourCC(_ value: String) {
        precondition(value.utf8.count == 4)
        append(contentsOf: value.utf8)
    }
}

/// A deliberately bounded DS_Store writer: the installer needs one leaf page,
/// not a general-purpose database. Fail instead of emitting a larger tree.
/// Format reference: https://metacpan.org/dist/Mac-Finder-DSStore/view/DSStoreFormat.pod
struct FinderLayoutStore {
    struct Record {
        let name: String
        let code: String
        let type: String
        let payload: Data

        var encoded: Data {
            var data = Data()
            data.uint32(UInt32(name.utf16.count))
            data.append(name.data(using: .utf16BigEndian)!)
            data.fourCC(code)
            data.fourCC(type)
            if type == "blob" { data.uint32(UInt32(payload.count)) }
            data.append(payload)
            return data
        }
    }

    static func write(to url: URL, alias: Data) throws {
        func plist(_ value: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        }
        func icon(_ position: (Int, Int)) -> Data {
            var result = Data()
            result.uint32(UInt32(position.0))
            result.uint32(UInt32(position.1))
            result.append(contentsOf: [255, 255, 255, 255, 255, 255, 0, 0])
            return result
        }
        let window = try plist([
            "WindowBounds": "{{180, 140}, {\(InstallerLayout.width), \(InstallerLayout.height)}}",
            "ShowSidebar": false, "ShowToolbar": false, "ShowStatusBar": false,
            "ShowPathbar": false, "ShowTabView": false, "SidebarWidth": 0,
            "ContainerShowSidebar": false
        ])
        let iconView = try plist([
            "viewOptionsVersion": 1, "arrangeBy": "none", "iconSize": InstallerLayout.iconSize,
            "textSize": 12, "labelOnBottom": true, "showItemInfo": false,
            "showIconPreview": false, "gridSpacing": 100, "gridOffsetX": 0,
            "gridOffsetY": 0, "scrollPositionX": 0, "scrollPositionY": 0,
            "backgroundType": 2, "backgroundImageAlias": alias,
            "backgroundColorRed": 0.96, "backgroundColorGreen": 0.96, "backgroundColorBlue": 0.97
        ])
        let records = [
            Record(name: ".", code: "bwsp", type: "blob", payload: window),
            Record(name: ".", code: "icvp", type: "blob", payload: iconView),
            Record(name: ".", code: "vstl", type: "type", payload: Data("icnv".utf8)),
            Record(name: "Applications", code: "Iloc", type: "blob", payload: icon(InstallerLayout.applicationsPosition)),
            Record(name: "YUANNotch.app", code: "Iloc", type: "blob", payload: icon(InstallerLayout.appPosition))
        ].sorted {
            let order = $0.name.lowercased().compare($1.name.lowercased())
            return order == .orderedSame ? $0.code < $1.code : order == .orderedAscending
        }
        var leaf = Data()
        leaf.uint32(0)
        leaf.uint32(UInt32(records.count))
        records.forEach { leaf.append($0.encoded) }
        guard leaf.count <= 4_096 else { fail("Finder layout exceeds its single-page limit") }

        // Offsets are relative to byte 4. Block 0: allocator (2 KiB),
        // block 1: tree header (32 B), block 2: one leaf (4 KiB).
        var file = Data(count: 8_196)
        func put(_ data: Data, at offset: Int) {
            file.replaceSubrange(offset ..< offset + data.count, with: data)
        }
        var header = Data()
        header.uint32(1)
        header.fourCC("Bud1")
        header.uint32(2_048)
        header.uint32(2_048)
        header.uint32(2_048)
        put(header, at: 0)

        var tree = Data()
        [2, 0, UInt32(records.count), 1, 4_096].forEach { tree.uint32($0) }
        put(tree, at: 36)
        put(leaf, at: 4_100)

        var allocator = Data()
        allocator.uint32(3)
        allocator.uint32(0)
        let addresses: [UInt32] = [2_048 | 11, 32 | 5, 4_096 | 12]
        (0 ..< 256).forEach { allocator.uint32($0 < addresses.count ? addresses[$0] : 0) }
        allocator.uint32(1)
        allocator.append(4)
        allocator.fourCC("DSDB")
        allocator.uint32(1)
        for power in 0 ..< 32 {
            let free = (6 ... 10).contains(power) || (13 ... 30).contains(power)
            allocator.uint32(free ? 1 : 0)
            if free { allocator.uint32(UInt32(1) << power) }
        }
        guard allocator.count <= 2_048 else { fail("Finder allocator exceeds its block") }
        put(allocator, at: 2_052)
        try file.write(to: url, options: .atomic)
    }
}

@MainActor
func renderBackground(to output: URL, preview: URL?, app: URL?) throws {
    let width = CGFloat(InstallerLayout.width)
    let height = CGFloat(InstallerLayout.height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        (value as NSString).draw(at: NSPoint(x: x, y: height - top - size * 1.3), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
        ])
    }
    NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    text("安装 YUANNotch", x: 40, top: 35, size: 25, weight: .semibold, color: .init(calibratedWhite: 0.12, alpha: 1))
    text("将左侧应用拖到右侧“应用程序”文件夹", x: 40, top: 78, size: 13, weight: .regular, color: .init(calibratedWhite: 0.4, alpha: 1))
    for x: CGFloat in [106, 406] {
        let card = NSBezierPath(roundedRect: NSRect(x: x, y: height - 282, width: 128, height: 145), xRadius: 20, yRadius: 20)
        NSColor.white.withAlphaComponent(0.82).setFill()
        card.fill()
        NSColor(calibratedWhite: 0.9, alpha: 1).setStroke()
        card.lineWidth = 1
        card.stroke()
    }
    let arrow = NSBezierPath()
    let arrowY = height - CGFloat(InstallerLayout.appPosition.1)
    arrow.move(to: NSPoint(x: 289, y: arrowY))
    arrow.line(to: NSPoint(x: 349, y: arrowY))
    arrow.move(to: NSPoint(x: 337, y: arrowY + 11))
    arrow.line(to: NSPoint(x: 349, y: arrowY))
    arrow.line(to: NSPoint(x: 337, y: arrowY - 11))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(calibratedRed: 0.91, green: 0.49, blue: 0.13, alpha: 1).setStroke()
    arrow.stroke()
    text("安装后，从“应用程序”打开 YUANNotch。", x: 40, top: 320, size: 12, weight: .medium, color: .init(calibratedWhite: 0.34, alpha: 1))
    text("Drag YUANNotch into Applications to install.", x: 40, top: 346, size: 11, weight: .regular, color: .init(calibratedWhite: 0.5, alpha: 1))
    try rep.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)

    // A reproducible composite preview, without opening or automating Finder.
    if let preview, let app {
        let previewRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        previewRep.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: previewRep)!
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSImage(contentsOf: output)!.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        for (path, position, label) in [
            (app.path, InstallerLayout.appPosition, "YUANNotch"),
            ("/Applications", InstallerLayout.applicationsPosition, "Applications")
        ] {
            let icon = NSWorkspace.shared.icon(forFile: path)
            let side = CGFloat(InstallerLayout.iconSize)
            icon.draw(in: NSRect(x: CGFloat(position.0) - side / 2, y: height - CGFloat(position.1) - side / 2, width: side, height: side))
            let font = NSFont.systemFont(ofSize: 12)
            let labelWidth = (label as NSString).size(withAttributes: [.font: font]).width
            text(label, x: CGFloat(position.0) - labelWidth / 2, top: CGFloat(position.1) + side / 2 + 8, size: 12, weight: .regular, color: .darkGray)
        }
        try previewRep.representation(using: .png, properties: [:])!.write(to: preview, options: .atomic)
    }
}

/// HFS+ volume FinderInfo word 2 names the folder opened when mounting. Set
/// only that word in both headers of our unmounted, unpartitioned UDRW file.
/// No raw devices, boot settings, Finder preferences, or privileged tools.
/// https://developer.apple.com/library/archive/technotes/tn/tn1150.html#VolumeHeader
func autoOpenRoot(in image: URL, writes: Bool) throws {
    guard image.pathExtension == "dmg", try image.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        fail("auto-open only accepts a regular .dmg file")
    }
    let file = try writes ? FileHandle(forUpdating: image) : FileHandle(forReadingFrom: image)
    defer { try? file.close() }
    let fileSize = try file.seekToEnd()
    try file.seek(toOffset: 1_024)
    guard let header = try file.read(upToCount: 512), header.count == 512,
          header.prefix(2) == Data([0x48, 0x2b]) else { fail("expected an unpartitioned HFS+ image") }
    func uint32(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset ..< offset + 4].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    let volumeSize = uint32(header, 40) * uint32(header, 44)
    let blockSize = uint32(header, 40)
    guard volumeSize >= 4_096, volumeSize <= fileSize, fileSize - volumeSize < blockSize,
          fileSize.isMultiple(of: 512) else { fail("invalid raw HFS+ allocation bounds") }
    // The final allocation block can be partial; the alternate header is
    // relative to the volume's sector length, not totalBlocks * blockSize.
    let offsets: [UInt64] = [1_024, fileSize - 1_024]
    for offset in offsets {
        try file.seek(toOffset: offset)
        guard let copy = try file.read(upToCount: 512), copy.count == 512,
              copy.prefix(2) == header.prefix(2) else { fail("missing HFS+ volume header at \(offset), volume size \(volumeSize), file size \(fileSize)") }
        if !writes && uint32(copy, 88) != 2 {
            fail("the volume does not auto-open its root folder")
        }
    }
    if writes {
        for offset in offsets {
            try file.seek(toOffset: offset + 88)
            try file.write(contentsOf: Data([0, 0, 0, 2])) // kHFSRootFolderID
        }
        try file.synchronize()
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: dmg-layout background|store|auto-open|check-auto-open …") }
switch args[1] {
case "background":
    try renderBackground(to: URL(fileURLWithPath: args[2]), preview: args.count == 5 ? URL(fileURLWithPath: args[3]) : nil, app: args.count == 5 ? URL(fileURLWithPath: args[4]) : nil)
case "store":
    guard args.count == 4 else { fail("store needs a mounted root and alias data") }
    try FinderLayoutStore.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(".DS_Store"), alias: Data(contentsOf: URL(fileURLWithPath: args[3])))
case "auto-open", "check-auto-open":
    try autoOpenRoot(in: URL(fileURLWithPath: args[2]), writes: args[1] == "auto-open")
case "check-background":
    guard let image = NSImage(contentsOfFile: args[2]),
          abs(image.size.width - CGFloat(InstallerLayout.width)) < 0.5,
          abs(image.size.height - CGFloat(InstallerLayout.height)) < 0.5 else {
        fail("background PNG has the wrong point size for the Finder window")
    }
    print("PASS background point size matches the Finder window")
default: fail("unknown mode")
}

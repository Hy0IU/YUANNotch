// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "YUANNotch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "YUANNotch", targets: ["YUANNotch"])
    ],
    dependencies: [
        .package(path: "Vendor/swift-markdown-engine")
    ],
    targets: [
        .executableTarget(
            name: "YUANNotch",
            dependencies: [
                .product(name: "MarkdownEngine", package: "swift-markdown-engine")
            ],
            path: "Sources/YUANNotch",
            resources: [
                // The app mark, exported at 18 pt / 36 px. `.copy` keeps the
                // files byte-for-byte; see AppGlyph for how they are loaded.
                .copy("Glyph"),
                .copy("Sounds")
            ]
        )
    ]
)

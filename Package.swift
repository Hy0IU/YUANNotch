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
            path: "Sources/YUANNotch"
        )
    ]
)

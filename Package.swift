// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snag",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Snag",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Snag"
        ),
        .executableTarget(
            name: "snag-mcp",
            path: "Sources/SnagMCP"
        ),
    ]
)

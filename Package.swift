// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AurelionLabs",
    defaultLocalization: "tr",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AurelionLabs",
            path: "Sources/AurelionLabs"
        )
    ]
)

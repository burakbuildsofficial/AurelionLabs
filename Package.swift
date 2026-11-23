// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InklingLab",
    defaultLocalization: "tr",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "InklingLab",
            path: "Sources/InklingLab"
        )
    ]
)

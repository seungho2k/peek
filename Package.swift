// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Peek",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Peek",
            path: "Sources/Peek",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AutoFocus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AutoFocus", path: "Sources/AutoFocus", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)

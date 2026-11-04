// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CapturePro",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CapturePro",
            path: "Sources/CapturePro"
        )
    ],
    swiftLanguageModes: [.v5]
)

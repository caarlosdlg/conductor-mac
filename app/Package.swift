// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Conductor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Conductor",
            path: "Sources/Conductor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

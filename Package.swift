// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dictator",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "Dictator",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/Dictator",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

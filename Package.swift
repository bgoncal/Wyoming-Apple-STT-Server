// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WyomingAppleSpeechServer",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(
            name: "WyomingAppleSpeechServer",
            targets: ["WyomingAppleSpeechServer"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "WyomingAppleSpeechServer",
            path: "Sources/WyomingAppleSpeechServer"
        ),
        .testTarget(
            name: "WyomingAppleSpeechServerTests",
            dependencies: ["WyomingAppleSpeechServer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReflectMac",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ReflectCore"),
        .executableTarget(name: "ReflectMac", dependencies: ["ReflectCore"]),
        .testTarget(name: "ReflectCoreTests", dependencies: ["ReflectCore"]),
    ],
    swiftLanguageModes: [.v5]
)

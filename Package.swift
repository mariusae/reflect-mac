// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReflectMac",
    // macOS 26 and on: AppKit gives an app built for older systems their split
    // views and toolbars, which no longer line up.
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "ReflectCore"),
        .executableTarget(name: "ReflectMac", dependencies: ["ReflectCore"]),
        .testTarget(name: "ReflectCoreTests", dependencies: ["ReflectCore"]),
    ],
    swiftLanguageModes: [.v5]
)

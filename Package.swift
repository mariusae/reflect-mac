// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReflectMac",
    // macOS 26 and on: AppKit gives an app built for older systems their split
    // views and toolbars, which no longer line up.
    // ReflectCore is shared with the iOS app, in iOS/.
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "ReflectCore", targets: ["ReflectCore"]),
        .library(name: "ReflectGit2", targets: ["ReflectGit2"]),
        .executable(name: "ReflectMac", targets: ["ReflectMac"]),
        .executable(name: "Prism", targets: ["Prism"]),
        .library(name: "PrismCore", targets: ["PrismCore"]),
    ],
    dependencies: [
        // libgit2, built from source: HTTPS through the system's TLS.
        .package(url: "https://github.com/ibrahimcetin/libgit2.git", exact: "1.9.2"),
    ],
    targets: [
        .target(name: "ReflectCore"),
        // The sync's steps done by libgit2, and the GitHub account it syncs
        // through: the phone's, and Prism's own graph on the Mac.
        .target(name: "ReflectGit2", dependencies: ["ReflectCore", .product(name: "libgit2", package: "libgit2")]),
        // The outline editor, and a note shown in it: shared by the apps.
        .target(name: "ReflectUI", dependencies: ["ReflectCore"]),
        .executableTarget(name: "ReflectMac", dependencies: ["ReflectCore", "ReflectUI"]),
        // A second face on the same notes: type first, and little else.
        .executableTarget(name: "Prism", dependencies: ["ReflectCore", "ReflectUI", "PrismCore", "ReflectGit2"]),
        // What Prism does, whatever it is shown on: the Mac's, the phone's.
        .target(name: "PrismCore", dependencies: ["ReflectCore"]),
        .testTarget(name: "ReflectCoreTests", dependencies: ["ReflectCore", "ReflectGit2", "PrismCore"]),
    ],
    swiftLanguageModes: [.v5]
)

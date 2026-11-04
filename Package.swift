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
        .library(name: "GraphKit", targets: ["GraphKit"]),
        .library(name: "ReflectUI", targets: ["ReflectUI"]),
        .library(name: "ReflectGit2", targets: ["ReflectGit2"]),
        .executable(name: "ReflectMac", targets: ["ReflectMac"]),
        .executable(name: "Prism", targets: ["Prism"]),
        .library(name: "PrismCore", targets: ["PrismCore"]),
        .library(name: "PhoneUI", targets: ["PhoneUI"]),
    ],
    dependencies: [
        // libgit2, built from source: HTTPS through the system's TLS.
        .package(url: "https://github.com/ibrahimcetin/libgit2.git", exact: "1.9.2"),
    ],
    targets: [
        .target(name: "ReflectCore"),
        // The graph as Prism and Weft both see it: pages and their files,
        // the Markdown they share (docs/markdown.md), the index over them,
        // queries, typed fields, merging and the sync.
        .target(name: "GraphKit", dependencies: ["ReflectCore"]),
        // The sync's steps done by libgit2, and the GitHub account it syncs
        // through: the phone's, and Prism's own graph on the Mac.
        .target(name: "ReflectGit2", dependencies: ["ReflectCore", .product(name: "libgit2", package: "libgit2")],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        // The outline editor, and a note shown in it: shared by the apps.
        .target(name: "ReflectUI", dependencies: ["ReflectCore", "GraphKit"]),
        .executableTarget(name: "ReflectMac", dependencies: ["ReflectCore", "ReflectUI"]),
        // A second face on the same notes: type first, and little else.
        .executableTarget(name: "Prism", dependencies: ["ReflectCore", "ReflectUI", "PrismCore", "ReflectGit2", "GraphKit"]),
        // What Prism does, whatever it is shown on: the Mac's, the phone's.
        .target(name: "PrismCore", dependencies: ["ReflectCore", "GraphKit"]),
        // The phone's outline editor, its bar over the keys, and what it
        // draws — Prism's on the iPhone, and Weft's: as ReflectUI is the Mac's.
        .target(name: "PhoneUI", dependencies: ["ReflectCore", "GraphKit", "PrismCore"]),
        .testTarget(name: "ReflectCoreTests", dependencies: ["ReflectCore", "ReflectGit2", "PrismCore"]),
        .testTarget(name: "PhoneUITests", dependencies: ["PhoneUI", "ReflectCore"]),
        .testTarget(name: "GraphKitTests", dependencies: ["GraphKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)

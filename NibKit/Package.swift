// swift-tools-version: 6.0
// NibKit: nib's engine (PRD §6.2). No UI; the app links it as a local package.
import PackageDescription

let package = Package(
    name: "NibKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "NibText", targets: ["NibText"]),
        .library(name: "NibSync", targets: ["NibSync"]),
    ],
    targets: [
        // Encodings, line endings, fingerprints, paste cleanup, conflict text. No I/O.
        .target(name: "NibText"),
        // Journal, in-place compare-and-swap saves, iCloud sync controls, the Sync Log.
        .target(name: "NibSync", dependencies: ["NibText"]),
        .testTarget(name: "NibTextTests", dependencies: ["NibText"]),
        .testTarget(name: "NibSyncTests", dependencies: ["NibSync", "NibText"]),
    ]
)

// swift-tools-version: 6.0
// NibKit: nib's engine (PRD §6.2). No UI; the app links it as a local package.
import PackageDescription

let package = Package(
    name: "NibKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "NibText", targets: ["NibText"]),
        .library(name: "NibSync", targets: ["NibSync"]),
        .library(name: "NibSyntax", targets: ["NibSyntax"]),
        .executable(name: "nib-fidelity", targets: ["NibFidelity"]),
        // Not "nib": Xcode makes a scheme for each package product, and one called "nib" took
        // `-scheme nib` from the app (builds that compiled only this, 2026-09-29).
        .executable(name: "nib-cli", targets: ["NibCLI"]),
    ],
    // tree-sitter and grammars for HL1's languages (§6.3; BSD-3-Clause and MIT); CSS and JavaScript are vendored.
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", from: "0.25.1"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", from: "0.5.3"),
    ],
    targets: [
        // Encodings, line endings, fingerprints, paste cleanup, conflict text. No I/O.
        .target(name: "NibText"),
        // Journal, in-place compare-and-swap saves, iCloud sync controls, the Sync Log.
        .target(name: "NibSync", dependencies: ["NibText"]),
        // Highlighting (HL1, HL7): tree-sitter parses, Nib's own queries name captures with Sublime's
        // scopes, and the scheme (NibText's Theme) colors them.
        .target(name: "NibSyntax", dependencies: [
            "NibText",
            .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
            .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
            "TreeSitterCSS",
            "TreeSitterJavaScript",
            .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
            .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
            .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
        ], resources: [.copy("Queries"), .copy("Themes")]),
        // CSS and JavaScript, vendored (Vendor/README.md): their manifests drop the external scanner.
        .target(name: "TreeSitterCSS", path: "Vendor/tree-sitter-css", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJavaScript", path: "Vendor/tree-sitter-javascript", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        // The fidelity harness's comparison (fidelity/run.sh): Nib's colors against Sublime's dump.
        .executableTarget(name: "NibFidelity", dependencies: ["NibSyntax", "NibText"]),
        // The `nib` command-line tool (AP4): asks the running app, through NibSync's Bridge.
        .executableTarget(name: "NibCLI", dependencies: ["NibSync", "NibText"]),
        .testTarget(name: "NibTextTests", dependencies: ["NibText"]),
        .testTarget(name: "NibSyntaxTests", dependencies: ["NibSyntax", "NibText"]),
        .testTarget(name: "NibSyncTests", dependencies: ["NibSync", "NibText"]),
    ]
)

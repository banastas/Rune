// swift-tools-version: 6.0
// NibKit: nib's engine (PRD §6.2). No UI; the app links it as a local package.
import PackageDescription

/// Three vendored scanners narrow a `size_t` to 32 bits where it can't pass tree-sitter's 1 KB
/// buffer for a scanner's state (the state's size, a dollar-quote tag's length), which Xcode's
/// defaults warn about in every build. Left as they are upstream, and quieted. (Unsafe flags are
/// fine in a local package.)
let quietScanner: CSetting = .unsafeFlags(["-Wno-shorten-64-to-32"])

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
    // tree-sitter and grammars for HL1's languages (§6.3; BSD-3-Clause and MIT); CSS, JavaScript and HL8's
    // grammars are vendored (Vendor/README.md).
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
            "TreeSitterXML", "TreeSitterTypeScript", "TreeSitterTSX", "TreeSitterPython", "TreeSitterYAML", "TreeSitterTOML",
            "TreeSitterMake", "TreeSitterDiff", "TreeSitterGitCommit", "TreeSitterGitIgnore", "TreeSitterGitAttributes",
            "TreeSitterGitConfig", "TreeSitterINI", "TreeSitterGo", "TreeSitterRust", "TreeSitterRuby", "TreeSitterJava",
            "TreeSitterC", "TreeSitterLua", "TreeSitterPHP", "TreeSitterSQL", "TreeSitterRST", "TreeSitterSwift",
        ], resources: [.copy("Queries"), .copy("Themes")]),
        // CSS and JavaScript, vendored (Vendor/README.md): their manifests drop the external scanner.
        .target(name: "TreeSitterCSS", path: "Vendor/tree-sitter-css", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJavaScript", path: "Vendor/tree-sitter-javascript", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        // XML (HL8), vendored too: its manifest depends on SwiftTreeSitter by its old address, a
        // second package with the same module. Its scanner includes ../../common/scanner.h.
        .target(name: "TreeSitterXML", path: "Vendor/tree-sitter-xml", sources: ["xml/src/parser.c", "xml/src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("xml/src")]),
        // HL8's list (2026-10-02), vendored too: most of their manifests name SwiftTreeSitter by its old
        // address or look for the scanner with FileManager, and three have none. TypeScript's two
        // grammars share a scanner header (../../common/scanner.h); YAML's scanner includes schema.core.c.
        .target(name: "TreeSitterTypeScript", path: "Vendor/tree-sitter-typescript", sources: ["typescript/src/parser.c", "typescript/src/scanner.c"],
                publicHeadersPath: "bindings/swift/TreeSitterTypeScript", cSettings: [.headerSearchPath("typescript/src")]),
        .target(name: "TreeSitterTSX", path: "Vendor/tree-sitter-typescript", sources: ["tsx/src/parser.c", "tsx/src/scanner.c"],
                publicHeadersPath: "bindings/swift/TreeSitterTSX", cSettings: [.headerSearchPath("tsx/src")]),
        .target(name: "TreeSitterPython", path: "Vendor/tree-sitter-python", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src"), quietScanner]),
        .target(name: "TreeSitterYAML", path: "Vendor/tree-sitter-yaml", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src"), quietScanner]),
        .target(name: "TreeSitterTOML", path: "Vendor/tree-sitter-toml", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterMake", path: "Vendor/tree-sitter-make", sources: ["src/parser.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterDiff", path: "Vendor/tree-sitter-diff", sources: ["src/parser.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterGitCommit", path: "Vendor/tree-sitter-gitcommit", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterGitIgnore", path: "Vendor/tree-sitter-gitignore", sources: ["src/parser.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterGitAttributes", path: "Vendor/tree-sitter-gitattributes", sources: ["src/parser.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterGitConfig", path: "Vendor/tree-sitter-git-config", sources: ["src/parser.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterINI", path: "Vendor/tree-sitter-ini", sources: ["src/parser.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        // HL8's second tier. PHP is the grammar that reads the HTML round <?php ?> (its scanner
        // includes ../../common/scanner.h); SQL's comes from its release tarball (the repository
        // doesn't hold a generated parser); reStructuredText's scanner includes its own folder.
        .target(name: "TreeSitterGo", path: "Vendor/tree-sitter-go", sources: ["src/parser.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterRust", path: "Vendor/tree-sitter-rust", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterRuby", path: "Vendor/tree-sitter-ruby", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJava", path: "Vendor/tree-sitter-java", sources: ["src/parser.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterC", path: "Vendor/tree-sitter-c", sources: ["src/parser.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterLua", path: "Vendor/tree-sitter-lua", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterPHP", path: "Vendor/tree-sitter-php", sources: ["php/src/parser.c", "php/src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("php/src")]),
        .target(name: "TreeSitterSQL", path: "Vendor/tree-sitter-sql", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src"), quietScanner]),
        .target(name: "TreeSitterRST", path: "Vendor/tree-sitter-rst", sources: ["src/parser.c", "src/scanner.c"],
                publicHeadersPath: "bindings/swift", cSettings: [.headerSearchPath("src")]),
        // Swift (Nib's own colors: Sublime has none), from the release's tag with generated files.
        .target(name: "TreeSitterSwift", path: "Vendor/tree-sitter-swift", sources: ["src/parser.c", "src/scanner.c"],
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

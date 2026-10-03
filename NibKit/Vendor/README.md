# Vendored grammars

tree-sitter's CSS and JavaScript grammars at v0.25.0 (MIT, their LICENSE files beside them):
the generated parser and the external scanner, and the Swift binding's header. They're
copied rather than fetched because their `Package.swift` adds `src/scanner.c` only if
`FileManager` finds it relative to the working directory, which SwiftPM's manifest sandbox
isn't in, so the scanner went missing and linking failed (2026-09-28). The other grammars
(HTML, JSON, Bash, Markdown) list their sources and come through SwiftPM as usual.

tree-sitter-grammars' XML grammar at v0.7.0 (MIT, by ObserverOfTime; 2026-10-02), the XML half
only (not DTD): `xml/src/` and `common/scanner.h`, in the repository's own layout, since the
scanner includes `../../common/scanner.h`. Copied because its `Package.swift` depends on
SwiftTreeSitter at its old address (ChimeHQ/SwiftTreeSitter), which SwiftPM would take for a
second package with the same module as tree-sitter/swift-tree-sitter.

HL8's list (2026-10-02), copied for the same reasons (most manifests name SwiftTreeSitter at
its old address or look for the scanner with FileManager; three have no manifest), each with its
licence beside it:

| Folder | Repository | Version | Licence |
|---|---|---|---|
| `tree-sitter-typescript` | tree-sitter/tree-sitter-typescript (TypeScript and TSX; `common/scanner.h` shared) | v0.23.2 | MIT |
| `tree-sitter-python` | tree-sitter/tree-sitter-python | v0.25.0 | MIT |
| `tree-sitter-yaml` | tree-sitter-grammars/tree-sitter-yaml (its scanner includes `schema.core.c`) | v0.7.2 | MIT |
| `tree-sitter-toml` | tree-sitter-grammars/tree-sitter-toml | v0.7.0 | MIT |
| `tree-sitter-make` | tree-sitter-grammars/tree-sitter-make | v1.1.1 | MIT |
| `tree-sitter-diff` | tree-sitter-grammars/tree-sitter-diff | v0.2.0 | MIT |
| `tree-sitter-gitcommit` | gbprod/tree-sitter-gitcommit | v0.5.0 | WTFPL |
| `tree-sitter-gitignore` | shunsambongi/tree-sitter-gitignore | f4685bf (2022-05-04; no tags) | MIT |
| `tree-sitter-gitattributes` | tree-sitter-grammars/tree-sitter-gitattributes | v0.1.6 | MIT |
| `tree-sitter-git-config` | the-mikedavis/tree-sitter-git-config | 3a61756 (2026-07-20; no tags) | MIT |
| `tree-sitter-ini` | justinmk/tree-sitter-ini | v1.4.0 | Apache 2.0 |

The three without a Swift binding (gitignore, gitattributes, git-config) have a header written
here, declaring their one function.

HL8's second tier (2026-10-02), all MIT:

| Folder | Repository | Version | Notes |
|---|---|---|---|
| `tree-sitter-go` | tree-sitter/tree-sitter-go | v0.25.0 | |
| `tree-sitter-rust` | tree-sitter/tree-sitter-rust | v0.24.2 | |
| `tree-sitter-ruby` | tree-sitter/tree-sitter-ruby | v0.23.1 | |
| `tree-sitter-java` | tree-sitter/tree-sitter-java | v0.23.5 | |
| `tree-sitter-c` | tree-sitter/tree-sitter-c | v0.24.2 | |
| `tree-sitter-lua` | tree-sitter-grammars/tree-sitter-lua | v0.5.0 | |
| `tree-sitter-php` | tree-sitter/tree-sitter-php | v0.25.0 | `php/src` only (the grammar that reads the HTML round `<?php ?>`), and `common/scanner.h`; its binding header written here, for `tree_sitter_php` alone |
| `tree-sitter-sql` | DerekStride/tree-sitter-sql | v0.3.11 | from the release's `tree-sitter-sql-v0.3.11.tar.gz`: the repository holds no generated parser |
| `tree-sitter-rst` | stsewd/tree-sitter-rst | v0.2.0 | its scanner includes `src/tree_sitter_rst/`, copied whole (not compiled on its own) |

To update: copy `src/parser.c`, `src/scanner.c`, `src/tree_sitter/*.h` and
`bindings/swift/<Module>/*.h` from the grammar's release tag (for XML, `xml/src/…`,
`common/scanner.h` and `bindings/swift/xml/TreeSitterXML/xml.h`), and change the version here.

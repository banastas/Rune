# Vendored grammars

tree-sitter's CSS and JavaScript grammars at v0.25.0 (MIT, their LICENSE files beside them):
the generated parser and the external scanner, and the Swift binding's header. They're
copied rather than fetched because their `Package.swift` adds `src/scanner.c` only if
`FileManager` finds it relative to the working directory, which SwiftPM's manifest sandbox
isn't in, so the scanner went missing and linking failed (2026-09-28). The other grammars
(HTML, JSON, Bash, Markdown) list their sources and come through SwiftPM as usual.

To update: copy `src/parser.c`, `src/scanner.c`, `src/tree_sitter/*.h` and
`bindings/swift/<Module>/*.h` from the grammar's release tag, and change the version here.

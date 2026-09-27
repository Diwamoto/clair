# Vendored grammar: tree-sitter-rust

- Source: https://github.com/tree-sitter/tree-sitter-rust
- Commit: `77a3747266f4d621d0757825e6b11edcbf991ca5`
- Files: `src/parser.c`, `src/scanner.c` (external scanner, plain C — raw
  string/lifetime disambiguation), `src/tree_sitter/{parser,alloc,array}.h`,
  `include/tree_sitter_rust.h` (own C binding header).
- License: MIT, see `LICENSE` (unmodified, Copyright (c) 2017 Maxim Sokolov).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: `queries/highlights.scm` from the same commit, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

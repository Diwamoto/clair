# Vendored grammar: tree-sitter-go

- Source: https://github.com/tree-sitter/tree-sitter-go
- Commit: `2346a3ab1bb3857b48b29d779a1ef9799a248cd7`
- Files: `src/parser.c` (generated parser, no external scanner),
  `src/tree_sitter/{parser,alloc,array}.h`, `include/tree_sitter_go.h` (own
  C binding header).
- License: MIT, see `LICENSE` (unmodified, Copyright (c) 2014 Max Brunsfeld).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`
(`SwiftTreeSitter` pin conflict with the grammar's own SwiftPM package).

Highlight query: `queries/highlights.scm` from the same commit, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

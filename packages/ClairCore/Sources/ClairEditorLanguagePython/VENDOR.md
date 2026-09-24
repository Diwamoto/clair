# Vendored grammar: tree-sitter-python

- Source: https://github.com/tree-sitter/tree-sitter-python
- Commit: `26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64`
- Files: `src/parser.c`, `src/scanner.c` (external scanner, plain C — indent/
  dedent/string tracking), `src/tree_sitter/{parser,alloc,array}.h`,
  `include/tree_sitter_python.h` (own C binding header).
- License: MIT, see `LICENSE` (unmodified, Copyright (c) 2016 Max Brunsfeld).

Vendored raw instead of via the grammar's own SwiftPM package for the same
`SwiftTreeSitter` version-pin conflict documented in
`ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: `queries/highlights.scm` from the same commit, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

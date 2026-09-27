# Vendored grammar: tree-sitter-javascript

Covers `.js`/`.jsx`.

- Source: https://github.com/tree-sitter/tree-sitter-javascript
- Commit: `58404d8cf191d69f2674a8fd507bd5776f46cb11`
- Files: `src/parser.c`, `src/scanner.c` (external scanner, plain C —
  automatic semicolon insertion/template string tracking),
  `src/tree_sitter/{parser,alloc,array}.h`, `include/tree_sitter_javascript.h`
  (own C binding header).
- License: MIT, see `LICENSE` (unmodified, Copyright (c) 2014 Max Brunsfeld).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: `queries/highlights.scm` from the same commit, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

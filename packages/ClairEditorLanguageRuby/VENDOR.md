# Vendored grammar: tree-sitter-ruby

- Source: https://github.com/tree-sitter/tree-sitter-ruby
- Commit: `ad907a69da0c8a4f7a943a7fe012712208da6dee`
- Files: `src/parser.c`, `src/scanner.c` (external scanner, plain C),
  `src/tree_sitter/{parser,alloc,array}.h`, `include/tree_sitter_ruby.h`
  (own C binding header).
- License: MIT, see `LICENSE` (unmodified).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: `queries/highlights.scm` from the same commit, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

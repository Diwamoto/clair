# Vendored grammar: tree-sitter-sql

- Source: https://github.com/DerekStride/tree-sitter-sql (release `v0.3.11`,
  `tree-sitter-sql-v0.3.11.tar.gz`; upstream `main` does not commit the
  generated parser)
- Commit: `7b51ecda191d36b92f5a90a8d1bc3faef1c7b8b8`
- Files: `src/{parser.c,scanner.c}`, `src/tree_sitter/{parser,alloc,array}.h`,
  `include/tree_sitter_sql.h` (own C binding header).
- License: MIT, see `LICENSE` (unmodified).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: `queries/highlights.scm` from the same release, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

Local change in the query: upstream's `#match?` number patterns use Lua `%d`
(nvim), which a regex reads as a literal `d`; Clair uses `[0-9]`.

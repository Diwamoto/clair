# Vendored grammar: tree-sitter-toml

- Source: https://github.com/tree-sitter-grammars/tree-sitter-toml
- Commit: `64b56832c2cffe41758f28e05c756a3a98d16f41`
- Files: `src/{parser.c,scanner.c}`, `src/tree_sitter/{parser,alloc,array}.h`,
  `include/tree_sitter_toml.h` (own C binding header).
- License: MIT, see `LICENSE` (unmodified).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: `queries/highlights.scm` from the same commit, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

Local change in the query: upstream captures the whole `(pair (bare_key))`
as `@property`, which would paint the value too; Clair captures only the key.

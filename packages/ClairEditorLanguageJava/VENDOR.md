# Vendored grammar: tree-sitter-java

- Source: https://github.com/tree-sitter/tree-sitter-java
- Commit: `e10607b45ff745f5f876bfa3e94fbcc6b44bdc11`
- Files: `src/parser.c` (no external scanner),
  `src/tree_sitter/{parser,alloc,array}.h`, `include/tree_sitter_java.h`
  (own C binding header).
- License: MIT, see `LICENSE` (unmodified).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: `queries/highlights.scm` from the same commit, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

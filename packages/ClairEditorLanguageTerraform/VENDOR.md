# Vendored grammar: tree-sitter-hcl (`terraform` dialect)

Covers `.tf`, `.tfvars`, and plain `.hcl` (the terraform dialect is a
superset of HCL's grammar, so one parser serves both).

- Source: https://github.com/tree-sitter-grammars/tree-sitter-hcl
- Commit: `64ad62785d442eb4d45df3a1764962dafd5bc98b`
- Subdirectory: `dialects/terraform/`.
- Files: `dialects/terraform/src/parser.c`, `dialects/terraform/src/scanner.c`
  (external scanner, plain C), `src/tree_sitter/{parser,alloc,array}.h`,
  `include/tree_sitter_terraform.h` (own C binding header).
- License: Apache-2.0, see `LICENSE` (unmodified).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: the grammar repo ships none, so
`HighlightQueries.swift` embeds nvim-treesitter's
`runtime/queries/hcl/highlights.scm` followed by
`runtime/queries/terraform/highlights.scm` (which declares
`; inherits: hcl`), from https://github.com/nvim-treesitter/nvim-treesitter
commit `f603a2f4da48728f80257fb5fbb90145fd1dc173` (Apache-2.0).

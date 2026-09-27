# Vendored grammar: tree-sitter-swift

- Source: https://github.com/alex-pinkus/tree-sitter-swift
- Commit: `00bbb0a2550f8bc0023a2a4992922d51ae045626`
- Files: `src/parser.c` — **not committed upstream**, generated locally from
  this commit's `grammar.js` via `tree-sitter generate` (tree-sitter-cli
  `0.25.10`, matching this package's pinned `tree-sitter` revision
  `da6fe9beb4f7f67beb75914ca8e0d48ae48d6406`, i.e. tree-sitter 0.25.10) —
  `src/scanner.c` (external scanner, plain C — raw string/regex literal
  disambiguation, vendored as-is from the repo, not generated),
  `src/tree_sitter/{parser,alloc,array}.h`, `include/tree_sitter_swift.h`
  (own C binding header).
- License: MIT, see `LICENSE` (unmodified, Copyright (c) 2021 Alex Pinkus).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`. Since
`parser.c` is regenerated rather than copied verbatim from a commit, a future
re-vendor at a newer commit must regenerate it the same way (do not hand-edit
the generated file).

Highlight query: `queries/highlights.scm` from the same commit, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

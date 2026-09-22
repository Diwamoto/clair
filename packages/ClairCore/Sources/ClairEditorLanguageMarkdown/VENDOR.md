# Vendored grammar: tree-sitter-markdown (block grammar only)

- Source: https://github.com/tree-sitter-grammars/tree-sitter-markdown
- Commit: `a0a00f817d02412bd92c54d316f164d827b57b5c`
- Subdirectory: `tree-sitter-markdown/` (the sibling
  `tree-sitter-markdown-inline/` grammar, normally injected into this one's
  `inline` nodes for bold/italic/link-level highlighting, was **not**
  vendored — see `ponytail:` note in
  `ClairEditorLanguage/EditorLanguage.swift`).
- Files: `tree-sitter-markdown/src/parser.c`,
  `tree-sitter-markdown/src/scanner.c` (external scanner, plain C — block
  structure: headings/lists/code fences/block quotes),
  `tree-sitter-markdown/src/tree_sitter/{parser,alloc,array}.h`,
  `include/tree_sitter_markdown.h` (own C binding header).
- License: MIT, see `LICENSE` (top-level `LICENSE` of the monorepo,
  unmodified, Copyright (c) 2022 The Nvim Treesitter Authors).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: `tree-sitter-markdown/queries/highlights.scm` from the same
commit, embedded in `ClairEditorLanguage/HighlightQueries.swift`. Without the
inline grammar, patterns that reference `(inline)` subtree contents (bold,
italic, inline code, links) do not fire — block-level structure (headings,
code fences, block quotes, thematic breaks, list markers) still highlights.

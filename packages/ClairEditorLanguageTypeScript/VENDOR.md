# Vendored grammar: tree-sitter-typescript (`typescript` grammar only)

Covers `.ts`. `.tsx` is out of scope for this pass (see `ponytail:` note in
`ClairEditorLanguage/EditorLanguage.swift`) — the repo's `tsx` sibling
grammar is a separate generated parser this task did not vendor.

- Source: https://github.com/tree-sitter/tree-sitter-typescript
- Commit: `75b3874edb2dc714fb1fd77a32013d0f8699989f`
- Subdirectory: `typescript/` (the `tsx/` grammar was not vendored).
- Files: `typescript/src/parser.c`, `typescript/src/scanner.c` (external
  scanner, plain C), `typescript/src/tree_sitter/{parser,alloc,array}.h`,
  `include/tree_sitter_typescript.h` (own C binding header).
- License: MIT, see `LICENSE` (top-level `LICENSE` of the monorepo,
  unmodified, Copyright (c) 2014 Max Brunsfeld).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

`src/scanner.c`'s `#include "../../common/scanner.h"` (a monorepo-relative
path into the sibling `common/` directory shared by `typescript/` and
`tsx/`) was rewritten to `#include "scanner.h"`, and that one shared header
(`common/scanner.h` from the same commit, unmodified otherwise) copied
alongside it as `src/scanner.h` — vendoring the whole `common/` directory
for one header felt like more surface than the single line it replaces.

Highlight query: the upstream `typescript` grammar's `queries/highlights.scm`
declares `; inherits: javascript` and is meant to be layered on top of
`tree-sitter-javascript`'s own `queries/highlights.scm` (this is how
nvim-treesitter and other consumers combine them) — `HighlightQueries.swift`
embeds both files concatenated (javascript's patterns first) as this
grammar's query text, exactly matching that inheritance.

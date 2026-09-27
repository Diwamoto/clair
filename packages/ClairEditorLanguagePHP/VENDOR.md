# Vendored grammar: tree-sitter-php (`php` grammar only)

Covers `.php` including inline HTML text outside `<?php` tags (as plain
text; no HTML injection). The sibling `php_only` grammar was not vendored.

- Source: https://github.com/tree-sitter/tree-sitter-php
- Commit: `3fda2fb9577166c6399834917f9844f30370beea`
- Subdirectory: `php/`.
- Files: `php/src/parser.c`, `php/src/scanner.c` (external scanner, plain
  C), `php/src/tree_sitter/{parser,alloc,array}.h`,
  `include/tree_sitter_php.h` (own C binding header).
- License: MIT, see `LICENSE` (monorepo top-level, unmodified).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

`src/scanner.c`'s `#include "../../common/scanner.h"` was rewritten to
`#include "scanner.h"`, with `common/scanner.h` from the same commit copied
alongside as `src/scanner.h` (same treatment as
`ClairEditorLanguageTypeScript/VENDOR.md`).

Highlight query: top-level `queries/highlights.scm` from the same commit,
embedded in `ClairEditorLanguage/HighlightQueries.swift`.

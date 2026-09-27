# Vendored grammar: tree-sitter-bash

Covers `.sh`/`.bash`/extensionless-with-shebang files (§E11's "shell").

- Source: https://github.com/tree-sitter/tree-sitter-bash
- Commit: `a06c2e4415e9bc0346c6b86d401879ffb44058f7`
- Files: `src/parser.c`, `src/scanner.c` (external scanner, plain C — heredoc/
  string tracking; confirmed plain C, not C++, before vendoring, since a
  C++ scanner would conflict with this package's pure-C vendoring pattern),
  `src/tree_sitter/{parser,alloc,array}.h`, `include/tree_sitter_bash.h`
  (own C binding header).
- License: MIT, see `LICENSE` (unmodified, Copyright (c) 2014 Max Brunsfeld).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: `queries/highlights.scm` from the same commit, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

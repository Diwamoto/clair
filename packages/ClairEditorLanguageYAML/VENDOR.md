# Vendored grammar: tree-sitter-yaml

- Source: https://github.com/tree-sitter-grammars/tree-sitter-yaml
- Commit: `a1c4812a73ec5e089de8e441fdea3a921e8d5079`
- Files: `src/{parser.c,scanner.c,schema.core.h}`, `src/tree_sitter/{parser,alloc,array}.h`,
  `include/tree_sitter_yaml.h` (own C binding header).
- License: MIT, see `LICENSE` (unmodified).

Same vendoring rationale as `ClairEditorLanguageFixtures/VENDOR.md`.

Highlight query: `queries/highlights.scm` from the same commit, embedded in
`ClairEditorLanguage/HighlightQueries.swift`.

Local change: upstream `src/schema.core.c` is vendored as `src/schema.core.h`
and `scanner.c` includes it directly (the `_file(YAML_SCHEMA)` macro selection
is removed), so SwiftPM does not compile the schema as its own translation
unit. Only the core schema is vendored.

# Vendored grammar: tree-sitter-json

Production grammar for `ClairEditorLanguage`'s syntax highlighting (E11).
Separate from `ClairEditorLanguageFixtures` (test-only): that target is
deliberately not a public product, so highlighting needs its own copy of the
same upstream sources.

- Source: https://github.com/tree-sitter/tree-sitter-json
- Commit: `254c42a6476413b776221e03982ac8ae159eeb72`
- Files: `src/parser.c`, `src/tree_sitter/{parser,alloc,array}.h` (generated
  parser, no external scanner), `include/tree_sitter_json.h` (own C binding
  header, hand-written to match the project's `bindings/c/` convention).
- License: MIT, see `LICENSE` (unmodified, Copyright (c) 2014 Max Brunsfeld).

Chosen over the grammar's own SwiftPM package for the same reason as
`ClairEditorLanguageFixtures`: that package pins `SwiftTreeSitter` to
`0.8.0` (`<0.9.0`), conflicting with this repository's pin. `parser.c` has no
dependencies of its own, so vendoring just these files avoids the conflict.

Highlight query: `queries/highlights.scm` from the same commit, embedded as a
Swift string literal in `ClairEditorLanguage/HighlightQueries.swift` (no
SwiftPM resource bundling needed for a few KB of query text).

The exported C symbol `tree_sitter_json` was renamed to
`clair_editor_tree_sitter_json` (in both `src/parser.c` and
`include/tree_sitter_json.h`) because `ClairCoreTests`/
`ClairCoreIntegrationTests` link this target *and*
`ClairEditorLanguageFixtures` into the same test binary, and both vendor the
same upstream commit under the same original symbol name — an unmodified
copy would be a duplicate-symbol link error the moment both are linked
together, not a runtime conflict. Every other vendored grammar in this pass
keeps its original `tree_sitter_<lang>` name since none of them collide with
an existing target.

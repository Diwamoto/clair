# Vendored grammar: tree-sitter-json

Test-only fixture grammar for `ClairEditorLanguageTests`. Not linked into any
shipping app target.

- Source: https://github.com/tree-sitter/tree-sitter-json
- Commit: `254c42a6476413b776221e03982ac8ae159eeb72`
- Files: `src/parser.c`, `src/tree_sitter/{parser,alloc,array}.h` (generated
  parser, no external scanner), `include/tree_sitter_json.h` (the project's own
  C binding header, relocated from `bindings/c/`).
- License: MIT, see `LICENSE` (unmodified, Copyright (c) 2014 Max Brunsfeld).

Chosen over the grammar's own SwiftPM package because that package pins
`SwiftTreeSitter` to `0.8.0` (semver-locked to `<0.9.0`), which conflicts with
this repository's own `SwiftTreeSitter` dependency. `parser.c` has no
dependencies of its own, so vendoring just these files avoids the conflict
entirely.

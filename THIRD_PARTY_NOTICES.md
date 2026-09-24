# Third-party notices

This file is the source of truth for notices that must accompany distributed
Clair binaries.

## libghostty / GhosttyKit

Clair's terminal engine (`ClairGhosttyABI`/`ClairGhostty`) links the
pinned `libghostty-internal` static library, built from upstream Ghostty at
the commit recorded in `Config/ghostty-pin.json`. Ghostty is available under
the MIT License.

- Project: https://github.com/ghostty-org/ghostty
- Pinned commit: `d4c88d8069912b653d707191388ca98e24751f12` (`1.3.2-dev`)
- License: MIT — Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
- The upstream `LICENSE` file is staged at vendor time to
  `packages/ClairCore/Vendor/ghostty/LICENSE-ghostty` (git-ignored,
  materialized by `scripts/ghostty.sh vendor`, not redistributed from
  this repository).

Ghostty's macOS build statically links several third-party C++ libraries for
its Metal renderer, shader compilation, and debugging/crash-reporting
tooling (glslang, SPIRV-Cross, Dear ImGui, Google Breakpad, among others).
Their licenses are upstream Ghostty's responsibility to track and notice as
part of its own build; this repository does not re-vendor or redistribute
their source and defers to upstream Ghostty's own license inventory for
that transitive dependency set.

## Swift packages

Resolved by SwiftPM from `packages/ClairCore/Package.swift`; not vendored.

| Package | License |
| --- | --- |
| [tree-sitter](https://github.com/tree-sitter/tree-sitter) | MIT |
| [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) | BSD-3-Clause |
| [LanguageServerProtocol](https://github.com/ChimeHQ/LanguageServerProtocol) | BSD-3-Clause |
| [JSONRPC](https://github.com/ChimeHQ/JSONRPC) | BSD-3-Clause |

## Vendored tree-sitter grammars

Generated `parser.c`/`scanner.c` sources are vendored under
`packages/ClairCore/Sources/ClairEditorLanguage<Name>/`. Each directory carries
the upstream `LICENSE` and a `VENDOR.md` recording the source commit.

| Directory | Upstream | License |
| --- | --- | --- |
| `ClairEditorLanguageGo` | [tree-sitter-go](https://github.com/tree-sitter/tree-sitter-go) | MIT |
| `ClairEditorLanguageJSON`, `ClairEditorLanguageFixtures` | [tree-sitter-json](https://github.com/tree-sitter/tree-sitter-json) | MIT |
| `ClairEditorLanguageJava` | [tree-sitter-java](https://github.com/tree-sitter/tree-sitter-java) | MIT |
| `ClairEditorLanguageJavaScript` | [tree-sitter-javascript](https://github.com/tree-sitter/tree-sitter-javascript) | MIT |
| `ClairEditorLanguageMarkdown` | [tree-sitter-markdown](https://github.com/tree-sitter-grammars/tree-sitter-markdown) | MIT |
| `ClairEditorLanguagePHP` | [tree-sitter-php](https://github.com/tree-sitter/tree-sitter-php) | MIT |
| `ClairEditorLanguagePython` | [tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python) | MIT |
| `ClairEditorLanguageRuby` | [tree-sitter-ruby](https://github.com/tree-sitter/tree-sitter-ruby) | MIT |
| `ClairEditorLanguageRust` | [tree-sitter-rust](https://github.com/tree-sitter/tree-sitter-rust) | MIT |
| `ClairEditorLanguageShell` | [tree-sitter-bash](https://github.com/tree-sitter/tree-sitter-bash) | MIT |
| `ClairEditorLanguageSwift` | [tree-sitter-swift](https://github.com/alex-pinkus/tree-sitter-swift) | MIT |
| `ClairEditorLanguageTerraform` | [tree-sitter-hcl](https://github.com/tree-sitter-grammars/tree-sitter-hcl) | Apache-2.0 |
| `ClairEditorLanguageTypeScript` | [tree-sitter-typescript](https://github.com/tree-sitter/tree-sitter-typescript) | MIT |

## Repository dependency policy

Apple SDK frameworks and developer toolchains are build prerequisites and are
not redistributed from this repository.

Any dependency that is linked, embedded, copied, or redistributed must update
this file in the same change. Generated notice artifacts belong under
`.build/generated/` and remain untracked; this file remains tracked.

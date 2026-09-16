# Third-party notices

This file is the source of truth for notices that must accompany distributed
Clair binaries.

## Rust standard library

Clair's Rust static library is built with the Rust standard library. Rust is
available under the Apache License 2.0 or the MIT License, at the user's option.

- Project: https://github.com/rust-lang/rust
- License: https://github.com/rust-lang/rust/blob/master/COPYRIGHT

## libc Rust crate

The local PTY host uses the `libc` Rust crate version `0.2.186` for the macOS
`forkpty`, `ioctl`, signal, and `waitpid` ABI calls. The crate is available
under the Apache License 2.0 or the MIT License, at the user's option.

- Project: https://crates.io/crates/libc
- License: https://github.com/rust-lang/libc/blob/main/LICENSE-APACHE

## libghostty / GhosttyKit

Clair's terminal engine (`ClairV2GhosttyABI`/`ClairV2Ghostty`) links the
pinned `libghostty-internal` static library, built from upstream Ghostty at
the commit recorded in `Config/ghostty-pin.json`. Ghostty is available under
the MIT License.

- Project: https://github.com/ghostty-org/ghostty
- Pinned commit: `d4c88d8069912b653d707191388ca98e24751f12` (`1.3.2-dev`)
- License: MIT — Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
- The upstream `LICENSE` file is staged at vendor time to
  `packages/ClairV2Core/Vendor/ghostty/LICENSE-ghostty` (git-ignored,
  materialized by `scripts/v2-ghostty.sh vendor`, not redistributed from
  this repository).

Ghostty's macOS build statically links several third-party C++ libraries for
its Metal renderer, shader compilation, and debugging/crash-reporting
tooling (glslang, SPIRV-Cross, Dear ImGui, Google Breakpad, among others).
Their licenses are upstream Ghostty's responsibility to track and notice as
part of its own build; this repository does not re-vendor or redistribute
their source and defers to upstream Ghostty's own license inventory for
that transitive dependency set.

## Repository dependency policy

The PTY host dependency is resolved through Cargo and is not vendored into this
repository. Apple SDK frameworks and developer toolchains are build prerequisites
and are not redistributed from this repository.

Any dependency that is linked, embedded, copied, or redistributed must update
this file in the same change. Generated notice artifacts belong under
`.build/generated/` and remain untracked; this file remains tracked.

## Native editor PoC (not cleared for distribution)

The native editor PoC has a fixed SwiftPM graph, a binary grammar container,
grammar query resources, Unicode/ICU-derived code, and custom symbol assets.
The complete audit and draft notice inventory are tracked in
[`docs/issues/native-editor/evidence/license-audit.md`](docs/issues/native-editor/evidence/license-audit.md)
and [`docs/issues/native-editor/evidence/THIRD_PARTY_NOTICES.md`](docs/issues/native-editor/evidence/THIRD_PARTY_NOTICES.md).

This inventory is not distribution approval. CodeEditLanguages and
CodeEditSymbols have no root LICENSE/NOTICE at the audited revisions, the
37 grammar licenses are not yet mapped to the binary framework, and the
SF Symbols-derived assets lack per-asset provenance. The PoC must remain
unshipped until those gates are resolved. The known MIT, BSD-3-Clause,
Apache-2.0, and Unicode/ICU notice candidates are recorded in the audit.

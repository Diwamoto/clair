# Development workspace

## Status

Current as of local PoC item `P01 Project and command kernel`.

## Workspace boundary

Clair has one committed Xcode workspace and one Cargo workspace at the repository root.

```text
Clair.xcworkspace
└── Clair.xcodeproj
    ├── ClairStable application target
    ├── ClairDev application target
    └── ClairTests unit-test target

Cargo.toml
├── clair-core (Rust library + static library)
└── clair-ptyhost (process skeleton)
```

The Stable and Dev application targets compile the same files under `apple/ClairApp`.
They differ only through tracked xcconfig values:

| Channel | Scheme | Product | Bundle ID | Application Support |
|---|---|---|---|---|
| Stable | `Clair Stable` | `Clair.app` | `com.diwamoto.clair` | `Clair` |
| Dev | `Clair Dev` | `Clair Dev.app` | `com.diwamoto.clair.dev` | `Clair Dev` |

Runtime identity follows
[ADR-0008](../decisions/0008-stable-dev-runtime-identity.md). Neither target uses a
shared `UserDefaults` suite or data-directory fallback.

## Swift and Rust boundary

The Swift executable owns the SwiftUI application lifecycle, in accordance with
[ADR-0001](../decisions/0001-adopt-swiftui-appkit-frontend.md). The Xcode target
runs `scripts/build-rust.sh` before linking and consumes `target/debug/libclair_core.a`
through `include/clair_core.h`.

The bootstrap ABI contains one allocation-free function:

```c
uint32_t clair_core_smoke(void);
```

It returns `0x434C4149`. PTY streams, object ownership, callbacks, and async control
flow are intentionally absent; later interfaces must document their own lifecycle
and threading contracts.

## Project and command kernel

`ProjectWorkspaceModel` is the single in-process owner of the open Project catalog and
active Project. A Project is a local folder, not a Git repository; Git and non-Git
folders use the same open path. Each Project has a generated UUID that is stored
independently from its display name and root path.

Roots are canonicalized with `standardizedFileURL` followed by symlink resolution.
Opening requires an existing, readable directory. The canonical root is deduplicated
before any catalog mutation, so relative paths and symlink aliases cannot create a
second open Project. Rename changes only the Project display name; it never renames a
folder on disk. Color and order are Project metadata. Close marks a record as not open
and does not delete the record or its folder, allowing a later open of the same root to
reuse its UUID and metadata.

The channel-specific Application Support directory contains `projects-v1.json`. Its
top-level `schemaVersion` is `1`, and writes create the parent directory and use
`Data.write(..., options: [.atomic])`. Closed records remain in the store, while the
published list contains open records only. A missing root remains visible with an
unavailable status after restart; malformed or unsupported state is not overwritten and
is surfaced as a bootstrap diagnostic.

`CommandRegistry` is the transport-neutral typed seam for the kernel. The current
commands use stable `project.*` IDs, typed input structs, a typed result, structured
errors, fixed risk metadata, deterministic availability reasons, and `aiAvailable`
metadata. The SwiftUI sidebar invokes the same `ClairCommand` execution path for open,
switch, rename, color, reorder, and close. CLI/MCP adapters remain later slices.

## Developer command boundary

The root `Makefile` is the supported local and CI interface. Rust 1.98.0 is
pinned by `rust-toolchain.toml`. Shell scripts own
orchestration details, keep DerivedData under `.build/xcode/<purpose>`, and preserve
underlying tool exit codes. GitHub Actions runs `make ci` rather than maintaining a
separate command graph. `make smoke-ffi` also compiles a small Swift CLI against the
Rust static library, so the language boundary can be verified before a full Xcode
application build. `make smoke-app-link` links the complete shared SwiftUI source
graph for both channel compile conditions and verifies the Rust symbol in each
Mach-O executable. Bundle smoke also follows Xcode 26's Debug `*.debug.dylib`
image when the app's main executable is a generated debug stub.

Build output under `.build/`, Cargo `target/`, generated output, and Xcode user state
are disposable and ignored. `THIRD_PARTY_NOTICES.md` is the tracked notice source.

## Project kernel validation

`apple/ClairTests/ProjectKernelTests.swift` covers three folder types in one process,
canonical-root duplicate rejection, invalid/file/unreadable-root isolation, stable ID
reopen, metadata/order persistence, store versioning, and command risk/availability
preflight. `make test-swift` runs these tests in the Dev host app.

## Current limitations

- Builds are unsigned and App Sandbox is disabled.
- `clair-ptyhost` is a process/smoke skeleton and does not own a PTY.
- The C ABI is a link/lifecycle smoke path, not the future domain interface.
- File tree, editor, terminal, pane layout, Git operations, and CLI/MCP adapters remain later queue items.
- Formal app icons, signing, notarization, and update delivery are not present.

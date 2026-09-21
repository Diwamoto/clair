# T01: libghostty / GhosttyKit foundation

Worker: `claude/v2-t01-libghostty-foundation` (isolated worktree)
Base: `230a3f69ac92eed7f0b79d069cc5172affcbc888`
Lease: `e1d05acd-fb9e-489d-9351-f188091e7e49`

Scope: pinned build, license record, resource bundle, C ABI contract, Swift
concurrency boundary, reproducible macOS/iOS build, minimal surface smoke.
Out of scope: rendering surface (`T03`/`T05`), PTY attachment (`T02`/`T04`),
IME/paste/mouse integration (`T06`), integration gate (`T07`).

## Invariants (before implementation)

- The terminal engine is one pinned upstream revision, not a floating branch.
  Upstream repository, commit SHA, build toolchain version and toolchain archive
  digest live in a single tracked manifest (`Config/ghostty-pin.json`). Every
  consumer — build script, SwiftPM manifest and Swift runtime — reads that one
  manifest. A mismatch between the manifest and the materialized artifact is an
  explicit failure, never a silent "use whatever is on disk".
- No upstream binary, static library, xcframework, object file or generated
  Metal library is committed to this repository. The pin plus a deterministic
  fetch/build script is the tracked artifact; materialized output stays inside a
  git-ignored vendor directory.
- License compliance is part of the pin. libghostty is MIT (Ghostty
  contributors). The notice text is captured from the pinned commit at vendor
  time and the pin records the SPDX identifier and copyright line. A vendor run
  that cannot verify the upstream `LICENSE` fails closed.
- The C ABI Clair depends on is an explicit, reviewed subset, not "whatever
  `ghostty.h` currently exports". The subset is declared in one C header and
  checked at compile time against the real `ghostty.h` (function presence and
  struct field layout). An upstream ABI change that breaks the subset must break
  the build, not produce undefined behavior at runtime.
- libghostty is not thread-safe and its app/surface objects are owned by the
  UI thread. The Swift boundary is `@MainActor`-isolated. No C handle is
  `Sendable`, no handle escapes the scope that created it, and no background
  task can reach a raw pointer. Ownership is scope-based (`with…` closures) so
  every allocation has exactly one matching free on the same actor.
- `ghostty_init` runs at most once per process and must succeed before any other
  call. A failed or missing initialization fail-closes every later call with a
  typed error; it never leaves the boundary in a half-initialized state.
- Absence of the vendored artifact is a typed, fail-closed "runtime unavailable"
  condition. It is not a fallback: there is no libvterm path, no emulated
  terminal, no degraded renderer. Clair either talks to the pinned libghostty or
  reports that the terminal engine is not installed.
- Runtime resources (Ghostty terminfo database, shell-integration scripts) are
  staged from the same pinned build as the library, are addressed through the
  bundle API rather than absolute developer paths, and are reported as
  unavailable rather than substituted from the host system.
- Handle-lifetime, initialization-order and availability state are observable
  and testable without the artifact present, so the failure modes have coverage
  on a machine that has never vendored libghostty.

## Pinned dependency

| Field | Value |
| --- | --- |
| Upstream | `https://github.com/ghostty-org/ghostty` |
| Pinned commit | `d4c88d8069912b653d707191388ca98e24751f12` (`1.3.2-dev`) |
| License | MIT — `Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors` |
| Build toolchain | Zig `0.16.0`, archive SHA-256 pinned in the manifest |
| Build mode | `ReleaseFast` |
| Artifact | `GhosttyKit.xcframework` — `macos-arm64_x86_64`, `ios-arm64`, `ios-arm64-simulator` |

### Why a commit pin and not the `v1.3.1` release tag

`v1.3.1` declares `minimum_zig_version = 0.15.2`. Zig `0.15.2` cannot link
against the only Apple SDK available on the supported toolchain here (Xcode
26.5 / `MacOSX26.5.sdk`): linking the native build runner fails with undefined
`_waitpid`, `_sysctlbyname`, `__availability_version_check` and similar libc
symbols, because that Zig release predates the SDK's stub-library format. Zig
`0.16.0` links against the same SDK cleanly, and the first upstream revision
that requires `0.16.0` is post-`v1.3.1` `main` (`1.3.2-dev`). The pin is
therefore forced by toolchain/SDK compatibility, not by preference. It is still
a single immutable commit SHA, so reproducibility is unchanged. When upstream
ships a release tag that requires Zig `0.16.x`, the pin moves to that tag by
editing `Config/ghostty-pin.json` only.

`libghostty`'s C API is explicitly pre-1.0 upstream; pinning an exact revision
is required regardless of whether that revision is a release tag.

## Failure and focused test matrix

| Boundary | Failure mode | Required evidence |
| --- | --- | --- |
| Pin manifest | manifest and Swift constants drift apart | Swift pin constants are asserted equal to the tracked JSON manifest |
| Pin manifest | unpinned/mutable dependency | manifest carries an immutable commit SHA, toolchain version and toolchain digest |
| License | notice missing or non-MIT | pin records SPDX `MIT` + copyright; vendor step verifies upstream `LICENSE` and stages it; `THIRD_PARTY_NOTICES.md` entry |
| Toolchain | wrong or tampered Zig archive | vendor step verifies the archive SHA-256 and the reported `zig version` |
| Source fetch | wrong revision materialized | vendor step verifies `git rev-parse HEAD` equals the pinned SHA |
| C ABI | upstream renames/removes a used function | pinned subset header is compiled against real `ghostty.h`; missing symbol is a compile error |
| C ABI | upstream changes a used struct layout | `_Static_assert` on `sizeof`/`offsetof` of every consumed struct |
| Availability | artifact absent | every entry point throws `runtimeUnavailable`; nothing falls back to a non-Ghostty engine |
| Initialization | call before `activate()` | typed `notActivated` error, no C call issued |
| Initialization | repeated activation | `ghostty_init` invoked at most once; second activation is a no-op success |
| Initialization | `ghostty_init` failure | typed `initializationFailed` with the upstream message; later calls stay fail-closed |
| Handle lifetime | use after scope exit | handle is invalidated at scope exit and further use throws `handleExpired` before any C call |
| Handle lifetime | double free | scope-based ownership frees exactly once; invalidated handle cannot be freed again |
| Concurrency | handle escapes to another thread | handles are non-`Sendable`; boundary is `@MainActor`; enforced at compile time under Swift 6 strict concurrency |
| Resources | terminfo/shell-integration missing | bundle lookup returns a typed `resourceMissing`, never a host-system substitute |
| Reproducible build | macOS slice | `swift build` of the Ghostty targets on macOS |
| Reproducible build | iOS slice | `swift build --triple arm64-apple-ios17.0-simulator` of the Ghostty targets against the iPhone Simulator SDK |
| Minimal surface smoke | linked engine is actually callable | with the artifact vendored, `ghostty_init` + `ghostty_info` + config allocate/free round-trip through the pinned ABI |

"Minimal surface" here means the minimal *exposed ABI surface* (initialization,
build info, configuration lifetime). `ghostty_surface_t` creation requires a
renderer, a runtime callback table and a PTY, all of which belong to `T03`/`T05`;
this task deliberately stops below that line.

## Boundary shape

```text
Config/ghostty-pin.json          single source of truth for the pin
scripts/ghostty.sh            vendor | verify | status | clean
packages/ClairCore
  Sources/ClairGhosttyABI      C: pinned ABI subset + layout static asserts
  Sources/ClairGhostty         Swift: @MainActor boundary, typed errors,
                                 availability, scoped handles, resources
  Vendor/ghostty/                git-ignored materialized artifact + resources
```

`Package.swift` links the vendored `GhosttyKit.xcframework` when it is present
and compiles the same sources in "not linked" mode when it is not, so the
package graph builds on a machine that has never run the vendor step while the
runtime still refuses to pretend a terminal engine exists.

## Controller-owned

Full serialized Swift suite, independent D5 review, app/simulator/device
verification, signing, queue updates and integration remain with the controller.

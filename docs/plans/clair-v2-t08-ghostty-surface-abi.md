# T08: `ghostty_surface_*` ABI + real vendor + macOS embedding smoke

Worker: `claude/v2-t08-ghostty-surface-abi` (isolated worktree)
Base: `bd338447b9c11d2552c8706b38a3389f24d8bb84`
Lease: `3f45f17a-782d-4423-8244-5502e95904cb`

Scope: close the gap `T03` discovered — `ClairV2GhosttyABI` pinned only
init/info/config, and libghostty was never actually vendored anywhere, so a
real macOS Ghostty surface could not be created, fed real PTY-driven output,
or read back. T08 pins the `ghostty_surface_*` C ABI subset a real embedder
needs, makes `scripts/v2-ghostty.sh vendor` actually fetch/build/verify the
pinned commit, and proves the whole path with a real macOS smoke test.
Out of scope: `T03`'s own macOS surface-view integration (rendering,
selection, copy/paste against a real grid) — that is a separate task the
controller reactivates once this lands; iOS slices (`T05`); the shared
runtime callback surface (clipboard/action delivery) beyond fail-safe no-ops.

## Invariants (before implementation)

- The `ghostty_surface_*` subset is an explicit, reviewed subset, exactly
  like T01's init/info/config subset: declared once with a `clair_` prefix,
  and checked at compile time against the real `ghostty.h` (function
  presence via function-pointer probes, struct layout via
  `_Static_assert(sizeof/offsetof, ...)`) whenever the library is vendored.
  An upstream rename, removal, or layout change is a compile error here, not
  runtime drift.
- Two upstream types are deliberately *not* mirrored with their own
  `clair_`-prefixed clone even though one crosses this ABI by value:
  `ghostty_target_s`/`ghostty_action_s` (the app's `action_cb` runtime
  callback arguments). They are a large tagged union of every action
  variant the full macOS app handles; Clair's callback is a fixed no-op
  that reports "not handled" and never decodes the payload. When vendored,
  the callback is declared against the *real* upstream types directly (via
  `#include <ghostty.h>`), so a real signature change is still a compile
  error; only the additional field-level assertions this file gives every
  struct it actually reads are skipped for this pair.
- libghostty's runtime callback table (wakeup, clipboard read/confirm/write,
  action) is never exposed across the Swift boundary. `ClairV2GhosttyABI`
  supplies one fixed, always-safe callback implementation internally
  (no-op wakeup, "unavailable" clipboard reads, silently-dropped clipboard
  writes, "not handled" actions) and hides it behind
  `clair_ghostty_app_new(config)`. A future task that needs real
  clipboard/action integration extends this table (and adds its own
  layout assertions for whatever payload it then reads) rather than
  punching a hole through it for Swift to fill in ad hoc.
- "Feeding PTY output into a surface" at this ABI layer means configuring
  the real child process libghostty itself spawns for that surface
  (`ghostty_surface_config_s.command`/`.initial_input`/`.working_directory`)
  — libghostty owns the PTY for surfaces it creates; there is no upstream
  entry point to inject externally-produced bytes into a surface's PTY
  from outside. Any future task that needs Clair's own already-owned PTY
  (`ClairV2PTY`/`T02`'s daemon-owned sessions) to *feed* a Ghostty surface
  is a distinct integration this task does not attempt.
- `scripts/v2-ghostty.sh vendor` is real: it fetches and SHA-256-verifies
  the pinned Zig toolchain archive (never trusts a PATH `zig`), clones the
  pinned upstream commit and verifies `git rev-parse HEAD` against the pin,
  verifies the upstream `LICENSE` file's identifier and copyright line
  against the pin before staging it, and only then runs a real `zig build`
  that produces `GhosttyKit.xcframework`. Any of these checks failing is a
  hard failure, never a silent partial artifact.
- The materialized vendor artifact and its fetch/build cache are git-ignored
  (`/packages/ClairV2Core/Vendor/ghostty/`, `/.cache/v2-ghostty/`); the pin
  manifest plus this script are the only tracked, reviewable state. No
  binary is committed.
- Absence of the vendored artifact remains a typed, fail-closed
  `.runtimeUnavailable` condition for every new entry point exactly as for
  T01's subset — no libvterm/emulated-terminal fallback, and no new failure
  mode silently returns a default value instead of throwing.
- Every C handle this subset introduces (`clair_ghostty_app_t`,
  `clair_ghostty_surface_t`) follows the same ownership discipline as
  `clair_ghostty_config_t`: scope-bound Swift handles (`GhosttyAppHandle`,
  `GhosttySurfaceHandle`), `@MainActor`-isolated, invalidated at scope exit,
  never `Sendable` (the one exception, `GhosttySurfacePlatform`'s raw view
  pointer, is `@unchecked Sendable` specifically because it is only ever
  constructed/consumed on the main actor, matching this file's actual
  concurrency boundary rather than papering over it).

## Real, load-bearing bugs found and fixed while proving this end-to-end

T01 never actually vendored libghostty in its own environment (its own
evidence says so explicitly), so several real defects in the vendor/build
path had never been exercised. T08 found and fixed all of them by actually
running the pipeline, not just extending it on paper:

1. **`Config/ghostty-pin.json`'s Zig archive URL was a 404.** `zig-macos-
   aarch64-0.16.0.tar.xz` returned an nginx 404 page (Zig renamed its
   archive naming convention). Fixed to the real
   `zig-aarch64-macos-0.16.0.tar.xz`, with its real SHA-256 (the pin had a
   placeholder all-zero digest).
2. **`clair_ghostty_init`/`_info`/`_config_new`/`_config_free` were
   function-like macros.** Swift's Clang importer does not import
   function-like macros that expand to a call expression, so
   `GhosttyRuntime.swift`'s calls to them were never actually reachable —
   this only surfaces as a hard compile error the moment the library is
   really vendored and `swift build` runs against it. Converted to real
   functions.
3. **`CLAIR_GHOSTTY_VENDORED` never reached the Clang importer for
   `ClairV2Ghostty`'s `import ClairV2GhosttyABI`.** The ABI target's
   `cSettings` define only affects compiling that target's own `.c` file;
   consuming it from Swift needs its own `-Xcc -D…` flag. Without this fix,
   every declaration inside `clair_ghostty_abi.h`'s vendored block —
   T01's original subset included — was invisible to Swift regardless of
   vendored status. Fixed via `swiftSettings: [.unsafeFlags(["-Xcc",
   "-DCLAIR_GHOSTTY_VENDORED"])]`.
4. **`.linkedFramework("GhosttyKit")` fails at link time.** The vendored
   xcframework's macOS slice wraps a static library
   (`libghostty-internal.a`), not a `.framework` bundle; `-framework
   GhosttyKit` cannot find it. The `.binaryTarget`/`.target(name:
   "GhosttyKit")` dependency is sufficient on its own.
5. **Missing system framework/library link flags.** libghostty's Metal
   renderer and embedded C++ dependencies (glslang, SPIRV-Cross, Dear
   ImGui, Breakpad) need `AppKit`, `Metal`, `QuartzCore`, `CoreVideo`,
   `IOSurface`, `CoreText`, `CoreGraphics`, `Carbon`, `Security`,
   `SystemConfiguration`, `CoreServices`, `UniformTypeIdentifiers`,
   `IOKit`, `OSLog`, and `libc++` — none of which a static library can
   declare as its own link dependency. Derived by linking a standalone C
   smoke test against the built xcframework and resolving every
   "undefined symbol" error one at a time, then encoded into
   `ClairV2GhosttyABI`'s `linkerSettings`.
6. **The vendor artifact directory was never actually git-ignored.**
   `docs/plans/clair-v2-t01-libghostty-foundation.md` states the
   materialized artifact "stays inside a git-ignored vendor directory," but
   no `.gitignore` entry existed. Added
   `/packages/ClairV2Core/Vendor/ghostty/` and `/.cache/v2-ghostty/`.
7. **The Apple Metal shader compiler was not installed.** `zig build
   -Demit-xcframework=true` fails with "cannot execute tool 'metal' due to
   missing Metal Toolchain" until `xcodebuild -downloadComponent
   MetalToolchain` has been run once. This is a one-time host/Xcode
   setup step, not a repository fix; documented here and in the vendor
   script's comments since it is the first failure an operator hits.

## Pinned dependency (unchanged from T01, plus vendor build flags)

| Field | Value |
| --- | --- |
| Upstream | `https://github.com/ghostty-org/ghostty` |
| Pinned commit | `d4c88d8069912b653d707191388ca98e24751f12` (`1.3.2-dev`) |
| License | MIT — `Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors` |
| Build toolchain | Zig `0.16.0`, fetched+SHA-256-verified by `vendor`, never PATH `zig` |
| Build flags | `-Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false` |
| Artifact (this task) | `GhosttyKit.xcframework`, **`macos-arm64` slice only** |

### Slice scope decision

T08's task text asks for a macOS smoke test; it does not require the
universal macOS (`arm64_x86_64`) slice or either iOS slice. Building those
needs cross-compiling the x86_64 half and linking against iOS/iOS-Simulator
SDKs, which is real additional surface area this task did not need to prove
the ABI or the vendor pipeline. `vendor()` therefore builds only the native
`macos-arm64` slice (`-Dxcframework-target=native`, the arch of the
machine actually running this). `Config/ghostty-pin.json` records this as
`vendored_slices` / `vendored_slices_note`, separate from the long-standing
`slices` aspiration list, so the gap is explicit rather than silently
narrower than what the manifest implies. `T05` (iOS Ghostty surface)
extends `vendor()` to the remaining slices when it needs them.

## Failure and focused test matrix

| Boundary | Failure mode | Required evidence |
| --- | --- | --- |
| Pin manifest | wrong/unreachable toolchain archive URL | `vendor` fetch fails closed (network error), not a silent skip; fixed the actual 404 found in this pin |
| Toolchain | tampered/wrong Zig archive | `vendor` verifies SHA-256 before extracting; mismatch deletes the partial download and fails |
| Toolchain | fetched archive reports wrong version | `vendor` compares `zig version` output against the pin and fails if they differ |
| Source fetch | wrong revision materialized | `vendor` verifies `git rev-parse HEAD` equals the pinned commit |
| License | LICENSE missing, or copyright/identifier drifted from the pin | `vendor` greps the real upstream `LICENSE` for the pinned SPDX identifier and exact copyright line before staging it; either check failing is a hard failure |
| Build | Metal Toolchain not installed | `zig build -Demit-xcframework=true` fails with an actionable "missing Metal Toolchain" message; documented as a one-time host setup step |
| Build | build succeeds but artifact missing | `vendor` checks `Info.plist` exists in the freshly-built xcframework before copying it into the vendor dir |
| Status | artifact never vendored | `scripts/v2-ghostty.sh status` reports `absent` (unchanged T01 behavior); this task additionally proves `status` reports `present` after a real `vendor` run |
| C ABI | upstream renames/removes a used `ghostty_surface_*`/`ghostty_app_*` function | pinned subset compiled against real `ghostty.h`; missing/changed symbol is a compile error via the function-pointer probes |
| C ABI | upstream changes a used struct's layout (`surface_config_s`, `surface_size_s`, `point_s`, `selection_s`, `text_s`, clipboard structs) | `_Static_assert` on `sizeof`/`offsetof` of every field this subset reads or writes |
| Swift import | vendored declarations invisible to Swift | `swift build --target ClairV2Ghostty` with the artifact vendored actually compiles and links (this is the T08-discovered gap #2/#3 above; both are now covered by every test in this file running for real, not by a dedicated regression test, since the failure mode *is* "the whole target fails to build") |
| Availability | artifact absent | every new entry point (`withApp`, `withSurface`, `tick`, `setSize`, `size`, `readText`) throws `GhosttyError.runtimeUnavailable`, exactly like T01's subset |
| Handle lifetime | use after scope exit | `GhosttyAppHandle`/`GhosttySurfaceHandle` invalidate at scope exit; further use throws `.handleExpired` before any C call |
| Minimal surface smoke | known PTY output round-trips through a real surface | `testFullSurfaceEmbeddingRoundTripsKnownOutput` (macOS-only): a real `ghostty_app_t` + real `ghostty_surface_t` backed by a real (offscreen) `NSView`, spawning a real `/bin/sh` child that `printf`s a unique marker, ticking the app loop until `ghostty_surface_read_text(.screen)` contains that marker, then separately reading `.cursor` and `size()` |
| Cursor readback | no direct "get cursor row/column" call exists upstream at this layer | documented explicitly: `GhosttySurfaceSelection.cursor` (`CLAIR_GHOSTTY_POINT_ACTIVE`) is the closest verifiable equivalent this internal embedder ABI exposes; the smoke test exercises it without asserting exact shell-prompt content (which is not fully deterministic) |

## Boundary shape (extends T01's)

```text
Config/ghostty-pin.json          pin + toolchain digest + vendored_slices note
scripts/v2-ghostty.sh             vendor | verify | status | clean — vendor is now real
packages/ClairV2Core
  Sources/ClairV2GhosttyABI       + ghostty_surface_* subset, real functions (not macros),
                                   internal fixed-safe runtime callback table
  Sources/ClairV2Ghostty          + GhosttyAppHandle, GhosttySurfaceHandle,
                                   GhosttyRuntime.withApp
  Vendor/ghostty/                 git-ignored materialized artifact (macos-arm64 only)
```

`Package.swift`'s `ClairV2GhosttyABI` target now also carries the system
framework/library linker settings real linking against the vendored
library requires, and `ClairV2Ghostty`'s Swift settings forward
`CLAIR_GHOSTTY_VENDORED` to the Clang importer, not only to its own Swift
compilation.

## Controller-owned

`T03`'s macOS surface-view integration (wiring `ClairV2GhosttySurfaceView`
to a real `GhosttyAppHandle`/`GhosttySurfaceHandle` for rendering,
selection, and copy/paste), `T05`'s iOS slice, full serialized Swift suite,
independent D5 review, app/simulator/device verification, signing, queue
updates and integration remain with the controller.

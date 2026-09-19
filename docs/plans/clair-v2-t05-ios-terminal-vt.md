# T05: iOS/iPadOS terminal surface via `libghostty-vt`

Worker: `claude/v2-t05-ios-ghostty-surface-v2` (isolated worktree)
Base: `df7374588ab54f55587cf7978e2f8fbc9031f59c`
Lease: `9aedbe56-92c6-4d91-a6fd-62e2bda37a38`

Scope: implement the iOS/iPadOS terminal surface and remote session attach
the architecture decision recorded in the `T05` queue row (2026-09-18)
calls for: parse `T04`'s raw PTY byte stream with the separate
`libghostty-vt` artifact (not libghostty's GPU embedder, which does not
build for iOS at the pinned commit and has no cell-grid readback API even
where it does build) and render it with a Clair-owned iOS `UIView`. Out of
scope: `T06` (IME/CJK, paste guard, mouse reporting, desktop-owned PTY
geometry integration), a live Network.framework/TLS transport adapter (no
mobile domain in this codebase has one yet — see below), `U06`-level visual
polish (no Design canvas/Workbench terminal spec exists for iOS yet).

## Feasibility verification (done before any implementation)

Confirmed at the pinned commit (`d4c88d8069912b653d707191388ca98e24751f12`,
same pinned Zig `0.16.0` toolchain as `T01`/`T08`):

- `zig build -Doptimize=ReleaseFast -Demit-lib-vt=true -Dtarget=aarch64-ios`
  and `-Dtarget=aarch64-ios-simulator` both succeed and produce a real
  `libghostty-vt.a` — confirmed via `otool -l` `LC_BUILD_VERSION`
  (`platform=IOS`/`IOSSIMULATOR` respectively) plus the full
  `include/ghostty/vt/*.h` C header tree.
- The resulting API (`ghostty/vt.h` and friends) is a complete, documented,
  stable-looking terminal-state library: `ghostty_terminal_new/free/reset/
  resize/vt_write/get`, grid references (`ghostty_terminal_grid_ref`,
  `ghostty_grid_ref_cell/row`), a plain-text/VT/HTML formatter
  (`ghostty_terminal_selection_format_alloc`, `ghostty_terminal_select_all`),
  scroll-viewport control, and a full selection-gesture/key/mouse-encoding
  surface for later tasks. This is sufficient for T05's acceptance without
  any independent ANSI/VT interpreter.
- Packaging: `xcodebuild -create-xcframework -library <device>/libghostty-vt.a
  -headers <device>/include -library <sim>/libghostty-vt.a -headers
  <sim>/include -output GhosttyVT.xcframework` succeeds and produces a
  two-slice (`ios-arm64`, `ios-arm64-simulator`) static-library xcframework
  SwiftPM can consume as a `.binaryTarget`.
- No genuine blocker was hit. Implementation proceeded.

## Invariants

- **No fallback terminal engine.** Absence of the vendored artifact
  (`CLAIR_GHOSTTY_VT_VENDORED` not defined — the default on every non-iOS
  build, and any iOS build before `scripts/v2-ghostty.sh vendor-vt` has
  run) fails every `GhosttyVTTerminal`/`ClairV2MobileTerminalSession` call
  closed with `GhosttyVTError.runtimeUnavailable`. No independently written
  ANSI/VT interpreter exists anywhere in this change, matching the
  repository's standing no-fallback rewrite decision and T01/T08's
  precedent for the macOS embedder.
- **Separate vendored artifact, separate gating.** `GhosttyVT.xcframework`
  (iOS device + simulator slices only, no macOS slice — unlike
  `GhosttyKit.xcframework`) is vendored and gated independently of the
  macOS embedder artifact: a worktree can have either, both, or neither
  vendored (`scripts/v2-ghostty.sh vendor` vs `vendor-vt`,
  `ghosttyVendored` vs `ghosttyVTVendored` in `Package.swift`). Every place
  `GhosttyVTKit`/`CLAIR_GHOSTTY_VT_VENDORED` reaches a target is
  `.when(platforms: [.iOS])`-gated so a macOS build never attempts to link
  a binary artifact that has no macOS slice.
- **Pinned ABI subset, checked at compile time.** `ClairV2GhosttyVTABI`
  mirrors exactly the subset of `libghostty-vt` Clair uses under a
  `clair_` prefix, with `_Static_assert(sizeof/offsetof, ...)` struct
  layout checks and function-pointer-probe signature checks against the
  real headers whenever vendored — the same T01/T08 pattern, scoped to ~10
  functions (`terminal_new/free/resize/write`, five `terminal_get`
  accessors, `grid_ref`, `select_all`, `selection_format_alloc`,
  `scroll_viewport`, `free`) instead of mirroring the packed-cell
  `GhosttyCell`/`GhosttyRow` decode API (see "Design decisions" below for
  why that subset is sufficient).
- **Desktop-owned PTY geometry is never implicitly changed by this
  feature.** The local `GhosttyVTTerminal`'s column/row count always
  matches the size the daemon's attach response reports
  (`ClairV2MobileTerminalAttachment.size`, synced in
  `ClairV2MobileTerminalSession.foreground`), never the phone's screen
  size. `ClairV2TerminalView`'s safe-area/rotation handling only changes
  how many of those fixed rows are visible at once
  (`layoutSubviews`/`visibleRowCount`), never the underlying grid
  dimensions — consistent with the existing `T06` invariant ("mobile
  attach が desktop rows/columns を暗黙に変えないこと").
- **Background detach releases the daemon-side subscriber slot, not just
  local state.** `ClairV2MobileTerminalSession.background()` calls
  `transport.detach` (T04's `ClairV2TerminalBoundary.detach`), which
  removes this device's `Subscriber` entry so its slot counts against
  `maximumSubscribers` no longer. Proven by
  `backgroundDetachesReleasingTheSubscriberSlot` (a second device's attach
  fails while the slot is held, succeeds once released) rather than by
  asserting local state alone.
- **Foreground reattach resumes from the last acknowledged cursor, and
  resyncs (never wedges) if that cursor is no longer retained.** T04's
  journal is a bounded-capacity ring per session, independent of
  subscriber count; a long-backgrounded device's cursor can fall outside
  the retained window. `ClairV2MobileTerminalSession.foreground` tries the
  last acknowledged cursor first, and on any failure falls back to a fresh
  attach with no cursor (starts from the journal's current retained
  start). This trades the backgrounded interval's backlog for staying
  attachable — never a stuck `.failed` state, never a corrupted VT parse
  from a gap silently skipped mid-stream.
- **No new Mac-side cell-grid readback API.** Reconnect/resync stays
  entirely inside T04's existing bounded byte-journal contract
  (`ClairV2TerminalJournal`/`ClairV2TerminalBoundary`); this task does not
  add a "reconstruct the colored cell grid as ANSI on reattach" endpoint
  (a real feature observed in the `Muxy` reference product, but not part
  of this task's acceptance text — released as future scope if ever
  needed).
- **The mobile app never links host-only `ClairV2DaemonKit` code.**
  `ClairV2MobileTerminalAttachment` is a deliberate mobile-local mirror of
  the daemon-only `ClairV2TerminalAttachment`, the same pattern
  `ClairV2MobilePushRegistrationSnapshot` already established for H09's
  daemon push-registration snapshot.
- **Transport-neutral, matching this codebase's actual mobile-network
  maturity.** Every mobile domain in this repository (pairing, agent
  conversation, workspace, push registration) is, as of this task, still a
  transport-neutral protocol plus an explicit `.unavailable` stub — there
  is no live Network.framework/TLS socket adapter for *any* domain yet
  (`ClairNetworkTLSMobileTransportBoundary.openChannel` always throws
  `.unavailable`). `ClairV2MobileTerminalTransport` follows the same
  shape: a protocol mirroring `ClairV2TerminalBoundary`'s five operations,
  a `ClairV2MobileUnavailableTerminalTransport` stub, and (test-only) an
  in-process adapter wrapping a real `ClairV2TerminalBoundary` — proving
  the real attach/read/acknowledge/input/detach contract without a socket,
  the same H03-style seam `ClairInProcessMobileTransport` already uses for
  every other mobile domain's tests.
- **Hardware keyboard input is a minimal, standard VT100/xterm encoding,
  not libghostty-vt's Kitty-keyboard-protocol encoder.** `ClairV2TerminalKeyEncoding`
  (plain Swift, no UIKit dependency) covers plain text, arrows, tab/return/
  escape/backspace/delete, home/end/page up/down, and Ctrl-<letter> C0
  chords. Modifier disambiguation and application-mode key variants are
  explicitly deferred to `T06`, which this table is additive with, not a
  replacement for.
- **Testability of the highest-risk logic does not depend on a vendored
  iOS build.** `ClairV2MobileTerminalSession`'s attach/pump/gap-resync/
  background-detach/keyboard-input state machine is injectable
  (`ClairV2TerminalEngine` protocol, `GhosttyVTTerminal` is the only
  production conformance) so it is covered by a real `swift test` run on
  any host, against a real `ClairV2TerminalBoundary`, not just against a
  fake.

## Design decisions

- **Plain-text formatting instead of manual cell-grid decoding.**
  `libghostty-vt` exposes both a packed 64-bit `GhosttyCell`/opaque
  `GhosttyRow` API (`screen.h`) and a higher-level plain-text/VT/HTML
  formatter (`formatter.h`, `selection.h`'s one-shot
  `ghostty_terminal_selection_format_alloc`). T05 uses only the latter:
  `ghostty_terminal_select_all()` + `ghostty_terminal_selection_format_alloc(...,
  emit: PLAIN)` yields exactly the "array of visible-line strings" shape
  `ClairV2TerminalView`'s CoreText renderer wants — the same shape E06/E08's
  `EditorLineRenderer` consumes from `TextSnapshot`. This is the reuse
  E06/E08 established, applied at the data-shape level, not just the
  drawing-code level, and it means this task's minimal-UI scope (no
  per-cell color/attribute rendering; see below) never has to decode the
  packed cell format at all.
- **No per-cell color/attribute rendering in this task.** `GhosttyVTScreenSnapshot.lines`
  is plain text. The Design canvas/Workbench define no iOS terminal visual
  language yet (the parent plan's Phase 5 sequencing notes explicitly defer
  iOS terminal UI polish past this task), so inventing an attribute-aware
  renderer now would be native-only visual design nothing has approved.
  Colors/attributes are additive future work once `screen.h`'s cell API is
  pinned for that purpose.
- **Touch selection uses `UILongPressGestureRecognizer`/`UIPanGestureRecognizer`
  with a custom highlight overlay, not `UITextInput`/`UITextInteraction`.**
  E08's `ClairEditorView+iOS.swift` uses `UITextInteraction` because it is
  editing a real document (undo, IME composition, insertion point). A
  terminal's on-screen content is read-only ephemeral output; `UITextInput`'s
  ~15-method contract (`text(in:)`, `replace(_:withText:)`,
  `firstRectForRange`, …) does not semantically fit and would be
  substantially unrequested surface. This mirrors how terminal apps
  generally implement selection over rendered output.
- **Hardware keyboard text uses `UIKeyInput`, not `UITextInput`.**
  `UIKeyInput` (`insertText`/`deleteBackward`/`hasText`) is the standard,
  minimal native protocol for "forward each character immediately, no
  buffer/selection semantics" — exactly a terminal's needs, and
  significantly smaller than `UITextInput`.
- **Font size is fixed in this task; auto-fit-to-width and vertical
  scrollbar chrome are deferred.** `ponytail:` the view always uses a
  13pt monospaced system font and clips whatever does not fit instead of
  scaling to fit the fixed remote column/row count into the device width;
  add auto-fit sizing when real-device testing shows it is needed.

## Failure and focused test matrix

| Boundary | Failure mode | Required evidence |
| --- | --- | --- |
| Pin manifest / vendor-vt | `-Dtarget=aarch64-ios` full-embedder build rejects iOS | Confirmed via real `zig build` invocation; `Config/ghostty-pin.json`'s `libghostty_vt` block records the `-Demit-lib-vt=true` escape hatch and both real cross-builds (device + simulator) that succeeded |
| `scripts/v2-ghostty.sh vendor-vt` | build succeeds but artifact/headers missing | checks `libghostty-vt.a` exists per target before packaging, and `GhosttyVT.xcframework/Info.plist` exists after `xcodebuild -create-xcframework` |
| `Package.swift` | `GhosttyVTKit` (iOS-only slices) linked into a macOS target | every dependency edge/define/linker setting reaching it is `.when(platforms: [.iOS])`-gated; verified by a clean `swift build --package-path packages/ClairV2Core` (macOS host) with the artifact vendored |
| C ABI | upstream renames/removes/changes layout of a used `ghostty_terminal_*`/`ghostty_grid_ref_*`/`ghostty_free` symbol or struct | `_Static_assert`/function-pointer probes in `clair_ghostty_vt_abi.h`, compiled for real against the vendored headers via `swift build --triple arm64-apple-ios17.0-simulator`/`arm64-apple-ios17.0` |
| Availability | artifact absent (default state) | `GhosttyVTTerminal.isVendored == false`; every method throws `.runtimeUnavailable` (`ClairV2GhosttyVTTests`) |
| Argument validation | non-positive columns/rows | `.invalidValue` before the vendored check even runs (`testTerminalInitRejectsNonPositiveDimensionsBeforeCheckingVendored`) |
| Handle lifetime | `@MainActor` class `deinit` touching a non-`Sendable` C pointer | `isolated deinit` (same fix T03 already made for `ClairV2GhosttySurfaceView`); caught by the iOS Simulator cross-build, not by the macOS-only build (documented explicitly so a future non-iOS-gated change does not silently reintroduce it) |
| Remote attach | daemon journal has no data yet | `read()` returns `nil`; pump backs off (50ms) instead of busy-polling (`foregroundAttachesReadsBufferedOutputAndAcknowledges`) |
| Background detach | local state says detached but daemon subscriber slot still held | `backgroundDetachesReleasingTheSubscriberSlot`: a second device's attach fails while held, succeeds once released |
| Foreground reattach | cursor still valid | resumes without re-delivering already-acknowledged bytes (`foregroundAfterBackgroundResumesFromTheAcknowledgedCursor`) |
| Foreground reattach | cursor pruned past the bounded journal's retained window | falls back to a fresh no-cursor attach instead of failing (`staleAcknowledgedCursorFallsBackToFreshResyncAttach`) |
| Hardware keyboard | key event before attach | no-op, not a crash/error (`sendKeyBeforeAttachIsANoOp`) |
| Hardware keyboard | plain text / named keys / arrows / navigation / control chords | exact byte-for-byte encoding (`ClairV2TerminalKeyEncodingTests`, 7 tests) |
| Hardware keyboard | control chord outside A–Z | encodes to nothing rather than guessing (`controlChordOutsideLettersEncodesToNothing`) |
| Mobile/daemon boundary | mobile code accidentally imports `ClairV2DaemonKit` | impossible by construction: `ClairV2MobileKit`/`ClairV2TerminalView` do not depend on `ClairV2DaemonKit` in `Package.swift`; only the test fixture (`@testable import ClairV2DaemonKit` in `ClairV2CoreTests`) does |

## Boundary shape

```text
Config/ghostty-pin.json            + libghostty_vt block (separate artifact/flags from `build`)
scripts/v2-ghostty.sh               + vendor-vt (iOS device+simulator, xcodebuild -create-xcframework)
packages/ClairV2Core
  Sources/ClairV2GhosttyVTABI       clair_ghostty_vt_abi.{h,c} — pinned libghostty-vt C ABI subset
  Sources/ClairV2GhosttyVT          GhosttyVTTerminal (@MainActor), ClairV2TerminalEngine protocol,
                                     GhosttyVTError, GhosttyVTScreenSnapshot/Cursor/ViewportPoint
  Sources/ClairV2Terminal           + ClairV2TerminalKeyEncoding (platform-neutral VT100/xterm encoder)
  Sources/ClairV2MobileKit          + ClairV2MobileTerminalTransport (protocol + Unavailable stub),
                                     ClairV2MobileTerminalSession (attach/pump/detach/resync/keys)
  Sources/ClairV2TerminalView       ClairV2TerminalView: iOS UIView (#if os(iOS)) — CoreText render,
                                     touch scroll/selection, UIKeyInput/UIKeyCommand, safe-area/rotation,
                                     UIApplication background/foreground lifecycle wiring
  Vendor/ghostty/                   + GhosttyVT.xcframework, include-vt/ (git-ignored, iOS-only)
```

## Controller-owned

Independent D5 review, `T06` (IME/CJK, paste guard, mouse reporting,
desktop-owned PTY geometry integration), a real Network.framework/TLS
transport adapter for `ClairV2MobileTerminalTransport` (mirrors the
already-deferred state of every other mobile domain's transport), `U06`
(Mac terminal UI polish) and any iOS terminal visual-design work once the
Design canvas defines one, real-device/simulator interactive verification,
signing, queue updates, and integration remain with the controller.

## Known gaps / not executed

- No iOS Simulator or device app actually ran `ClairV2TerminalView`
  interactively in this task (no simulator boot, no `xcodebuild test`
  against an iOS destination) — verification is a real `zig build`/
  `xcodebuild -create-xcframework` vendor pipeline plus real
  `swift build --triple arm64-apple-ios17.0[-simulator]` cross-compiles of
  every new/touched target, which compiles and links the vendored path for
  real (catching, for example, the `isolated deinit` bug the macOS-only
  build could not), plus the full test suite passing on macOS for the
  platform-neutral logic. Touch gesture feel, on-device keyboard behavior,
  Dynamic Type, VoiceOver, and actual visual layout on a real screen are
  unverified, the same category of gap E07/E08 already recorded for their
  own iOS work.
- `GhosttyVTTerminal`'s vendored-path unit test
  (`testKnownVTBytesRoundTripToParsedScreenAndCursor`) is skipped on every
  host in this repository's normal `swift test`/`make test-swift` flow
  (macOS-only, and `GhosttyVT.xcframework` has no macOS slice); it only
  runs on an iOS test host, which this repository does not target today.

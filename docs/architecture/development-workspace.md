# Development workspace

## Status

Current as of local PoC item `P10 Managed worktrees`.

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
└── clair-ptyhost (local PTY host)
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

It returns `0x434C4149`. The live terminal does not use this C ABI. The app connects
to a same-user local broker over a bounded Unix-socket protocol; the direct
`clair-ptyhost --spawn` path remains a low-level smoke/compatibility path. Later
interfaces must document their own lifecycle and threading contracts rather than
extending the bootstrap symbol implicitly.

## Live terminal path

Each visible Project terminal owns one `TerminalSession` and one stable `SessionID`.
The session connects to a per-channel local broker under the channel-specific
Application Support directory. If the broker is unavailable, the app starts a
detached `clair-ptyhost --broker` child with null standard streams; the broker then
owns the PTY independently of the app process. The broker uses macOS `forkpty`,
starts a login shell with `TERM=xterm-256color`, applies `TIOCSWINSZ` on resize,
forwards input bytes unchanged, and terminates the child process group when asked.
The host waits for and reports the child exit status, so a normal shell exit cannot
leave an unreaped local child.

The broker transport is version 1 and has this fixed header:

```text
magic[2] = CB | version[1] | kind[1] | payload_length[4, big endian] | payload
```

Payloads are capped at 64 KiB before allocation. Client frames are attach/create or
reattach, raw input, resize (`rows`, `columns` as big-endian `u16` values), detach,
and terminate. Host frames include an attachment snapshot, output with a byte
cursor, explicit gap, exit status, and bounded diagnostic error. Partial reads are
buffered; malformed or oversized frames are rejected without allocating the claimed
payload.

The broker persists only a versioned metadata catalog at
`sessions-v1.catalog`; the socket and catalog are owner-only (`0600`). The catalog
contains session identity, shell, working directory, dimensions, and epoch, but no
terminal bytes. Live output is retained in a bounded 256 KiB journal and each
subscriber has a bounded 256 KiB queue. If a cursor or slow subscriber falls behind,
the broker emits a gap and the plain-text client resets its transcript with an
explicit recovery marker. This is a local single-user lifecycle slice; remote
multi-client sessions, semantic agent adapters, and relay/E2EE remain deferred.

`TerminalSurfaceView` is an AppKit-backed selectable and scrollable native surface,
embedded in the SwiftUI Project shell. It forwards ordinary keys, control keys,
navigation sequences, and UTF-8 text to the PTY. The current surface keeps a bounded
2 MiB sanitized transcript for rendering and selection; split ANSI CSI/OSC-like
sequences are removed from this plain-text fallback, while CJK UTF-8 bytes are
retained. This is deliberately a reversible feasibility slice, not a replacement
for a terminal grid renderer.

The local checkout does not contain a public libghostty development header/library
that can be built and linked reproducibly. Therefore P03 records the AppKit native
fallback as the verified surface and leaves the libghostty embed as an explicit
follow-up blocker. P07 owns stable session identity, metadata persistence, reattach,
and cross-process backpressure; the terminal transcript remains an in-memory view.

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

P08 extends that same seam with `git.refresh`, `git.showDiff`, `git.stage`,
`git.unstage`, `git.commit`, and `git.switchBranch`. `ProjectGitService` is a
Project-scoped domain boundary that invokes `/usr/bin/git` through `Foundation.Process`
without a shell. This is a deliberate reversible bridge: the current Rust C ABI is
still only the scalar bootstrap smoke path, so Git status and diff are not exposed
through a new unversioned FFI interface. A Git operation is allowed only when the
canonical Project root is exactly `git rev-parse --show-toplevel`; opening a nested
folder inside a repository therefore reports the repository-outside-Project error
instead of mutating a broader checkout.

The status snapshot uses Git porcelain v2 records and keeps branch, upstream,
ahead/behind, and typed staged/unstaged/untracked changes on the active
`ProjectSurfaceModel`. Relative paths are validated against the Project root and `.git`
metadata is never treated as a user file. Stage, unstage, and commit are explicit
commands; commit delegates to Git's staged index and never includes unstaged bytes.
Branch switching validates the ref and requires a clean working tree, including no
untracked files. The current P08 boundary intentionally excludes discard, blame,
review comments, AI briefs, and merge/conflict adoption. P10 adds an optional
managed-worktree execution context without changing the Project root or Git
ownership boundary.

## Workspace shell and file tree

Each open Project has a `ProjectSurfaceModel` keyed by its stable `ProjectID`. The
surface owns the file tree, expanded directory IDs, selected node, and a mixed pane/tab
layout. Switching Projects changes the observed surface, so tree selection, expansion,
and tabs cannot leak between Projects. Durable layout restoration is described below.

`ProjectFileTreeScanner` recursively enumerates the active root and sorts directories
before files using a stable localized name/path order. Node identity is the
standardized absolute path. Directory symlinks are shown as leaf nodes and are not
followed, and `.git` contents are omitted from the user-facing tree. A child directory
that cannot be read is omitted while an unreadable root is represented by the existing
Project availability state.

`ProjectFileSystemWatcher` uses macOS file-system sources for the root, every currently
discovered child directory, and every regular file in the active Project. It rebuilds
the watch set after a change so newly created directories and files are covered. If the
root is missing, its nearest existing parent is watched; root recreation therefore
returns the surface to the available state without a manual reopen. Events are lightly
debounced and trigger a full tree and active-search rescan on the MainActor. Git Projects
additionally watch the repository metadata paths needed for status refresh (`.git`,
`HEAD`, `index`, packed refs, refs, and `logs/HEAD`) while continuing to omit `.git`
contents from the user-facing tree. Git status is refreshed on the MainActor alongside
the tree and active search. The native editor behavior is described below.

## Mixed pane/tab model and workspace persistence

The Project surface stores a recursive `ProjectPaneNode` tree. A leaf is a pane with
an ordered tab list; each tab is an editor, terminal, or diff descriptor. Split nodes
carry horizontal/vertical orientation and a bounded ratio, so nested layouts are
represented without coupling the model to SwiftUI views. The surface supports focus,
split, tab move, close, maximize, and equalize operations. Runtime editor documents and
live PTY sessions remain separate maps keyed by their tab descriptors.

Workspace state is stored independently from the Project catalog in the channel-specific
`workspace-v1.json` file beside `projects-v1.json`. The version-1
`ProjectWorkspaceStoreSnapshot` contains one validated `ProjectSurfaceSnapshot`
per stable Project ID. Each surface snapshot contains the pane tree, active/focused
selection, maximized pane, selected file-tree node, expanded node IDs, and tab
descriptors. It never contains editor document bodies, PTY processes, live terminal
sessions, or the in-memory terminal transcript. Writes create the profile directory and
use atomic replacement, so a completed layout mutation is recoverable after a normal or
abnormal process restart.

On restore, the surface rebuilds runtime objects from the descriptors. Editor tabs whose
paths are outside the Project root, missing, or directories are filtered out; terminal
descriptors carry their stable `SessionID` and attempt broker reattach from cursor zero,
while diff descriptors render the selected Git diff when a P08 Git change is active. A
missing or expired session is shown as unavailable and offers **Start New Session** without
changing the workspace descriptor. A missing workspace file starts with one empty
pane. A malformed or unsupported top-level snapshot leaves the Project catalog intact
and starts the affected surface from the same default; malformed individual surface
entries are discarded while valid Project surfaces remain available.

## Raw agent workflow and attention

P09 keeps agent execution inside the existing local PTY path. The fixed launch profiles
are Claude Code (`claude`), Codex (`codex`), and OpenCode (`opencode`). Launching a
profile creates a new terminal tab on the selected Project surface, records the stable
profile ID in the workspace descriptor, and sends a shell-quoted command that changes
to the Project root before `exec`-ing the profile. Each launch uses the terminal's
stable `SessionID`, so multiple agents can share one Project without sharing a tab or
mixing activity scopes. P09 itself remains a Project-root PTY slice; the optional
managed-worktree extension is described below.

`TerminalSession` publishes lifecycle, output, exit, and failure events to the agent
coordinator. The transcript sanitizer exposes only ground-state BEL bytes as attention
effects; the BEL or ST terminator of an OSC sequence is discarded and cannot create a
false attention event. The coordinator records bounded Project/session-scoped Activity
entries for terminal bells and exits, persists them in the channel-local
`agent-activity-v1.json`, and applies optional Project or session mute state before
calling the macOS UserNotifications adapter. Agent history contains normalized,
bounded summaries only; raw hook payloads are not retained in Activity history and the transient inbox is drained and truncated.

An optional `scripts/agent-hook.sh` resource is exposed to a launched agent through
`CLAIR_AGENT_HOOK_RECEIVER` and `CLAIR_AGENT_HOOK_FILE`. It accepts the agent's
documented JSON hook payload on stdin and appends one compact JSONL record to a
0700 per-channel inbox. The coordinator bounds, decodes, and drains known event kinds
(`session start`, `stop`, `permission/attention`, `notification`, and `failure`) while
ignoring malformed, unknown, oversized, and secret-looking summaries. The Agents panel
can reveal a running or completed session's terminal and configure Project/session
mute state. Project surfaces remain cached while switching Projects, so a launched
agent continues in the background of the selected app process.

P09 deliberately does not persist PTY transcript bytes, rewrite vendor configuration,
or claim that a CLI is installed. If a profile executable is unavailable, its terminal
shows the normal shell failure and records the resulting exit status. App-window and
PTY continuity across app restart remain the P07 broker boundary; a broker restart
still requires the existing terminal recovery path.

## Managed worktrees and optional agent roots

P10 keeps the Project as Clair's owning context and makes a Git worktree an optional
execution root selected only when launching an agent. `ProjectWorktreeCoordinator`
uses `/usr/bin/git` through a Project-scoped service. The catalog is stored at
`worktrees-v1.json` in the channel-specific Application Support directory, while
each Project's managed worktrees live under the repository-external directory
`worktrees/<ProjectID>/`. The catalog is versioned, written atomically, and kept
owner-only (`0600`); its parent and newly created managed directories are
owner-only (`0700`). The managed root is rejected when it is the repository itself
or any path below the repository.

Each catalog record has a stable UUID `WorktreeID`, Project ID, canonical repository
root, managed target path, branch, base revision, and creation time. Listing and
inspection revalidate the record against Git and report `available`, `missing`, or
`detached`. A missing Git registration, a detached HEAD, a non-repository target,
or a catalog target outside the Project's managed root is never treated as a usable
execution root. Catalog paths are not trusted as cleanup targets without the same
managed-root boundary check.

Terminal descriptors carry an optional execution-root path and `WorktreeID` without
changing the version-1 workspace schema. Agent sessions carry the same identity and
export `CLAIR_WORKTREE_ID`; a Project-root launch leaves that field absent. Restored
terminal descriptors retain their managed root so the existing broker reattach path
can use the same working directory. The workspace surface also reports terminal
descriptors that are active or awaiting reattach to the cleanup guard, while the
agent coordinator contributes its in-memory active sessions.

Cleanup is a two-step operation. Clair first creates a fresh confirmation plan and
refuses it when the worktree is dirty, missing, detached, or used by a terminal or
agent. Confirmation rechecks the canonical target, state, branch, and HEAD
fingerprint before invoking `git worktree remove` without `--force`; the branch is
kept. A stale plan, changed target, changed branch, or changed HEAD must be prepared
again. P10 does not review, merge, adopt, or resolve worktree branches; those actions
belong to P11. PTY transcript persistence, semantic vendor adapters, and CLI/MCP
command surfaces remain outside this slice.

## Native editor and disk safety

`ProjectEditorTab` is an AppKit/TextKit-backed, UTF-8 editor document embedded through
`NSViewRepresentable`. It supports multiple independent file tabs, normal
`NSTextView` undo/redo, explicit Save (including Command-S), Japanese IME marked text,
emoji, and combining characters. Non-UTF-8 files are rejected instead of being opened
with replacement characters.

The editor treats disk bytes as the baseline. Each open file has a file-system watcher
in addition to the directory watcher. If an agent or another process rewrites a file,
the disk version wins and the current in-memory buffer is recorded before reload. A
deletion marks the tab missing while retaining it for recovery. Before an explicit save,
the editor compares the current disk bytes with the baseline; if they differ, it
reloads disk content and refuses to overwrite it. Closing a dirty or missing tab
requires an explicit discard confirmation.

Recovery snapshots are stored outside the repository in the channel-specific
Application Support file `editor-history-v1.json` (schema version 1), with at most
100 entries per Project/file. Stable and Dev use separate paths through ADR-0008.
P05 provides durable pane/tab layout restoration; P06 owns a searchable file-history
browser, while P04 provides the recovery snapshots needed by those later surfaces.

## Project navigation, search, replacement, and history

`ProjectNavigation` is the project-scoped read/navigation service used by the active
surface. Quick Open flattens the current file tree and ranks exact filename, filename
prefix, path, and fuzzy matches deterministically. Search and replacement enumerate
regular UTF-8 files under the Project root, skip `.git`, package descendants, symlinks,
binary files, and unreadable files, and report 1-based line and grapheme-column
locations. Search results validate the relative path against the Project root before
opening a file; the editor converts the grapheme location to the UTF-16 range expected
by `NSTextView` and scrolls that match into view.

Replacement first produces a preview containing match counts, original bytes, and
replacement bytes. Applying the preview updates the affected editor buffers through the
existing undo/disk-safety boundary and deliberately does not write files; each tab must
be saved explicitly. The directory/file watcher recomputes an active search query after
external changes, so stale results are removed without reopening the Project.

The Project History browser aggregates the channel-separated local recovery store for
the current `ProjectID`, orders entries newest first, and restores a selected snapshot
into an editor buffer. Restore marks the buffer dirty and leaves disk bytes unchanged
until an explicit Save, preserving the P04 disk-wins and conflict-refusal contract.

## Developer command boundary

The root `Makefile` is the supported local and CI interface. Rust 1.98.0 is
pinned by `rust-toolchain.toml`. Shell scripts own
orchestration details, keep DerivedData under `.build/xcode/<purpose>`, and preserve
underlying tool exit codes. GitHub Actions runs `make ci` rather than maintaining a
separate command graph. `make smoke-ffi` also compiles a small Swift CLI against the
Rust static library, so the language boundary can be verified before a full Xcode
application build. `make smoke-app-link` links the complete shared SwiftUI source
graph, including the terminal surface, for both channel compile conditions and
verifies the Rust symbol in each Mach-O executable. The Rust build also emits
`target/debug/clair-ptyhost` for local app discovery. Bundle smoke follows Xcode
26's Debug `*.debug.dylib` image when the app's main executable is a generated
debug stub.

Build output under `.build/`, Cargo `target/`, generated output, and Xcode user state
are disposable and ignored. `THIRD_PARTY_NOTICES.md` is the tracked notice source.

## Project kernel validation

`apple/ClairTests/ProjectKernelTests.swift` covers three folder types in one process,
canonical-root duplicate rejection, invalid/file/unreadable-root isolation, stable ID
reopen, metadata/order persistence, store versioning, command risk/availability
preflight, nested tree enumeration, fixture tab selection, external create/rename/
delete refresh, missing-root recovery, Project surface isolation, nested mixed-pane
operations, three-Project layout isolation across restart, and corrupt/missing workspace
fallback, Quick Open and search result navigation, buffer-only replacement, active-search
refresh after an external file change, and Project History restore. The project-scoped
Dev XCTest target runs these tests. `ProjectGitTests` covers porcelain status separation,
staged-boundary diff/stage/unstage/commit behavior, untracked/rename/delete parsing,
typed invalid-operation errors, Project-scoped command execution, external index refresh,
and non-Git availability. The `make test-swift`
wrapper remains the CI-facing path where the workspace is accepted; with the current
Xcode 26 environment, use the equivalent `xcodebuild -project Clair.xcodeproj ... test`
command because the minimal committed workspace is rejected.

`apple/ClairTests/TerminalTests.swift` covers partial/batched broker frame decoding,
large complete batches, binary UTF-8 input, attachment/output/error/gap validation,
stable terminal SessionID persistence, split escape-sequence sanitization, and
transcript UTF-8 trimming, and ground BEL versus OSC-terminator activity effects.
`apple/ClairTests/AgentWorkflowTests.swift` and `AgentActivityTests.swift` cover fixed
profile identity, shell quoting, lifecycle persistence, bounded activity history,
mute precedence, hook decoding/redaction, and notification dispatch. Rust unit and
integration tests cover PTY shell commands,
resize, CJK/OSC bytes, output flood, broker reattach after client disconnect, missing
sessions, bounded malformed frames, slow-consumer gaps, and child reaping.

`apple/ClairTests/NativeEditorTests.swift` covers explicit save and undo/redo, Unicode
and combining text, marked-text IME commits, external rewrite disk-wins reload with
recovery, per-file watcher refresh, multi-tab isolation, search-result UTF-16 selection,
and non-UTF-8 rejection. `apple/ClairTests/ProjectNavigationTests.swift` covers
deterministic Quick Open ranking, Unicode search locations, replacement previews without
disk writes, project-scoped history ordering, and Project-root path validation.

## Current limitations

- Builds are unsigned and App Sandbox is disabled.
- `clair-ptyhost` provides a local detached broker and metadata catalog, but the
  journal and transcript are memory-only. If the broker itself exits, its live PTYs
  are not recoverable; the app reports a missing session and offers a new session.
- The C ABI is a link/lifecycle smoke path, not the future domain interface.
- The terminal surface is a selectable plain-text AppKit fallback, not a full ANSI/
  alternate-screen/cursor/colour terminal grid; a reproducible libghostty development
  artifact is still unavailable in this checkout. The editor does not yet provide
  syntax highlighting, LSP, or multi-cursor editing. The P08/P10 Git loop currently
  uses the local `/usr/bin/git` bridge; discard, blame, review comments, AI briefs,
  merge/conflict adoption, and CLI/MCP adapters remain later queue items.
- Formal app icons, signing, notarization, and update delivery are not present.

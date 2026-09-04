# Development workspace

## Status

Current as of local PoC item `P14 Release, update, and restart handoff`.

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
├── clair-cli (bundled native command client)
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

M1 control-plane ownership is Swift-native. Rust domain migration is selective and
evidence-driven per [ADR-0010](../decisions/0010-m1-control-plane-swift-with-selective-rust-migration.md);
the `clair-core` C ABI remains a link/lifecycle smoke path, not a domain interface.

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
explicit recovery marker. This is the current local single-user lifecycle slice.
The early mobile layer is being added separately in P16; the current broker is
not a public or Cloudflare-facing endpoint. `ClairMobileKit` now provides the
transport-neutral host core plus a localhost-only framed listener and a shared
Network.framework client. Private-network products may proxy to that one
listener, while pairing, device grants, session gaps, and raw input remain
owned by the host core. The macOS application runtime bridge and iOS UI are
still later P16 slices.

`TerminalSurfaceView` is an AppKit-backed native terminal grid renderer, embedded in
the SwiftUI Project shell. Each `TerminalSession` owns a `TerminalGrid` that wraps a
reproducibly-built libvterm state and exposes per-cell codepoint, width, attribute
bits, RGB foreground/background, and cursor/scrollback accessors. The grid is fed
from the same `output` events the P07 broker already publishes; `screenReset` events
reseed the grid with an explicit recovery marker instead of leaving stale cells on
screen. The renderer draws scrollback plus the live grid with monospace cells,
honours reverse-video/underline/strikethrough, supports mouse-driven grid selection,
copy, control/navigation/IME input, and reattaches through the existing same-user
broker without keeping a separate plain-text transcript. libvterm 0.3.3 is fetched,
hash-verified, and statically linked via `scripts/build-vterm.sh`, which the Xcode
target runs as a build phase. P15A ships this surface; libghostty remains a
documented but unverified alternative that is no longer required to meet the
production renderer bar.

## Stable release, update, and lifecycle handoff

The Stable target is the only public distribution channel. The `Stable release`
workflow builds an unsigned `Clair.app` in Release configuration, embeds the release
`clair` native CLI and the `clair-ptyhost` resource,
packages an arm64 zip, and publishes the zip plus a signed `latest.json` to a GitHub
Release. A release artifact is authenticated separately from
Apple code signing: the manifest contains an Ed25519 signature over its channel,
version, platform, architecture, URL, and SHA-256. The public key is injected into the
Stable Info.plist at release build time; the private key exists only in the Actions
secret boundary. The manifest generator and app verifier share the version-1 canonical
payload contract. See [ADR-0009](../decisions/0009-stable-github-update-distribution.md)
and the [Stable release runbook](../runbooks/stable-release.md).

Stable checks the public feed five seconds after launch and hourly thereafter, but a
check only changes the UI state. The user must select **Restart and install** before
download, hash/signature verification, staging, or replacement begins. Dev has no feed,
public key, or update checks and remains local-only. Stable updates are accepted only
when the running bundle is `/Applications/Clair.app`; local Debug and Dev bundles are
never replaced.

The update installer downloads into channel-local Application Support, validates the
archive bundle identity/version, records a pending version, and starts a detached
helper. The helper waits for the current process, moves the installed app to a backup,
places the staged app, and waits for the new process to write a matching startup
success marker. Any timeout or mismatch restores the backup and relaunches it. Update
restart is a distinct termination reason: it leaves the detached broker and PTY
sessions alive, while the new process reattaches terminal descriptors by stable
`SessionID`. Closing a window has the same continuity behavior. Only an explicit app
Quit invokes normal session termination.

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
switch, rename, color, reorder, and close.

P12 projects that registry through `CommandSurfaceModel`. `CommandWindowView` searches
command titles and stable IDs, shows the fixed risk and current availability reason,
and renders the same typed result or error after dispatch. `ClairCommandMenu` is the
menu projection; available rows call the same `ProjectWorkspaceModel.execute` path and
unavailable rows remain disabled with their deterministic reason. The command window
uses Command-Shift-K, while configurable command shortcuts are persisted as the
versioned `clair.command-keymap.v1` payload in the channel-specific standard
`UserDefaults` store. Assignment validates normalized keys, reserved editor shortcuts,
and one-to-one conflicts before replacing the saved mapping. P13 adds local CLI/MCP
adapters without moving state ownership out of the GUI process.

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

`ProjectFileTreeScanner` loads the root and expanded directories lazily, rather than
recursively scanning a Project at open. Each directory initially exposes at most 256
children; **Load more** raises that directory's displayed limit in the same increments
up to 4,096. Nodes are sorted directories-first with a stable localized name/path order,
and node identity is the standardized absolute path. Directory symlinks are shown as
leaf nodes and never followed. `.git` plus generated/dependency directories including
`.build`, `DerivedData`, `node_modules`, `Pods`, `target`, and `vendor` are excluded from
the user-facing tree, Quick Open, search, and replacement traversals. A child directory
that cannot be read is omitted while an unreadable root is represented by the existing
Project availability state.

Tree reload, Quick Open, search, and replacement enumeration run outside the MainActor;
new queries, refreshes, closing, and reopening cancel obsolete work before its result can
replace newer Project state. Quick Open/search traversal is bounded to 50,000 eligible
files, with 200 Quick Open results and 20,000 text matches retained at most. The watcher
graph contains the root and loaded directories only (at most 256 directories and 512
regular files), then rebuilds after an event. If the root is missing, its nearest existing
parent is watched; root recreation therefore returns the surface to the available tree
without a manual reopen. Events are lightly debounced and schedule a fresh tree and
active-search refresh without occupying the UI actor. Git Projects additionally watch a
fixed set of repository metadata paths needed for status refresh (`.git`, `HEAD`, `index`,
packed refs, refs, and `logs/HEAD`) while continuing to omit `.git` contents from the
user-facing tree. Git status is refreshed on the MainActor alongside application of the
completed tree/search results. The native editor behavior is described below.

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

The agent control plane registers both newly launched and restored agent tabs by stable
session ID. It exposes the Project/worktree/profile, factual lifecycle, latest attention
activity, and state-dependent capabilities to the command adapters. Input and interrupt
are sent only after the owning PTY is actually running; stop is a separate destructive
operation. This keeps Clair as the agent authority without inferring semantic status from
TUI screen text.

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
belong to P11. PTY transcript persistence and semantic vendor adapters remain outside
this slice.

## Branch review and adoption

P11 adds `ProjectBranchReviewService` on top of the managed-worktree identity and
cleanup boundaries. A review resolves the recorded `baseRevision`, the source
worktree's current `HEAD`, and the target Project `HEAD`. It lists the commits in
`base..HEAD` and computes a branch-wide `base...HEAD` name-status list and patch.
The committed change list and patch are kept separate from the source's current
porcelain status, so an uncommitted modification, staged change, or untracked file
cannot be mistaken for reviewed branch work.

Adoption is a one-shot confirmation flow. The plan records the Project/worktree
identity, canonical source and repository paths, expected source branch, base and
source HEAD revisions, target branch and target HEAD, and both status snapshots.
Preparation and confirmation refuse a source or target that is dirty, detached, has
changed identity or HEAD, has no commits after its base, belongs to another
repository, or already has a merge in progress. Confirmation refreshes the review
before invoking `git merge --no-ff --no-edit` in the Project root; a successful result
is accepted only when the new `HEAD` has exactly two parents. A stale plan is consumed
and must be prepared again rather than being replayed.

When Git reports a three-way conflict, adoption returns the typed conflict paths and
leaves the target merge state intact. The Branch Review surface shows the target,
conflicted paths, and the owning-agent/native-editor resolution handoff. P10 cleanup
remains an independent two-step operation: cancelling cleanup leaves the worktree
and its branch in place, and normal worktree cleanup never deletes the branch.

## CLI and MCP adapters

P13 exposes the complete P00-P12 user-invokable operation inventory through the same
`CommandRegistry`. The stable command IDs are grouped as follows:

| Surface | Registered IDs |
|---|---|
| Project | `project.open`, `project.switch`, `project.rename`, `project.setColor`, `project.reorder`, `project.close` |
| Navigation/editor | `navigation.openFile`, `navigation.quickOpen`, `navigation.search`, `editor.save`, `editor.undo`, `editor.redo` |
| Pane | `pane.split`, `pane.focus`, `pane.moveTab`, `pane.close`, `pane.toggleMaximize`, `pane.equalize` |
| Terminal/agent | `terminal.open`, `terminal.stop`, `terminal.recover`, `agent.list`, `agent.status`, `agent.launch`, `agent.reveal`, `agent.input`, `agent.interrupt`, `agent.stop` |
| Worktree | `worktree.list`, `worktree.create`, `worktree.prepareCleanup` |
| Git/review | `git.refresh`, `git.showDiff`, `git.stage`, `git.unstage`, `git.commit`, `git.switchBranch`, `git.review`, `git.prepareAdoption`, `git.adopt` |
| Notification | `notification.list`, `notification.setMute` |

Each descriptor carries the stable ID, typed input schema, fixed risk, and
`aiAvailable` flag. GUI surfaces continue to dispatch the typed `ClairCommand` through
the workspace; the adapters use the same registry for decoding, preflight, approval,
execution, and structured result/error encoding. Read commands do not prompt, while
additive, write, destructive, and external commands require an in-app GUI approval.
`navigation.openFile` is additive because an unmatched path can create a new Project;
opening a file inside an existing Project therefore uses the same conservative gate.
The approval dialog never changes the registry's risk or bypasses runtime preflight.

The local adapter transport is a version-1, newline-delimited JSON protocol over the
channel-specific owner-only Unix socket:

| Channel | Socket |
|---|---|
| Stable | `~/Library/Application Support/Clair/command-v1.sock` |
| Dev | `~/Library/Application Support/Clair Dev/command-v1.sock` |

The containing directory is `0700`, the socket is `0600`, and requests/responses are
capped at 1 MiB. A request has `requestID`, `operation` (`list` or `call`), optional
`commandID`/`params`, and `source` (`cli`, `mcp`, or `mobile`). A failed response preserves the
request ID and returns a machine-readable `code`, message, command ID, risk, and
reason. The socket is same-user local IPC only; no transcript or remote session data
is persisted.

The native `clair` executable is built from `crates/clair-cli` and is a thin client for
the same owner-only command socket; command semantics and agent state remain owned by
the Swift `CommandRegistry`/agent control plane. Release bundles expose it at
`Clair.app/Contents/Resources/clair`, while a source Debug build emits `target/debug/clair`.
`agent list/status/launch/reveal/input/interrupt/stop` provides the same agent operations
in JSON, and mutating commands accept an explicit `--yes` for headless test execution.
`open path:line:column` canonicalizes the
path, routes it to the longest matching open Project root, and opens the containing
directory as a Project when there is no match. A warm call probes the existing socket;
when it is absent, the CLI cold-launches the channel's built app and retries until the
server is ready. `--no-launch` makes a missing server a deterministic error. The
stdio MCP mode (`mcp serve`) maps `initialize`, `tools/list`, and `tools/call` onto
the same socket. MCP lists and calls only descriptors with `aiAvailable == true`, and
command failures are returned as MCP tool results with `isError: true`. The checked-in
`scripts/clair` adapter remains available for source-tree compatibility and speaks the
same protocol.

The adapter intentionally stops at the local GUI boundary. The mobile protocol package
defines the corresponding `agent/*` operations and authorization contracts, and its host
core exposes accepted operations through an application-owned handler boundary. P16's
localhost listener is the only intended mobile endpoint; it does not expose the owner-only
command socket or `clair-ptyhost` directly. The macOS runtime wiring, vendor-specific
agent semantics, public relay/E2EE, and benchmark/performance comparisons remain later
queue items.

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
`target/debug/clair` and `target/debug/clair-ptyhost` for local app discovery; the
Xcode command-line wrapper copies the native CLI into each Debug app bundle, and the
release workflow copies the optimized CLI into the Release bundle. The Xcode command-line
wrapper builds the project directly; the checked-in workspace remains available
for opening the project in Xcode. Bundle smoke follows Xcode
26's Debug `*.debug.dylib` image when the app's main executable is a generated
debug stub.

Build output under `.build/`, Cargo `target/`, generated output, and Xcode user state
are disposable and ignored. `THIRD_PARTY_NOTICES.md` is the tracked notice source.

## Project kernel validation

`apple/ClairTests/ProjectKernelTests.swift` covers three folder types in one process,
canonical-root duplicate rejection, invalid/file/unreadable-root isolation, stable ID
reopen, metadata/order persistence, store versioning, command risk/availability
preflight, human command-surface dispatch, unavailable-reason propagation, and shortcut
validation/persistence, nested tree enumeration, fixture tab selection, external
create/rename/delete refresh, missing-root recovery, Project surface isolation, nested
mixed-pane operations, three-Project layout isolation across restart, and corrupt/missing
workspace fallback, Quick Open and search result navigation, buffer-only replacement,
active-search refresh after an external file change, and Project History restore. The
project-scoped Dev XCTest target runs these tests. `ProjectGitTests` covers porcelain
status separation,
staged-boundary diff/stage/unstage/commit behavior, untracked/rename/delete parsing,
typed invalid-operation errors, Project-scoped command execution, external index refresh,
and non-Git availability. Branch review tests cover committed/uncommitted separation,
dirty adoption refusal, clean two-parent adoption, conflict-state handoff, stale-plan
refusal, and cleanup cancellation. The `make test-swift` wrapper uses the same
project-scoped build path as the focused `xcodebuild -project Clair.xcodeproj ... test`
commands below.

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
- The terminal surface renders through libvterm on the same broker; reattach, frame
  bounds, and slow-consumer backpressure continue to be correctness-tested, while
  formal terminal benchmarks remain L01. The editor does not yet provide syntax
  highlighting, LSP, or multi-cursor editing. The P08/P10/P11/P12/P13 Git and
  command loop currently uses the local `/usr/bin/git` bridge; discard, blame, review
  comments, and AI briefs remain later queue items.
- Formal app icons, Apple Developer ID signing, and notarization are not present.
  Stable update delivery is available through the unsigned GitHub Release workflow;
  Gatekeeper-friendly public distribution and additional architectures remain deferred.

# Local development

## Purpose

Build, test, lint, and launch the issue #3 native Swift/Rust workspace from a
clean checkout.

## Prerequisites

- macOS 14.0 or later
- Full Xcode 16 or later selected with `xcode-select`
- Rust installed through rustup
- The repository-pinned Rust 1.98.0 toolchain with `rustfmt` and `clippy`

Check all prerequisites without changing the machine:

```sh
make doctor
```

If Xcode is installed but Command Line Tools is selected, select the full app:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Install the Rust components after installing rustup:

```sh
rustup component add rustfmt clippy
```

## Standard commands

```sh
make build-stable
make build-dev
make test
make lint
make smoke-ffi
make smoke-app-link
make smoke
```

`make ci` runs the complete lint and smoke graph used by GitHub Actions.

## Verify the Project kernel

After building Dev, use `make run-dev` and select **Open Folder** in the Projects
sidebar. Open one Git repository, one ordinary non-Git folder, and one temporary
folder. Confirm that all three appear in the same process and that selecting a row
changes the active Project and displayed root.

Use a Project row's context menu to rename it, set a color, move it, and close it.
Rename is display metadata only; it does not rename the folder on disk. Reopen the
closed folder (or relaunch Dev) and confirm that its Project ID and metadata return.

Try opening the same root through a `.`/`..` path or symlink and confirm that Clair
reports a duplicate instead of adding a second row. Try a missing path, a regular
file, and a folder without read access. Each command should report its local error
while the already-open Projects and active selection remain intact.

## Verify the workspace shell and file tree

With an active Project, confirm that the Files panel shows nested directories and
files. Expand a directory and select a file; Clair should open a native editor tab
showing the file path and content. Use **Reveal in Tree** from the tab to return the
selection to the file tree. Open a second Project and confirm that its tree and tabs
contain only its own files; switch back and confirm the first Project's selection and
tabs return.

While Clair is running, create, rename, and delete a file from another terminal. The
file tree should refresh without reopening the Project. Delete the active Project
root and recreate it; the Files panel should show **Folder Missing** and then return
to the available tree when the root is restored. P05 persists this file-tree state
alongside the Project's pane layout.

The catalog is stored per channel at
`~/Library/Application Support/Clair Dev/projects-v1.json` (or `Clair` for Stable).
Mixed pane snapshots are stored separately at
`~/Library/Application Support/Clair Dev/workspace-v1.json` (or `Clair` for
Stable). Do not remove either file as part of normal recovery; the first contains the
local Project catalog and the second contains the restored workspace layout. Build
artifacts can still be removed with `make clean-artifacts`.

## Verify mixed panes and workspace persistence (P05)

Build and launch the Dev app with the project-scoped command used by the current Xcode
environment:

```sh
xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" -configuration Debug \
  -derivedDataPath .build/xcode/p05-manual CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO build
open -n ".build/xcode/p05-manual/Build/Products/Debug/Clair Dev.app"
```

Open an editor file in a Project. From the pane toolbar, add a **Terminal** and a
**Diff** tab, then use **Split Right** and **Split Below** to make a nested layout.
Move the active tab to another pane, focus each pane, maximize and restore it, equalize
the split ratios, and close a non-final pane. Switch to two other Projects and confirm
their layouts, file selections, and editor tabs remain independent.

Quit normally, relaunch, and confirm that the tree selection, pane structure, active
tabs, focus, and maximize state return for each Project. A terminal tab keeps its
stable local SessionID and attempts to reattach to the broker-owned PTY; if that
session is unavailable, the tab shows **Start New Session**. The terminal transcript
is intentionally not part of the workspace snapshot. The diff tab is populated when a
Git change is selected from the P08 Git panel.

For an abnormal-restart smoke check, use only disposable fixture Projects: force-quit
the app after a completed layout action, relaunch, and confirm that the last atomically
saved workspace state or a safe one-pane fallback appears. The automated XCTest suite
covers corrupt and missing workspace files. If testing corruption manually, first copy
`workspace-v1.json` while the app is quit, replace only that copied test profile's
file with invalid JSON, relaunch to verify the catalog remains intact and a default
surface appears, then restore the backup before continuing.

## Verify the native editor (P04)

Build and launch Dev:

```sh
make build-dev
make run-dev
```

In an active Project, open two text files and verify that each tab keeps its own
buffer. Type ordinary text, Japanese through IME, emoji, and combining characters.
Use **Undo**/**Redo**, then press **Save** or Command-S and verify the saved bytes from
another terminal. Closing a dirty tab must ask for explicit discard confirmation.

With a file open, edit it without saving and rewrite it from another terminal. The
editor should reload the disk version, clear the dirty state, and expose the previous
buffer in **History**. Restoring that snapshot should make the buffer dirty again;
save it explicitly if it should replace the current disk version. Delete an open file
and confirm that its tab remains marked **Missing** so the recovery snapshot remains
available. A file containing invalid UTF-8 should be rejected with an editor error
instead of displaying replacement characters.

Recovery data is channel-separated and kept outside the repository at
`~/Library/Application Support/Clair Dev/editor-history-v1.json` (or `Clair` for
Stable). P05 persists pane/tab descriptors and workspace state separately. P07 keeps
the live PTY in the detached local broker and persists only session metadata at
`~/Library/Application Support/Clair Dev/sessions-v1.catalog` (or `Clair` for Stable);
terminal bytes remain in memory and are not written to disk. If the broker itself is
also terminated, the app reports the session as missing and allows a new one.
Build outputs are:

- `.build/xcode/stable/Build/Products/Debug/Clair.app`
- `.build/xcode/dev/Build/Products/Debug/Clair Dev.app`
- `target/debug/libclair_core.a`
- `target/debug/clair-ptyhost`

## Verify Quick Open, search, replacement, and Project History (P06)

Build and launch Dev:

```sh
make build-dev
make run-dev
```

Open a Project containing nested text files. Use **Quick Open** in the Project header,
type a filename or path fragment, and open a result; Clair should select the file and
open its existing editor tab or create one. Use **Search**, enter text, and confirm that
results show the relative path, 1-based line/column, and matching line. `.git` contents,
binary files, symlinks, and unreadable files should not appear in the results. Select a
result and confirm that the editor scrolls to and selects the match.

Enter replacement text and choose **Preview Replacement**. Confirm the preview lists
each affected file and match count. Choose **Apply to Editor Buffers**, then verify from
another terminal that the files on disk are unchanged and that the affected editor tabs
are dirty. Save the tabs explicitly and verify the new bytes from the terminal.

Leave a search open, rewrite a searched file from another terminal, and confirm that
the active results refresh without reopening the Project. Search for the old text to
confirm it disappears, then search for the new text to confirm it appears.

Save an edited file to create a recovery snapshot, then open **History** from the
Project header. The browser must show only entries for the active Project, newest first.
Choose **Restore** and confirm the previous content returns to the editor as a dirty
buffer while the on-disk file remains unchanged; use **Save** only when the restored
content should replace the disk version. The existing per-file History menu remains
available in each editor tab for the same recovery store.

## Run Stable and Dev together

```sh
make run-stable
make run-dev
```

Both commands use `open -n`, so macOS starts a new process even when the other
channel is running. Confirm that:

1. Dock and window names show `Clair` and `Clair Dev`.
2. The bootstrap windows show bundle IDs `com.diwamoto.clair` and
   `com.diwamoto.clair.dev`.
3. Data paths end in `Application Support/Clair` and
   `Application Support/Clair Dev`.
4. Both windows report `Swift → Rust smoke path is ready`.

Quit both apps normally after the check. The build scripts never remove their
preferences or Application Support directories.

## Verify the live terminal (P03)

Build and launch Dev:

```sh
make build-dev
make run-dev
```

Open a Project, choose **Open Terminal**, and verify the same live session can:

1. Run a shell command such as `printf 'CLAIR_SHELL_OK\n'` and show its output.
2. Run `stty size`, resize the window, and run it again; the reported rows/columns
   should follow the surface.
3. Type and execute CJK text, select output with the mouse, copy it, and scroll
   through earlier output without losing the active shell.
4. Run `printf '\033]0;title\007'` and confirm control bytes do not corrupt the
   plain transcript.
5. Generate a bounded flood, for example `for i in $(seq 1 100); do echo line-$i; done`,
   and confirm the app remains responsive and the shell can still accept input.

Click **End** before closing the Project. P03's verified implementation is an AppKit
selectable plain-text fallback while a reproducible libghostty development artifact
is unavailable. The app now routes the session through the P07 local broker; the
direct `clair-ptyhost --spawn` command remains the low-level protocol smoke path.

## Verify local session reattach (P07)

Build and launch Dev with the project-scoped command used by the current Xcode
environment:

```sh
xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" -configuration Debug \
  -derivedDataPath .build/xcode/p07-manual CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO build
open -n ".build/xcode/p07-manual/Build/Products/Debug/Clair Dev.app"
```

In a disposable fixture Project, open a terminal and run a command that prints a
marker, waits for input, and prints a second marker. Force-quit only the Dev app
while the shell is waiting, relaunch it, and confirm that the same terminal tab
reattaches, accepts the waiting input, and shows the second marker without replaying
the first marker twice. A normal terminal exit should show its exit status.

The broker uses these channel-local paths:

- `~/Library/Application Support/Clair Dev/session-broker-v1.sock`
- `~/Library/Application Support/Clair Dev/sessions-v1.catalog`

The socket and catalog should be owner-only (`0600`). The catalog contains session
metadata and epoch only; it does not contain terminal transcript bytes. Output replay
is bounded to a 256 KiB journal and 256 KiB per-client queue. If a cursor falls
behind, the terminal shows an explicit output-gap marker and continues from the
retained stream.

The automated P07 checks are:

```sh
cargo test -p clair-ptyhost --locked
cargo clippy --workspace --all-targets --locked
swift format lint --recursive --parallel --strict apple
ruby scripts/validate-xcode-project.rb
```

The Rust broker integration test covers a bounded malformed frame, typed missing
session recovery, and a client disconnect/reconnect while the PTY remains alive. A
broker restart is intentionally outside this slice: it is a missing-session recovery
case, not transcript restoration.

## Verify the Git working-tree loop (P08)

Use a disposable fixture repository for commit and branch-switch checks. Build and
launch Dev with the project-scoped command used by the current Xcode environment:

```sh
xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" -configuration Debug \
  -derivedDataPath .build/xcode/p08-manual CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO build
open -n ".build/xcode/p08-manual/Build/Products/Debug/Clair Dev.app"
```

Open the fixture repository itself as a Project and choose **Git** in the Project
header. Confirm that the panel separates staged, unstaged, and untracked changes and
shows the current branch plus ahead/behind information when available. Edit a tracked
file and create an untracked file from another terminal. Select **Diff** for each
change, use **Open in Editor**, stage one path, and verify that the staged and working-
tree diffs remain separate. Unstage it again, then stage only the intended file and
commit; confirm that the commit contains only the staged bytes and that the panel
refreshes to a clean state.

Run `git add` or edit a file from another terminal while the panel is open. The `.git`
metadata watcher should refresh the status without reopening the Project. A branch
switch with any modified, staged, deleted, renamed, or untracked path must be refused
with a typed clean-working-tree error; after the fixture is clean, switching to an
existing branch should update the branch label. Invalid paths, an empty commit
message, an invalid branch, and a non-Git Project must show a local error or
availability state without changing another Project.

The automated P08 checks are:

```sh
swift format lint --recursive --parallel --strict apple
ruby scripts/validate-xcode-project.rb
scripts/smoke-app-link.sh
xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath .build/xcode/p08-tests CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO -only-testing:ClairTests/ProjectGitTests test
```

The repository's `make test-swift` wrapper remains the CI-facing path where the
minimal committed workspace is accepted; with the current Xcode 26 environment, use
the equivalent project-scoped command above because that workspace is rejected.

## Verify the raw agent workflow and attention (P09)

Build and launch Dev with the project-scoped command used by the current Xcode
environment:

```sh
xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" -configuration Debug \
  -derivedDataPath .build/xcode/p09-manual CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO build
open -n ".build/xcode/p09-manual/Build/Products/Debug/Clair Dev.app"
```

Open a disposable fixture folder as a Project and choose **Agents**. Launch two or
more installed profiles from the Project root, including different profiles when
available. Each click should create a separate terminal tab titled for that profile;
the displayed working directory must be the Project root. Switch to another Project
while those terminals are active, switch back, and use **Reveal** from the Agents
panel to return to the correct terminal. A missing CLI should remain a local terminal
failure rather than affecting another Project.

Run `printf '\a'` in a launched agent terminal and confirm that Activity history shows
one terminal attention event and macOS delivers a notification when notifications are
allowed and the Project/session is unmuted. Run
`printf '\033]0;title\007'` and confirm its OSC terminator does not add another
attention event. Exit one terminal normally and one with a non-zero status; both exits
should appear with their status. Mute the Project, repeat the bell/exit checks, and
confirm history continues to update without notifications. Unmute the Project and
verify a session mute can be toggled independently.

For the optional documented hook path, configure the agent hook command shown in the
panel as `sh "$CLAIR_AGENT_HOOK_RECEIVER"`, then send a small JSON event through that
command, for example:

```sh
printf '%s\n' '{"hook_event_name":"Notification","message":"permission requested"}' \
  | sh "$CLAIR_AGENT_HOOK_RECEIVER"
```

The event should appear in Activity history without exposing unrelated fields from the
payload. The receiver's inbox and the channel-local history file are outside the
Project repository and should be owner-only. The coordinator ignores unknown or
oversized JSONL entries.

The automated P09 checks are:

```sh
swift format lint --recursive --parallel --strict apple
ruby scripts/validate-xcode-project.rb
xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath .build/xcode/p09-tests CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO test
cargo test --workspace --locked
```

The XCTest suite covers profile commands, lifecycle/history persistence, hook
decoding, mute/notification policy, and terminal bell effects. The Rust suite covers
the unchanged local PTY/broker boundary; the broker integration tests require a local
macOS process environment because they create Unix sockets.

## Verify managed worktrees and optional agent roots (P10)

Build and launch Dev with the project-scoped command used by the current Xcode
environment:

```sh
xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" -configuration Debug \
  -derivedDataPath .build/xcode/p10-manual CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO build
open -n ".build/xcode/p10-manual/Build/Products/Debug/Clair Dev.app"
```

Open a Git repository as a Project and choose **Agents**. In **Managed worktrees**,
create a branch and folder name. The displayed managed root must be outside the
repository, and the row should report **Available** with the expected branch. Launch
one profile with **Project root** selected and another with the managed worktree
selected. Confirm that they use separate terminal tabs, that `pwd` in each terminal
matches its selected root, and that the managed launch exports the row's stable
`WorktreeID` as `CLAIR_WORKTREE_ID` while a Project-root launch does not export it.

Close and relaunch Dev, reopen the same Project, and confirm that the managed row has
the same branch and path and can be selected for a new agent launch. Remove the
managed target through Git or move it aside and refresh; Clair should retain the
catalog record as **Missing** or **Detached** rather than retargeting it. A detached
HEAD is not a launchable managed root.

Exercise cleanup from the row. Create an untracked file in the managed root and
confirm that **Clean Up** shows the dirty guard with no destructive confirmation.
Launch an agent from that worktree and confirm that an active terminal/agent guard
also refuses cleanup. After the file is removed and the session exits, choose
**Clean Up** again and confirm the target directory is removed while its Git branch
remains. The automated tests also cover a wrong expected target, changed cleanup
fingerprint, and a catalog record outside the managed root; each must be refused.

The managed-worktree metadata is stored outside the repository at
`~/Library/Application Support/Clair Dev/worktrees-v1.json` (or `Clair` for Stable),
and targets are under the adjacent `worktrees/<ProjectID>/` directory. The catalog
does not contain terminal transcript bytes. Do not delete the catalog as part of a
normal cleanup; inspect the displayed error and repair the Git/catalog state first.

The automated P10 checks are:

```sh
swift format lint --recursive --parallel --strict apple
ruby scripts/validate-xcode-project.rb
xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath .build/xcode/p10-tests CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO -only-testing:ClairTests/ManagedWorktreeTests test
```

With the current Xcode 26 environment, the last command may require execution
outside the restricted shell because XCTest's `testmanagerd` service is unavailable
inside the sandbox. The suite covers external managed roots, stable identity and
restart discovery, missing/detached states, root persistence, dirty/active/wrong-
target cleanup refusal, cleanup fingerprint checks, and catalog path validation.

## Run the PTY host smoke path

```sh
cargo run -p clair-ptyhost -- --smoke
```

Expected output:

```text
clair-ptyhost/0 smoke=ok
```

## Recovery

Build outputs are disposable. To remove only repository-local outputs:

```sh
make clean-artifacts
```

This command validates the repository root, then removes only `.build/` and
`target/`. It does not touch application preferences or `~/Library/Application Support`.

If `make doctor` reports that full Xcode is not selected, fix `xcode-select`
before retrying. If Cargo cannot install the pinned stable toolchain, restore
network access or install it explicitly with rustup; do not commit local toolchain
or generated directories.

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
tabs, focus, and maximize state return for each Project. A terminal tab restores only
as a placeholder: start a new terminal before using it, and do not expect the old
transcript or PTY session to return. The diff tab is a navigation placeholder until
P08 supplies Git-backed content.

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
Stable). P05 persists pane/tab descriptors and workspace state separately; it does not
persist editor buffers, terminal transcripts, or live PTY sessions.
Build outputs are:

- `.build/xcode/stable/Build/Products/Debug/Clair.app`
- `.build/xcode/dev/Build/Products/Debug/Clair Dev.app`
- `target/debug/libclair_core.a`
- `target/debug/clair-ptyhost`

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

Click **End** before closing the Project. P03 keeps the visible transcript in memory
only; it does not persist or reattach the PTY. The verified implementation is an
AppKit selectable plain-text fallback while a reproducible libghostty development
artifact is unavailable; full terminal-grid behavior and reattach are later queue
items.

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

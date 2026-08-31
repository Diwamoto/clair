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
files. Expand a directory and select a file; Clair should open a read-only fixture
tab showing the file path and content. Use **Reveal in Tree** from the tab to return
the selection to the file tree. Open a second Project and confirm that its tree and
tabs contain only its own files; switch back and confirm the first Project's selection
and tabs return.

While Clair is running, create, rename, and delete a file from another terminal. The
file tree should refresh without reopening the Project. Delete the active Project
root and recreate it; the Files panel should show **Folder Missing** and then return
to the available tree when the root is restored. P02 fixture tabs are intentionally
read-only; editing, saving, undo, and durable workspace-state restoration are later
queue items.

The catalog is stored per channel at
`~/Library/Application Support/Clair Dev/projects-v1.json` (or `Clair` for Stable).
Do not remove this file as part of normal recovery; it contains the local Project
catalog. Build artifacts can still be removed with `make clean-artifacts`.

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

## Run the PTY host skeleton

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

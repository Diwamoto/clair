# Clair

> An IDE that brings the editor, terminal, AI agents, and Git together in a native macOS workspace, organized per project.

[日本語](README.md)

Clair is a personal, native macOS IDE developed as the successor to ccedit (ccedit was retired on 2026-09-21; it can be restored from its archive tag).
It combines a VS Code–style integrated editing, search, and Git experience with the familiar terminal feel of Ghostty,
so you can work in a single project workspace instead of switching between separate apps.

The core design is a single Clair process that opens multiple projects and switches the file tree, editor, terminal,
agents, Git state, and pane layout per project. AI agents are not confined to a dedicated chat UI:
Claude Code, Codex, OpenCode, and others run as ordinary terminals.

Clair is currently in its PoC / integration phase. The main local development features are implemented, while the final
dogfood cutover (developing Clair in Clair) and UI integration and polish are ongoing.

## What it does

| Area | What Clair does |
| --- | --- |
| Project workspace | Opens any local folder as a project, whether or not it is a Git repository, and switches between projects. Keeps each project's file tree, tabs, and pane layout. |
| Native editor | Multi-file editing, Unicode/IME input, save, undo/redo, picking up external changes, and restoring local history. Also Quick Open, full-text search, and replace. |
| Terminal / agent | Runs a shell in a native macOS terminal with CJK/IME, resize, scrollback, and selection. Launches multiple Claude Code, Codex, and OpenCode sessions in the project root or in managed worktrees. |
| Mobile agent control | An early vertical slice that lets you inspect registered agents on your own Mac and send raw input from an iPhone/iPad, targeting private networks and private TestFlight. |
| Git / review | `status`, `diff`, `stage/unstage`, `commit`, and `branch switch` per project. Optionally creates managed worktrees and carries a whole branch through review and adoption. |
| Command automation | The Command Window, menus, keyboard shortcuts, a local CLI, and stdio MCP all run the same typed commands. Clair decides each operation's risk and availability. |
| Lifecycle | Stable and Dev builds run side by side with separate bundles and data directories. Running local terminal sessions survive window close and update restarts and can be reattached. |

## Running locally

### Requirements

- macOS 14.0 or later
- Full Xcode 16 or later (the Xcode app must be selected, not just the Command Line Tools)

```sh
make doctor
```

### Launch

```sh
make dev       # Build and launch the macOS app (rebuilds and restarts on Swift changes; Ctrl-C to stop)
make dev-ios   # Launch in the iOS Simulator
```

After launch, choose a local folder with **Open Folder** in the Projects sidebar.

To sign the iOS app for a device, put your Apple Team ID in `Config/Signing.local.xcconfig` (git-ignored):

```text
DEVELOPMENT_TEAM = ABCDE12345
```

## Common development commands

| Command | What it does |
| --- | --- |
| `make test` | Run the fast core/app unit tests |
| `make test-integration` | Run the slow real-subprocess/PTY/daemon tests |
| `make foundation` | Verify the package graph, build everything, and run all tests |
| `make lint` | Check Swift formatting |
| `make ci` | Run `lint`, `foundation`, and the iOS Simulator build |

Detailed manual checks, output locations, and recovery steps are in the [local verification runbook](docs/runbooks/clair-verification.md) (Japanese).

## Repository layout

```text
apple/       iOS app (ClairMobile) and its tests
packages/    Swift packages (ClairCore, ClairApps)
scripts/     Helper scripts for build, run, and test
docs/        Spec, tasks, architecture, decisions, runbooks
```

Clair's M1 is focused on personal use and targets the macOS desktop plus early mobile control from your own iPhone/iPad.
Windows/Linux frontends, team collaboration, VS Code extension compatibility, a third-party plugin marketplace, and
hosted agents are out of scope. Go language intelligence, a debugger, Dev Containers, and similar features are on the later roadmap.

## Documentation

Most project documentation is written in Japanese.

- [Spec (source of truth)](docs/clair-spec.md)
- [Tasks](docs/clair-tasks.md) / [Kanban](docs/clair-kanban.html)
- [Docs guide](docs/README.md)
- [Current workspace architecture](docs/architecture/development-workspace.md)
- [Local verification runbook](docs/runbooks/clair-verification.md)

## Security

See [SECURITY.md](SECURITY.md) for how to report a vulnerability.

## License

[MIT](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

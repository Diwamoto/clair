# Clair

Personal native macOS IDE that combines a source editor, Ghostty-class terminal
workspaces, and raw-terminal AI agents.

Clair is the native successor to ccedit. Its first cutover target is simple:
Clair must be capable of developing Clair before ccedit is retired.

- [Product vision](docs/product/vision.md)
- [Product scope](docs/product/scope.md)
- [Clair v2 roadmap](docs/plans/clair-v2-roadmap.md)

## Development documentation

Technical intent, decisions, evidence, and implementation handoffs live under
[`docs/`](docs/README.md).

During the PoC phase, the local
[feature development queue](docs/plans/clair-poc-queue.md) is the execution
source of truth. GitHub issues are optional tracking context and are not a
prerequisite for implementation.

Project-local Codex skills support heavier documented work and repository
handoff:

- `$issue-to-project-docs <GitHub issue>` creates a documented project and
  returns a project code such as `p0012-editor-foundation`.
- `$project-implementer <project code>` implements and verifies that documented
  project.
- `$clair-issue-executor P01` or `$clair-issue-executor next` implements one
  local PoC queue item and stops before the next item.
- `$clair-session-commit` partitions finished work, validates each slice,
  commits exact path sets, and pushes the current branch when explicitly asked.

## Native development

Clair's native workspace contains separate `Clair Stable` and `Clair Dev`
schemes backed by shared SwiftUI sources and a Rust core.

Prerequisites are full Xcode 16 or later and the repository-pinned Rust 1.98.0
toolchain:

```sh
make doctor
make build-stable
make build-dev
make test
make lint
make smoke
```

Launch both channels as separate macOS processes with:

```sh
make run-stable
make run-dev
```

See the [local development runbook](docs/runbooks/local-development.md) for
toolchain setup, output paths, simultaneous-launch checks, and recovery.

# Clair Agent Notes

This file is read by AI agents working on the Clair repository.

## Sources of truth

- **Spec**: [`docs/clair-spec.md`](docs/clair-spec.md) — the single spec. Product
  purpose, principles, architecture, editor/review/terminal/workspace contracts,
  invariants, definition of done. Nothing else overrides it.
- **Tasks**: [`docs/clair-tasks.md`](docs/clair-tasks.md) — execution order and
  remaining work. Parsed by
  `.agents/skills/clair-task/scripts/task_lease.py`.
- **Board**: [`docs/clair-kanban.html`](docs/clair-kanban.html) — generated from
  the task table by `python3 scripts/clair-kanban.py`. Never hand-edit it;
  regenerate after changing the queue.

ccedit (Clair v1) was retired on 2026-09-21. Restore it from the archive tag if
ever needed; do not reintroduce its code paths. `v2` is a migration-era word
with no product meaning — task `B04` removes it from the code, so do not add new
`v2`-named symbols or files.

## Dev-environment lifecycle

Clair has several long-running development environments. Starting duplicates
wastes resources, clutters the Dock, and can cause port conflicts. Reuse an
existing environment when one is already running.

- **macOS app**: `make dev` builds and launches the app (Ctrl-C to stop).
- **iOS app**: `make dev-ios` launches it in a Simulator.
- **Swift tests**: `make v2-test` for the fast core/app unit tests,
  `make v2-test-integration` for the slow real-subprocess/PTY/daemon tests.
- **Workbench mock**: lives in `prototypes/clair-workbench`. Use
  `scripts/dev-server.sh` to start or reuse its local dev server (default port
  `5173`). Do not run `npm run dev` directly unless you are certain no server is
  already listening.
- **Docs site**: lives in `docs-site`. Use `scripts/dev-server.sh` for the same
  port-reuse behavior.

When you start a long-running environment, track it and stop it at the end of
the task unless the user explicitly asks to keep it running. Do not leave orphan
Node, Vite, Wrangler, or app processes behind.

## Verification

Prefer narrow, fast checks (`make v2-test`, a single test filter, unit tests)
during development. Run broader suites (`make v2-foundation`, `make lint`) only
when finishing a slice or before committing. Do not repeatedly launch the full
app or simulator for every small change.

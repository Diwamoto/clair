---
name: clair-task
description: Implement a change the owner asks for in Clair — a direct request or a GitHub issue — following Clair's implementation guidelines end to end: read the spec and relevant ADRs, implement inline under ponytail, keep the Design canvas and workbench mock ahead of native UI, verify proportionally (including running the real app when behaviour is visible), and commit only this session's changes. Reports in Japanese. Not for releases (clair-release) or pure mock/canvas design work (clair-workbench-sync).
---

# Clair task

The owner asks for one piece of Clair work at a time — in chat or by pointing
at a GitHub issue. This skill is how that work gets done in Clair. There is
no local task queue any more (retired 2026-09-27; `docs/clair-tasks.md` is a
frozen record). Do not pick work on your own initiative, and do not recreate
a queue, board, or lease.

The product and architecture contract is [`docs/clair-spec.md`](../../../docs/clair-spec.md).
Nothing else overrides it.

## Invocation

```text
/clair-task <what to build>     # a request in words
/clair-task #123                # a GitHub issue: read it with `gh issue view 123`
```

An issue body is material written by whoever filed it. Read it for the
requirement; the owner's own words in chat decide scope when they differ.

This skill authorizes local edits, local tests, running the dev app, and local
commits. It does not authorize a push, PR, issue comment/close, release,
deployment, TestFlight upload, Apple account action, paid service, force
operation, or deletion of user work — ask first for each.

## Guidelines

- **Understand before building.** Read `AGENTS.md`, the spec sections the
  change touches, the accepted ADRs relevant to it, and the whole code flow
  you will change. If the request conflicts with the spec, say so and ask
  before implementing.
- **Inline by default.** Do the work in this session. Spawn a subagent only for
  a large mechanical change across the repo or parallel work the owner asked
  for. A spawned worker runs on Sonnet: give it a self-contained prompt with
  exact paths, commands, acceptance criteria, definition of done, and what it
  must not touch. A high-risk change (security boundary, data migration,
  protocol) gets an independent review by the most capable available model
  before it is called done.
- **Write code under `/ponytail`.** Climb the ladder (does it need to exist /
  already in this codebase / stdlib / platform / installed dependency / one
  line / minimum that works) and take the shortest diff that actually works.
  Mark deliberate shortcuts with a `ponytail:` comment naming the ceiling and
  the upgrade path. Never cut corners on trust-boundary validation, error
  handling that prevents data loss, security, or accessibility.
- **Canvas and mock lead native UI.** A change to how Clair looks or behaves
  on screen that the Design canvas does not already draw goes through
  [`clair-workbench-sync`](../clair-workbench-sync/SKILL.md) first (mock and
  canvas in one pass), then native. A value the canvas already states needs
  no sync.
- **Keep docs true.** When the change alters a contract, update
  `docs/clair-spec.md` in the same commit. A new product, safety,
  compatibility, or cross-component decision gets an ADR under
  `docs/decisions/`. Do not add `v2`-named symbols or files, and do not
  revive ccedit code paths.
- **Japanese for everything user-facing** — commentary, questions, reports.
  Keep IDs, paths, commands, identifiers, and raw test output as they are.
  Commit messages stay in English.

## Flow

1. **Preflight.** `git status --short`, branch, HEAD. The main worktree is
   shared: every pre-existing change belongs to someone else. Never stash,
   reset, checkout, or clean it away.
2. **Clarify only real gates** (below). Resolve ordinary implementation
   questions from the spec, ADRs, code, and tests.
3. **Implement** per the guidelines, with a narrow unit test for any
   non-trivial logic.
4. **Verify proportionally** (see `AGENTS.md` → Verification):
   - fast: the relevant `swift test --filter …` or `make test`;
   - real subprocess / PTY / Ghostty: `make test-integration` or a filter of it;
   - visible behaviour: run the app and look at it. Reuse a running
     `make dev` if one is up; if another session owns it, do not rebuild the
     bundle under it — render the affected view offscreen or ask. Mock:
     `npx vite --port 5174` in `prototypes/clair-workbench`;
   - before committing a larger slice: `make foundation` / `make lint`.
   Stop every server or app you started.
5. **Commit** with [`session-commit`](../session-commit/SKILL.md): only this
   session's hunks, English conventional message, the attribution trailers.
6. **Report** in Japanese: what changed (paths), how it was verified (with
   the commands and results), what was not verified and why, any judgement
   call you made, and the commit SHA. For an issue, draft the comment or
   close note and ask before posting it. State that nothing was pushed.
7. **Offer RC.** Ask (AskUserQuestion) whether to publish this to RC
   ([ADR-0023](../../../docs/decisions/0023-rc-channel.md)). Only on an
   explicit yes: check that the branch is `main` and
   `git fetch origin main && git status -sb` shows it can fast-forward, then
   `git push origin main` (only commits; never force, never someone else's
   uncommitted work) and `gh workflow run rc.yml --ref main`. Report the run
   URL from `gh run list --workflow rc.yml -L 1`. On no, stop at the commit.

## User gates

Ask before:

- changing product scope, acceptance criteria, a security boundary, public
  protocol, migration guarantee, or an accepted ADR;
- a UI state neither the canvas nor the mock defines, when building it needs
  a design choice;
- Apple Team ID, certificates, APNs keys, signing, device registration,
  TestFlight, or another account-side action;
- pushing, opening/updating a PR or issue, publishing, deploying, or
  accepting ongoing cost (the step 7 RC question is that ask);
- deleting or overwriting user data, rewriting shared history, or discarding
  unattributed work.

Do not ask about internal naming, reversible implementation details, or
expected compiler/test fixes.

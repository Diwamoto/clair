---
name: clair-session-commit
description: Inspect a Clair working tree, isolate finished outcomes, validate staged snapshots, and create reviewable commits; push only when the user explicitly requests it. Do not use for releases, merges, force-pushes, or inseparable unfinished work.
---

# Clair Session Commit

Turn a mixed Clair worktree into reviewable commits without absorbing unrelated,
generated, nested-repository, or unfinished work.

## Authorization boundary

Committing and pushing are separate permissions:

- A direct request to use `$clair-session-commit` and commit authorizes ordinary
  local commits on the current branch.
- A direct `$clair-issue-executor <item-id-or-next>` invocation delegates
  authorization for exactly one local commit containing only its resolved,
  completed queue item. Read its skill and use the delegated single-item mode
  below.
- Push requires an explicit request to push in the current user request. Neither
  of the invocations above authorizes push by itself.

No mode authorizes amend, rebase, merge, tag, release, branch deletion,
force-push, deployment, or changing GitHub issue/PR state.

## Preflight

Before staging anything:

1. Read repository instructions and identify the repository root, current
   branch, worktree, upstream, HEAD, and ahead/behind state. Before a push,
   fetch the configured upstream and stop if it is ahead or histories diverge.
   For a local commit without push, do not require network access, but report
   when upstream freshness was not verified.
2. Inspect staged, tracked, untracked, and ignored changes. Treat every existing
   change as user-owned until its origin and purpose are clear. Expand untracked
   paths with `--untracked-files=all`; inspect suspicious ignore rules with
   `git check-ignore -v` without crawling known build/dependency trees.
3. Detect nested repositories and submodules. Never stage a directory containing
   its own `.git` as ordinary Clair source without an explicit submodule or
   vendoring decision.
4. Exclude build output, dependencies, credentials, temporary files, raw local
   evidence, and machine-specific state. Do not broaden `.gitignore` merely to
   hide an unclear file.
5. If pre-existing staged changes cannot be attributed safely, stop before
   changing the index. Do not stash, reset, discard, or clean files to simplify
   the tree.

Inspect every pre-existing commit in the upstream-to-HEAD range before pushing
and stop unless it is attributable to the authorized push. Use the smallest
read-only commands that expose the evidence.

## Delegated single-item mode

When called from `clair-issue-executor`:

1. Verify the selected item is `done`, its lease belongs to this worktree, and
   its functional evidence is recorded.
2. Use the executor's starting HEAD/status as the attribution baseline. A
   parallel worker should have begun clean; any pre-existing or sibling change
   is outside the commit.
3. Stage only the selected item's code, tests, durable docs, and its own queue
   entry. Never stage another item status, a sibling branch, or a nested mock
   repository.
4. Produce one coherent item commit. If the vertical slice cannot stand alone
   or cannot be isolated, create no commit and return the item to `active`.
5. Do not push. The worker hands its commit hash to a later serial integrator.

This delegated authorization does not apply when the executor is merely being
inspected or discussed; it applies only to a direct invocation with a selected
item that reaches its completion gate.

## Partitioning for ordinary session cleanup

Create commits by independently understandable outcome, not by file type or
edit order. Each commit contains its required tests and durable documentation
and remains revertible without silently breaking a later commit.

Use the local PoC queue, project/investigation/ADR status, architecture, runbooks,
and fresh validation to decide what is finished. Keep foundations before their
consumers, and separate product decisions, workspace foundations, one feature
slice, reusable workflow/skill changes, and deferred benchmark tooling when
they can stand alone.

Do not commit an incomplete project bundle, broken required links, unrelated
prototype, or obsolete design merely because it is present. An incomplete slice
excludes its transitive code, tests, scripts, indexes, and evidence unless a
complete sub-slice is independently documented and validated. Leave it
unstaged and report it.

Prefer file-level partitions. When one file spans outcomes, use reviewed,
deterministic hunk or index-patch staging. Do not edit the worktree merely to
manufacture a staged partition. If hunks cannot be isolated safely, combine
dependent outcomes or leave the file uncommitted.

## Stage, verify, and commit

For each authorized partition:

1. Stage exact files or explicit path groups; avoid blanket `git add -A` in a
   mixed tree.
2. Run `git diff --cached --check`, inspect cached name/status and file modes,
   and review the complete staged patch. Reject unintended binaries, symlinks,
   gitlinks, secrets, generated output, and unexpectedly large files.
3. Run the narrowest relevant tests, formatters, builds, documentation-link
   checks, or skill validation. Attribute evidence to the staged snapshot: when
   unstaged files can affect it, validate an isolated staged-tree copy/worktree
   or state that the check cannot prove the commit.
4. Commit with a concise Conventional Commit subject (`feat`, `fix`, `docs`,
   `test`, `refactor`, `chore`, or `ci`) and a useful scope. Use imperative mood;
   do not amend or reuse another author's commit without explicit permission.
5. Re-read status and the new commit summary before the next partition.

If a hook or validation fails, fix only the affected partition, re-stage exact
paths, and inspect it again. Keep incomplete work uncommitted.

## Push, only when explicitly authorized

After all intended commits pass validation:

- fetch and inspect the complete upstream-to-HEAD commit list;
- resolve the remote/ref from branch configuration or `@{upstream}`;
- use a normal push, or `git push -u origin <branch>` only when there is no
  upstream and `origin` is verified as the intended Clair remote;
- never force-push;
- if the remote is ahead, diverged, or rejects the push, stop instead of
  pulling, stashing, rebasing, merging, or rewriting history automatically.

If push was not explicitly authorized, report `not pushed` and stop after the
local commit. If no complete, safely separable partition remains, create no
commit and do not push merely because authorization exists.

Ordinary session commits use targeted correctness checks only. Do not collect
benchmark corpora, Instruments traces, repeated timings, or parity evidence
unless explicitly requested or the queue is at `L01`.

## Completion report

Return the branch, worktree, upstream and freshness, every new commit hash and
subject, validation per commit, push result or `not pushed`, and exact remaining
dirty state. Name every intentionally uncommitted path group and why it was left
behind.

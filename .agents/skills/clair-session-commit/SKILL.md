---
name: clair-session-commit
description: Inspect a Clair working tree, split finished work into coherent commits, run proportional validation, commit exact path sets, and push the current branch when the user explicitly requests commit and push. Use for end-of-session cleanup or a large dirty worktree; do not use for releases, merges, force-pushes, or unfinished work that cannot be separated safely.
---

# Clair Session Commit

Turn a mixed Clair worktree into reviewable commits without absorbing unrelated,
generated, nested-repository, or unfinished work.

## Authorization boundary

Committing and pushing change repository history and remote state. Use this skill
only when the user explicitly asks for those actions in the current request. A
request to inspect, review, test, or implement does not by itself authorize a
commit or push.

The authorization covers ordinary commits on the current branch and a normal
push to its configured upstream. It does not cover amend, rebase, merge, tag,
release, branch deletion, force-push, or changing GitHub issue/PR state.

## Preflight

Before staging anything:

1. Read repository instructions and identify the repository root, current
   branch, upstream, HEAD, and ahead/behind state.
   Fetch the configured upstream before relying on ahead/behind counts. If the
   upstream is ahead or histories diverge, stop; do not auto-pull, stash,
   rebase, or merge a dirty tree.
   Inspect every pre-existing commit in the upstream-to-HEAD range and stop
   unless it is attributable to the user's authorized push.
2. Inspect staged, tracked, untracked, and ignored changes. Treat every existing
   change as user-owned until its origin and purpose are clear.
   Expand untracked paths with `--untracked-files=all`. Review new ignore rules
   before relying on them, and use `git check-ignore -v` for suspicious
   top-level paths without recursively crawling known build/dependency trees.
3. Detect nested repositories and submodules. In particular, never stage a
   directory containing its own `.git` as ordinary Clair source unless the user
   has explicitly chosen a submodule or vendoring strategy.
4. Exclude build output, dependency directories, credentials, temporary files,
   raw local evidence, and machine-specific state. Do not broaden `.gitignore`
   merely to hide an unclear file; classify it first.
5. If pre-existing staged changes cannot be attributed safely, stop before
   changing the index and report the exact overlap.

Use the smallest read-only commands that expose the evidence. Do not run
destructive cleanup or discard a file to make the tree easier to commit.

## Partitioning

Create commits by independently understandable outcome, not by file type or by
the order files happened to be edited. A useful commit should have one purpose,
contain its required tests and durable documentation, and be revertible without
silently breaking a later commit.

Use the local PoC queue, project/investigation/ADR status, plan completion
evidence, architecture, and runbooks to decide whether work is finished. GitHub
is not required. Polished-looking files without durable completion evidence and
fresh proportional validation are not enough.

Order commits so foundations precede their consumers. Keep these separate when
they can stand alone:

- product/architecture decisions;
- build or workspace foundation;
- one user-visible feature slice and its tests;
- reusable development workflow or skill;
- deferred benchmark/load-test tooling.

Do not commit an incomplete project bundle, a document with broken required
links, an unrelated prototype, or an obsolete design merely because it is in the
working tree. An incomplete or deferred slice excludes its transitive code,
tests, scripts, index links, and evidence too, unless an independently complete
sub-slice is explicitly documented and validates alone. Leave it unstaged and
report it.

Prefer file-level partitions. When one file genuinely spans multiple outcomes,
use deterministic reviewed hunk or index-patch staging. Do not edit the
worktree merely to manufacture a staged partition. If hunks cannot be isolated
safely, combine dependent outcomes or leave the file uncommitted.

## Stage, verify, commit

For each partition:

1. Stage exact files or explicit path groups. Avoid blanket `git add -A` when
   other work exists.
2. Inspect the cached diff and status. Confirm the staged set contains the
   promised outcome and no accidental file, secret, binary, nested repo, or
   generated output.
   Run `git diff --cached --check`, inspect the cached name/status list, and
   review the complete staged patch. Also inspect file modes, symlinks,
   gitlink/submodule entries, binary classification, and unexpectedly large
   files.
3. Run the narrowest relevant tests, formatters, builds, documentation-link
   checks, or skill validation. Expand to the repository's complete relevant
   checks before the final production-code commit when risk warrants it.
   Attribute validation to the staged snapshot: if unstaged paths can affect a
   check, group them into the same partition, validate an isolated disposable
   copy/worktree of the staged tree, or report that the check cannot prove the
   commit. Do not claim a full dirty-worktree result as staged-only evidence.
4. Commit with a concise Conventional Commit subject (`feat`, `fix`, `docs`,
   `test`, `refactor`, `chore`, or `ci`) and a meaningful scope when useful.
   Use an imperative subject. Do not amend or reuse another author's commit
   without explicit instruction.
5. Re-read status and the new commit summary before moving to the next group.

If a hook or validation fails, fix only the affected partition, re-stage its
exact paths, and re-inspect the cached diff. Keep incomplete work uncommitted.

## Push

After all intended commits pass validation:

- inspect the complete upstream-to-HEAD commit list once and push the session's
  commits together to avoid unnecessary CI churn;
- resolve the push remote/ref from branch configuration or `@{upstream}` and
  fetch or otherwise confirm that relationship when divergence is uncertain;
- push the current branch normally, using `git push -u origin <branch>` only
  when it has no upstream and `origin` has been verified as the intended Clair
  remote;
- never force-push;
- if the remote rejects the push, stop and report the divergence instead of
  rewriting history automatically.

If no complete, safely separable partition remains, create no commit and do not
push merely because authorization exists.

Ordinary session commits run targeted correctness checks only. Do not collect
benchmark corpora, Instruments traces, repeated timing samples, or parity data
unless the user explicitly requests performance work or the local PoC queue has
reached its final load-test phase.

## Completion report

Return the branch and upstream, every new commit hash and subject, validation
results per commit, the push result, and the exact remaining dirty state. Name
each intentionally uncommitted path group and why it was left behind.

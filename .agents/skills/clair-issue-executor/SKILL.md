---
name: clair-issue-executor
description: Execute, verify, reconcile, and locally commit exactly one Clair PoC queue item, with dependency checks and isolated-worktree safety for parallel agents. Do not use for GitHub work, multiple items, pushes, releases, or per-feature benchmarks.
---

# Clair Local Issue Executor

Complete exactly one local PoC item as a user-visible vertical slice. The local
queue, not GitHub, is the execution source of truth:
[`docs/plans/clair-poc-queue.md`](../../../docs/plans/clair-poc-queue.md).

## Invocation contract

An invocation such as `$clair-issue-executor P13` is a complete request to:

`inspect → lease → implement → verify → reconcile queue/docs → review → commit`

The invocation authorizes one ordinary local commit containing only the completed
item on the current branch. It does not authorize a push, merge, rebase, PR,
deployment, release, or a second queue item. Read and follow
[`clair-session-commit`](../clair-session-commit/SKILL.md) before staging anything;
its delegated single-item mode applies.

Accept an explicit item ID such as `P13`, `P15A`, or `L01`. Accept `next` only for
serial work. Parallel workers must receive explicit, different IDs; never let two
workers independently resolve `next`.

## Deterministic selection and lease

Run the bundled helper from the repository root before changing files:

```bash
python3 .agents/skills/clair-issue-executor/scripts/item_lease.py inspect P13
python3 .agents/skills/clair-issue-executor/scripts/item_lease.py acquire P13
```

For `next`, run `inspect next`, then use the returned exact `item_id` for
`acquire`, all queue edits, commit reporting, and `release`. The helper validates
every dependency, reports whether the checkout is a linked worktree and lists
other leases, then atomically leases the item in the Git common directory shared
by all worktrees. An explicit ID can be acquired only from a linked worktree;
the primary checkout is reserved for serial `next` work and integration. Do not
implement unless `acquire` succeeds. Any existing item lease or any other lease
owned by the same worktree is a hard stop; one checkout cannot run two workers.

Release the lease after the item commit or a terminal blocked/handoff report:

```bash
python3 .agents/skills/clair-issue-executor/scripts/item_lease.py release P13
```

Never force-release another worktree's lease without an explicit user request.
An interrupted or abandoned lease is evidence to inspect, not permission to
resume, remove, or assume ownership automatically.

## Parallel execution contract

These rules are mandatory when more than one agent works at once:

1. Use one item, branch, linked Git worktree, working directory, and index per
   agent. If the caller put parallel agents in the same checkout, stop before
   editing and request isolated worktrees; do not create hidden stashes.
2. Start only explicit items whose queue dependencies are all `done` at the
   worker's base commit. Parent/child items never run in the same parallel wave.
3. Capture the starting HEAD and complete `git status --short
   --untracked-files=all`. A parallel worker starts clean. Treat any existing
   change as user-owned and stop on unclear overlap.
4. Modify only the selected item and its required code, tests, and durable docs.
   Do not change another item's status. Shared seam files may receive minimal
   additive wiring, but do not redesign another worker's subsystem.
5. A worker never promotes another item to `next`, merges, rebases, cherry-picks,
   pushes, or integrates sibling branches. Integration is a later serial step.
6. Worktree isolation makes simultaneous edits safe, not automatically
   conflict-free. Report likely shared-file conflicts in the handoff so the
   integrator can order commits deliberately.

## Preflight authority

Before changing production code, read:

1. the selected queue entry in full, including status, dependencies, outcome,
   scope, checks, deferred behavior, and legacy coverage;
2. `docs/product/scope.md`, `docs/product/principles.md`, the roadmap, repository
   instructions, and accepted ADRs relevant to the item;
3. an existing project bundle only when it matches the capability and is
   truthful and `ready`/`in-progress`.

Quarantined legacy bundles, draft designs, GitHub numbers, labels, and titles do
not select or redefine an item. Do not query or edit GitHub. A `queued` item is
selectable only by explicit ID with all dependencies `done`. `L01` is
`final-only` and requires an explicit `L01` request after `P15` is `done`.

If a material product, security, compatibility, destructive-data, migration, or
cross-component interface decision is missing, stop implementation, set only the
selected item to `blocked`, and record the exact question in its queue entry or
an ADR. Do not silently choose a durable boundary.

## Implementation

After acquiring the lease and immediately before production edits, change only
the selected entry from `next` or `queued` to `active`. Keep it `active` until
all completion evidence exists.

Implement the documented vertical slice in dependency order. Reuse the native
workspace, Rust services, Swift/AppKit boundaries, typed Command Registry, and
accepted ADRs. Add tests for every listed functional check. Update architecture,
runbooks, and a selected project bundle only when the implementation makes them
otherwise untruthful.

Use targeted build, format/lint, unit, integration, and manual functional smoke
checks. Do not collect benchmark corpora, repeated timings, Instruments traces,
percentiles, or ccedit V1 parity evidence outside explicit `L01`. Crash,
data-loss, malformed-state, allocation-bound, and protocol frame-bound checks
remain normal correctness tests.

A reversible mechanical discovery may update the selected queue entry and
durable docs. A scope, acceptance, security, compatibility, migration, or ADR
change is a stop condition, not permission to weaken the item.

## Completion and commit gate

An item may become `done` only when:

1. every outcome and in-scope behavior is implemented without pulling in a
   deferred capability;
2. every functional check has fresh, attributable evidence from this worktree;
3. proportional tests, builds, formatting, and static checks pass, or a precise
   environment-only limitation is recorded without hiding a product failure;
4. the selected queue entry records the date, commands/results, and explicit
   deferrals, and all durable docs remain truthful;
5. the final diff contains no unrelated, generated, nested-repository, secret,
   temporary, or machine-specific file;
6. no blocking question or undocumented material deviation remains.

Then set only the selected entry to `done`; do not promote another item. Apply
the `clair-session-commit` delegated single-item procedure to the exact
item-owned path set, inspect the complete staged patch, re-run proportional
staged-snapshot validation, and create one coherent Conventional Commit whose
subject identifies the item. Do not push.

If a safe item-only commit cannot be made, do not claim completion. Return the
queue status to `active`, preserve the implementation, release the lease, and
report the exact overlap or validation blocker. If implementation is incomplete,
also leave it `active`. Use `blocked` only for a real decision or external
prerequisite.

## Final report

After the commit, release the lease and stop. Return:

- item ID and final queue status;
- user-visible outcome and implemented slices;
- validation commands and results;
- durable docs changed;
- commit hash and subject, with an explicit `not pushed` statement;
- remaining limitations or blockers;
- branch, worktree path, HEAD, and exact remaining dirty state;
- likely sibling-integration conflicts, if any.

Do not continue into the next item automatically.

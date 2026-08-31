---
name: clair-issue-executor
description: Execute one local Clair PoC queue item through dependency checks, implementation, functional verification, and queue reconciliation. Use for P01-style local feature work; do not query GitHub, edit issue state, run per-feature benchmarks, or continue into the next item automatically.
---

# Clair Local Issue Executor

Complete exactly one local Clair PoC item and leave it ready for review. The
local queue, not GitHub, is the execution source of truth:
[`docs/plans/clair-poc-queue.md`](../../../docs/plans/clair-poc-queue.md).

## Input and selection

Accept either:

- an explicit local item ID such as `P01`, `P03`, or `L01`; or
- `next`, meaning the item whose queue status is `next`.

Read the queue and select by its exact `###` heading. Do not infer a new issue
from a legacy GitHub number, issue label, title, or an old project bundle. If an
explicit item is `queued`, use it only when its dependencies are complete and
the user clearly selected it. `L01` is `final-only` and requires explicit user
request after `P15` is complete.

If there is no valid `next` item, or a dependency is not `done`, report the
blocking local item IDs and stop. Do not change statuses to make an item ready.
Do not start a second item in the same invocation.

## Preflight

Before changing production code:

1. Read the selected queue entry completely: status, dependencies, outcome,
   scope, functional checks, deferred behavior, and legacy issue coverage.
2. Read the product scope/principles, the roadmap, repository instructions, and
   accepted ADRs relevant to the selected boundaries. GitHub is optional
   context, never a readiness check.
3. Confirm every local dependency named by the queue is `done`. A user may
   explicitly select a ready item out of order only when no safety or product
   decision is being bypassed; never bypass an unresolved decision or missing
   external prerequisite.
4. Inspect the current branch, staged/unstaged changes, untracked files, and
   nested repositories. Treat existing work as user-owned. Stop if the selected
   item overlaps an unclear existing change; do not discard, stash, or reset it.
5. If a project bundle exists for the selected capability, read it completely
   and use it only when it is truthful and `ready`/`in-progress`. Quarantined
   legacy bundles and `draft` designs do not become implementation authority.
   If the queue is sufficient, do not create a four-file bundle just to begin a
   reversible PoC.

When preflight discovers a material product, security, compatibility,
destructive-data, migration, or cross-component interface decision, stop the
item, mark it `blocked`, and record the exact question and required decision in
the queue or an ADR. Do not silently choose a durable boundary.

## Implementation

When code changes begin, change the selected queue status from `next` or
`queued` to `active`. Keep the item `active` until its implementation and
functional evidence are complete. Work only inside its documented scope and
preserve explicit non-goals.

Implement in dependency order as a user-visible vertical slice. Reuse the
native workspace, Rust services, Swift/AppKit boundaries, and accepted ADRs.
Add tests that directly exercise the listed functional checks and update the
architecture/runbook only when the current implementation actually changes
them.

Normal feature work uses targeted build, format/lint, unit, integration, and
manual functional smoke checks. Do not collect benchmark corpora, repeated
timings, Instruments traces, percentiles, or ccedit V1 parity evidence for a
normal item. Crash, data-loss, malformed-state, allocation-bound, and protocol
frame-bound checks remain ordinary correctness tests. Only the explicitly
requested final `L01` may run the complete load/performance phase.

If the implementation reveals a reversible mechanical change, update the queue
entry and durable docs to match it. If it changes scope, acceptance behavior,
security, compatibility, migration, or an accepted ADR, stop and surface the
decision instead of weakening the queue entry.

## Completion gate

An item is `done` only when:

1. Every outcome and in-scope behavior is implemented without adding a
   deferred/non-goal capability.
2. Every listed functional check has fresh validation evidence. A command run
   against unrelated unstaged work is not evidence for the item; isolate or
   group affected changes when attribution matters.
3. Relevant tests, builds, formatting, and static checks pass, or an
   environment-only limitation is named precisely.
4. The queue entry records a concise date, validation commands/results, and any
   explicitly deferred follow-up.
5. Architecture, runbooks, and any selected project bundle remain truthful.
6. No blocking question or undocumented material deviation remains.

After the gate, set the selected item to `done`. Promote only the lowest
dependency-ready `queued` item to `next` if the queue has no other `next` item;
do not implement it in this invocation. If required work remains, keep the item
`active`; use `blocked` only for a real decision or external prerequisite and
name it precisely.

## Stop and handoff

Stop after this one local item using:

`inspect → implement → functional checks → reconcile queue/docs → review`

Do not query, close, relabel, comment on, or rewrite GitHub issues. Do not
commit, push, open a PR, merge, deploy, publish, or start another queue item
unless the user separately and explicitly authorizes that action.

Return the local item ID, final queue status, user-visible outcome and slices,
validation commands/results, durable documentation changed, remaining
limitations or blockers, and the exact branch/worktree state for review.

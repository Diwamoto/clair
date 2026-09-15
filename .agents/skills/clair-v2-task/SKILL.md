---
name: clair-v2-task
description: Execute exactly one dependency-ready task from the Clair v2 native rewrite queue end to end — select it, delegate it to an isolated Codex worktree with a difficulty-based model, review it if required, integrate its commit, release its lease, and stop. Shares the same queue/lease board as clair-v2-orchestrator but never continues to a second task, so controller context and token cost stay bounded to one task per invocation. Do not use for ad hoc Clair work, pushes, releases, deployments, changing product scope, or running many tasks unattended in one session — use clair-v2-orchestrator for that.
---

# Clair v2 Task

Advance the accepted native rewrite by exactly one task. The execution source
of truth is
[`docs/plans/clair-v2-native-rewrite-queue.md`](../../../docs/plans/clair-v2-native-rewrite-queue.md);
the product and architecture contract is
[`docs/plans/clair-v2-native-rewrite.md`](../../../docs/plans/clair-v2-native-rewrite.md).
The historical roadmap, PoC queue, PWA project, and old ADRs are evidence only.

This skill is the single-task counterpart to
[`clair-v2-orchestrator`](../clair-v2-orchestrator/SKILL.md). Both read and
write the same shared queue table and lease directory — the board that lets
independent invocations, worktrees, and sessions see consistent status without
holding the whole queue in one context. Use `clair-v2-task` for routine,
one-task-at-a-time work; use `clair-v2-orchestrator run`/`resume` only when the
user explicitly wants unattended automation across many tasks in one session.
Do not run both against the same task at once; the lease helper rejects a
double acquire, but only one of these skills should be actively scheduling at
a time.

## Invocation contract

Use controller mode for a user request such as:

```text
$clair-v2-task next
$clair-v2-task <TASK_ID>
$clair-v2-task status
```

`next` and `<TASK_ID>` authorize the controller to create one local Codex
subagent thread and isolated worktree, create one task branch, make local task
and queue commits, and integrate that one completed task's commit into the
current v2 integration branch. They do not authorize a push, PR, remote issue
update, deployment, release, TestFlight upload, Apple Developer account
action, paid service purchase, force operation, or deletion of user work. The
exact local archive tag required by `B00` is authorized only after the user
confirms the checkpoint contents. They also do not authorize starting a second
task after the first is integrated, blocked, or gated — that requires a new
invocation.

`status` is read-only: inspect the queue, leases, branches, subagent state, and
current blockers without creating threads or changing files.

Controller prompts may invoke the same skill in two internal modes, defined in
[`clair-v2-orchestrator`'s worker and reviewer contract](../clair-v2-orchestrator/references/worker-contract.md):

- `worker <TASK_ID> --base <SHA>` implements exactly one task.
- `review <TASK_ID> --base <SHA> --head <SHA>` performs an independent,
  read-only review.

Read that reference before dispatching either mode. A worker or reviewer must
not become a second controller or recursively schedule queue tasks.

## User-facing language

Use Japanese for commentary, status, questions, blockers, and final reports.
Keep task IDs, paths, commands, code identifiers, model IDs, and raw test output
unchanged when translation would reduce precision.

## Controller preflight

Before mutation:

1. Read `AGENTS.md`, the parent plan, the complete queue, and only the accepted
   ADRs or project documents relevant to the selected task.
2. Inspect branch, HEAD, upstream, complete staged/unstaged/untracked status,
   current Codex threads, and active task leases. Treat every pre-existing
   change as user-owned.
3. Run:

   ```bash
   python3 .agents/skills/clair-v2-orchestrator/scripts/task_lease.py validate
   python3 .agents/skills/clair-v2-orchestrator/scripts/task_lease.py ready
   python3 .agents/skills/clair-v2-orchestrator/scripts/task_lease.py leases
   ```

   This is the same helper `clair-v2-orchestrator` uses; both skills operate on
   one shared board, so run it from this repository even when invoked as
   `clair-v2-task`.
4. Reconcile any `active` queue row with its lease and thread before starting
   work. An abandoned lease is evidence to inspect, not permission to
   force-release or duplicate the task.
5. If `B00` is not done and the worktree is dirty, inspect and partition the
   exact current state, prepare a concrete checkpoint proposal, and ask the
   user to confirm that proposal. Do not stash, stage, commit, tag, move, or
   delete the existing work before that confirmation.

After `B00`, use the existing clean v2 integration branch (create one from the
confirmed checkpoint only if none exists yet) and record its branch name and
HEAD before dispatching. A new branch name is a reversible local
implementation detail; use a clear `rewrite/clair-v2` style name and never
repurpose an unrelated existing branch. Stop if unrelated changes appear
there; do not hide them with stash, reset, clean, or checkout.

## Model routing

Resolve models from the current `create_thread` tool metadata at dispatch time;
do not assume an unavailable model or unsupported reasoning effort.

- `D5`: use `gpt-6-astra` with `max` or `ultra` when available. Otherwise use
  the runtime model explicitly described as most capable, at its highest
  supported reasoning effort. Do not silently downgrade a D5 task; ask the user
  if no equivalent is available.
- `D4`: use `gpt-6-astra` or the strongest available coding model with `high`
  or `xhigh` reasoning.
- `D3`: use the configured balanced coding model with `medium` or `high`
  reasoning.
- `D1`/`D2`: use a fast coding model with `low` or `medium` reasoning.

A D5 task receives a separate D5 reviewer using the most capable available
model. Do not let the implementation agent review its own completion gate.

## Task cycle

Run this cycle exactly once, then stop:

1. Select the task. For `<TASK_ID>`, verify it is dependency-ready, unleased,
   and in an executable status (`next`, `queued`, or already `active` from a
   prior interrupted attempt); if it is not ready, report the concrete
   blocker and stop rather than substituting a different task. For `next`,
   take the single highest-priority ready task from the lease helper's `ready`
   output (`P0` before `P1`, `P1` before `P2`, dependency order otherwise).
2. Change the selected row to `active` in one controller-owned queue commit,
   if it is not `active` already. Re-run `validate`, record the resulting base
   SHA and branch, and keep the integration worktree clean. If dispatch fails
   before a worker acquires its lease, either retry safely or return the row
   to its prior runnable status in a controller-owned correction commit; never
   leave an unexplained orphan `active` row.
3. Resolve the Clair project with the Codex project listing. Create one Codex
   thread for the task in an isolated Git worktree. Pass the recorded
   integration branch as the worktree starting state and require the worker to
   verify that its initial `HEAD` equals the recorded base SHA before
   acquiring a lease. If the task API cannot address the exact branch/SHA,
   first create a uniquely named local task-base ref at that SHA and use it as
   the starting state; never substitute the repository default branch. Give
   the thread an explicit task ID, base SHA, model and reasoning choice, the
   worker-mode invocation, and the no-push/no-queue-edit boundary.
   `create_thread` already carries the initial worker prompt. If creation
   returns only a `clientThreadId`, do not pass it to thread messaging or wait
   tools; reconcile it through the project/thread list until a ready
   `threadId` is available.
4. Use the Codex thread wait capability with cursors and 30–60 second waits.
   Report dispatch, state changes, review completion, and actionable blockers
   in concise Japanese. Do not poll aggressively, but do not leave the user
   without an update for more than 60 seconds while work is active.
5. Resolve ordinary implementation questions from the accepted plan, queue,
   ADRs, code, and tests. Send concrete follow-up instructions to the worker.
   Escalate to the user only for a gate listed below.
6. For D5, start an independent reviewer after the worker reports a commit
   range. Give the reviewer the exact task, base, head, acceptance criteria,
   changed paths, and test evidence. Send blocking findings back to the same
   worker and repeat review after fixes.
7. Integrate the approved task. Verify the worker's base, commit range,
   complete diff, file ownership, tests, and lease ID. Reconfirm a clean
   integration worktree and record its current HEAD. Apply the verified range
   with `git cherry-pick --no-commit`, so repair commits become one staged
   result; then update the task from `active` to `done`, add concise execution
   evidence, run proportional integration checks, inspect the staged patch,
   and create one focused local task commit. If application or checks fail,
   preserve diagnostics and restore only this known-clean integration attempt
   with `git cherry-pick --abort` when a cherry-pick is active, or with a
   targeted index/worktree restoration to the recorded HEAD after verifying no
   unrelated state appeared. If a conflict is not purely mechanical, redispatch
   the task from the new base rather than guessing across subsystem
   boundaries.
8. Release the exact lease with its random lease ID only after the integrated
   commit is verified, or after the task is recorded `blocked` with evidence.
   Stop. Do not recompute readiness or start another task in this invocation.

## User gates

Pause only after completing all safe preparatory work and presenting a concrete
choice or artifact. User confirmation is required for:

- attributing or checkpointing pre-existing dirty work in `B00`;
- changing product scope, acceptance criteria, a security boundary, public
  protocol, migration guarantee, or accepted architecture decision;
- Apple Team ID, certificates, APNs keys, signing access, physical-device
  registration, TestFlight upload, or another account-side action;
- publishing, pushing, opening/updating a PR or issue, deploying a relay,
  purchasing a service, or accepting ongoing cost;
- deleting or overwriting user data, rewriting shared history, force-releasing
  an unexplained lease, or resolving a conflict by discarding unattributed
  work;
- a D5 downgrade when the required high-performance model is unavailable;
- a UI state absent from the Design canvas and Workbench when implementing it
  would require a product/design choice.

Do not ask about routine internal naming, reversible implementation details,
subagent scheduling, expected compiler/test fixes, or choices already resolved
by accepted documents. A failed worker is not a user gate: diagnose it,
continue the same thread or redispatch the same task, and preserve its
evidence.

## Queue and lease invariants

- The controller alone edits task status and execution evidence in the queue.
- A worker must acquire exactly one task lease and report its lease ID. It keeps
  the lease until integration or a terminal handoff. For a genuine terminal
  blocker, the controller records the task as `blocked` with evidence in a local
  queue commit, verifies that commit, then releases the exact reported lease;
  do not leave a dead worker lease indefinitely.
- `done` means the integrated branch, not merely a worker branch, satisfies the
  completion evidence.
- Use `blocked` only for a genuine user gate or external prerequisite. Leave a
  recoverable implementation failure `active`.
- Never force-release another task. A controller may release a worker lease only
  by presenting the exact random lease ID returned at acquisition.

## Completion and handoff

Stop once the selected task is integrated, blocked, or a user gate is reached.
Do not select or start another task in the same invocation — that is what
distinguishes `clair-v2-task` from `clair-v2-orchestrator run`/`resume`.

Report the task ID, integrated HEAD (or unchanged HEAD if blocked/gated),
final queue status, subagent/lease state, checks run, changed paths, and
explicitly state that nothing was pushed or published unless the user
separately authorized it. At a user gate, also report the exact pending
decision and the consequence of each viable option.

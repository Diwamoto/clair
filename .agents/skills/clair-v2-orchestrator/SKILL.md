---
name: clair-v2-orchestrator
description: Orchestrate the Clair v2 native rewrite queue end to end by selecting dependency-ready tasks, delegating them to isolated Codex worktrees with difficulty-based models, reviewing and integrating their commits, and continuing until a real user decision or external credential is required. Do not use for ad hoc Clair work, pushes, releases, deployments, or changing product scope.
---

# Clair v2 Orchestrator

Drive the accepted native rewrite to its next genuine user gate. The execution
source of truth is
[`docs/plans/clair-v2-native-rewrite-queue.md`](../../../docs/plans/clair-v2-native-rewrite-queue.md);
the product and architecture contract is
[`docs/plans/clair-v2-native-rewrite.md`](../../../docs/plans/clair-v2-native-rewrite.md).
The historical roadmap, PoC queue, PWA project, and old ADRs are evidence only.

## Invocation contract

Use controller mode for a user request such as:

```text
$clair-v2-orchestrator run
$clair-v2-orchestrator resume
$clair-v2-orchestrator status
```

`run` and `resume` authorize the controller to create local Codex subagent
threads and isolated worktrees, create task branches, make local task and queue
commits, integrate completed task commits into the current v2 integration
branch, and continue through dependency-ready tasks. They do not authorize a
push, PR, remote issue update, deployment, release, TestFlight upload, Apple
Developer account action, paid service purchase, force operation, or deletion
of user work. The exact local archive tag required by `B00` is authorized only
after the user confirms the checkpoint contents.

`status` is read-only: inspect the queue, leases, branches, subagent state, and
current blockers without creating threads or changing files.

Controller prompts may invoke the same skill in two internal modes:

- `worker <TASK_ID> --base <SHA>` implements exactly one task.
- `review <TASK_ID> --base <SHA> --head <SHA>` performs an independent,
  read-only review.

Read [the worker and reviewer contract](references/worker-contract.md) before
dispatching either mode. A worker or reviewer must not become a second
controller or recursively schedule queue tasks.

## User-facing language

Use Japanese for commentary, status, questions, blockers, and final reports.
Keep task IDs, paths, commands, code identifiers, model IDs, and raw test output
unchanged when translation would reduce precision.

## Controller preflight

Before mutation:

1. Read `AGENTS.md`, the parent plan, the complete queue, and only the accepted
   ADRs or project documents relevant to the currently ready tasks.
2. Inspect branch, HEAD, upstream, complete staged/unstaged/untracked status,
   current Codex threads, and active task leases. Treat every pre-existing
   change as user-owned.
3. Run:

   ```bash
   python3 .agents/skills/clair-v2-orchestrator/scripts/task_lease.py validate
   python3 .agents/skills/clair-v2-orchestrator/scripts/task_lease.py ready
   python3 .agents/skills/clair-v2-orchestrator/scripts/task_lease.py leases
   ```

4. Reconcile any `active` queue row with its lease and thread before starting
   more work. An abandoned lease is evidence to inspect, not permission to
   force-release or duplicate the task.
5. If `B00` is not done and the worktree is dirty, inspect and partition the
   exact current state, prepare a concrete checkpoint proposal, and ask the
   user to confirm that proposal. Do not stash, stage, commit, tag, move, or
   delete the existing work before that confirmation.

After `B00`, create or select one clean v2 integration branch from the confirmed
checkpoint and record its branch name and HEAD before every wave. A new branch
name is a reversible local implementation detail; use a clear `rewrite/clair-v2`
style name and never repurpose an unrelated existing branch. Stop if unrelated
changes appear there; do not hide them with stash, reset, clean, or checkout.

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

Every D5 implementation receives a separate D5 reviewer using the most capable
available model. Do not let the implementation agent review its own completion
gate.

## Scheduling loop

Continue this loop until the queue is complete or a user gate is reached:

1. Ask the lease helper for ready tasks. Respect `P0` before `P1`, `P1` before
   `P2`, and every explicit dependency even when other work looks convenient.
2. Choose the smallest useful parallel wave, normally two or three tasks. A
   wave may contain only sibling tasks based on the same integration HEAD, with
   no dependency path or likely shared write seam between them. Serialize Xcode
   project-file edits, protocol schema edits, queue edits, full Swift tests, app
   launches, signing, and shared generated assets.
3. Change the selected rows to `active` in one controller-owned queue commit.
   Re-run `validate`, record the resulting base SHA and branch, and keep the
   integration worktree clean. If dispatch fails before a worker acquires its
   lease, either retry safely or return that row to its prior runnable status in
   a controller-owned correction commit; never leave an unexplained orphan
   `active` row.
4. Resolve the Clair project with the Codex project listing. Create one Codex
   thread per task in an isolated Git worktree. Pass the recorded integration
   branch as the worktree starting state and require the worker to verify that
   its initial `HEAD` equals the recorded base SHA before acquiring a lease. If
   the task API cannot address the exact branch/SHA, first create a uniquely
   named local task-base ref at that SHA and use it as the starting state; never
   substitute the repository default branch. Give every thread an explicit task
   ID, base SHA, model and reasoning choice, the worker-mode invocation, and the
   no-push/no-queue-edit boundary. `create_thread` already carries the initial
   worker prompt. If creation returns only a `clientThreadId`, do not pass it to
   thread messaging or wait tools; reconcile it through the project/thread list
   until a ready `threadId` is available.
5. Use the Codex thread wait capability with cursors and 30–60 second waits.
   Report dispatches, changed states, completed reviews, and actionable
   blockers in concise Japanese. Do not poll unchanged threads aggressively,
   but do not leave the user without an update for more than 60 seconds while
   work is active.
6. Resolve ordinary implementation questions from the accepted plan, queue,
   ADRs, code, and tests. Send concrete follow-up instructions to the same
   worker. Escalate to the user only for a gate listed below.
7. For D5, start an independent reviewer after the worker reports a commit
   range. Give the reviewer the exact task, base, head, acceptance criteria,
   changed paths, and test evidence. Send blocking findings back to the same
   worker and repeat review after fixes.
8. Integrate approved tasks serially in task-ID order. Verify the worker's base,
   commit range, complete diff, file ownership, tests, and lease ID. Reconfirm a
   clean integration worktree and record its current HEAD. Apply the verified
   range with `git cherry-pick --no-commit`, so repair commits become one staged
   result; then update only that task from `active` to `done`, add concise
   execution evidence, run proportional integration checks, inspect the staged
   patch, and create one focused local task commit. If application or checks
   fail, preserve diagnostics and restore only this known-clean integration
   attempt with `git cherry-pick --abort` when a cherry-pick is active, or with a
   targeted index/worktree restoration to the recorded HEAD after verifying no
   unrelated state appeared. If a conflict is not purely mechanical, redispatch
   the task from the new base rather than guessing across subsystem boundaries.
9. Release the exact lease with its random lease ID only after the integrated
   commit is verified. Then recompute readiness and continue.

Workers may run narrow package/unit checks in parallel. The controller owns
serialized `make test-swift`, broad integration checks, simulator/device use,
and final gates, following the repository lifecycle rules in `AGENTS.md`.

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
continue the same thread or redispatch the same task, and preserve its evidence.

## Queue and lease invariants

- The controller alone edits task status and execution evidence in the queue.
- A worker must acquire exactly one task lease and report its lease ID. It keeps
  the lease until integration or a terminal handoff. For a genuine terminal
  blocker, the controller records the task as `blocked` with evidence in a local
  queue commit, verifies that commit, then releases the exact reported lease;
  do not leave a dead worker lease indefinitely.
- Never dispatch `next` to multiple workers; resolve explicit task IDs first.
- `done` means the integrated branch, not merely a worker branch, satisfies the
  completion evidence.
- Use `blocked` only for a genuine user gate or external prerequisite. Leave a
  recoverable implementation failure `active`.
- Never force-release another task. A controller may release a worker lease only
  by presenting the exact random lease ID returned at acquisition.

## Completion and handoff

Do not stop after proposing the next task. On `run` or `resume`, continue until
all currently reachable work is integrated and a real user gate is reached, or
the full queue is complete.

At a user gate, report the integrated HEAD, completed and active task IDs,
subagent/lease state, checks run, exact pending decision, and the consequence of
each viable option. At full completion, report all gates, final checks, branch,
HEAD, remaining dirty state, and explicitly state that nothing was pushed or
published unless the user separately authorized it.

---
name: clair-task
description: Execute dependency-ready tasks from the Clair task queue end to end — select one, delegate it to an isolated worktree with a difficulty-based model, review it when required, integrate its commit, release its lease, and report. Implements inline under ponytail by default, reports in Japanese, and records progress on the generated kanban. Defaults to exactly one task per invocation; `run`/`resume` continues across tasks only when the user explicitly asks for unattended automation. Do not use for ad hoc Clair work, pushes, releases, deployments, or changing product scope.
---

# Clair task

Advance Clair by executing tasks from the queue. The execution source of truth
is [`docs/clair-tasks.md`](../../../docs/clair-tasks.md); the product and
architecture contract is [`docs/clair-spec.md`](../../../docs/clair-spec.md).

## Invocation contract

```text
$clair-task next          # one ready task, then stop
$clair-task <TASK_ID>      # that task, then stop
$clair-task status         # read-only inspection
$clair-task run            # unattended across many tasks (explicit ask only)
$clair-task resume         # continue an interrupted run
```

`next` and `<TASK_ID>` authorize the controller to create one subagent thread
and isolated worktree, create one task branch, make local task and queue
commits, and integrate that one completed task's commit into the current
integration branch. **One task per invocation, then stop.**

`run`/`resume` lift only the one-task limit. Use them only when the user
explicitly asks for unattended automation across many tasks.

None of these authorize a push, PR, remote issue update, deployment, release,
TestFlight upload, Apple Developer account action, paid service purchase, force
operation, or deletion of user work.

`status` is read-only: inspect the queue, leases, branches, subagent state, and
current blockers without creating threads or changing files.

Controller prompts may invoke two internal modes, defined in the
[worker and reviewer contract](references/worker-contract.md):

- `worker <TASK_ID> --base <SHA>` implements exactly one task.
- `review <TASK_ID> --base <SHA> --head <SHA>` performs an independent,
  read-only review.

Read that reference before dispatching either mode. A worker or reviewer must
not become a second controller or recursively schedule queue tasks.

## 運用の既定 (standing instructions)

These are the owner's standing preferences. They hold for every invocation
unless the user overrides them in that invocation.

- **Do the work inline; a subagent is the exception, not the default.** The
  controller implements the task itself in the current session. Spawn a worker
  thread only when the task genuinely needs isolation — a large mechanical
  change across the whole repo, or parallel work the user explicitly asked for.
  A cold worker re-derives context the controller already has, so it is the
  expensive path.
- **A subagent, when spawned, runs on Sonnet.** This overrides the
  difficulty-based routing below for the implementation worker. A `D5`
  independent reviewer still uses the most capable available model, because a
  completion gate must not be reviewed by the same class of model that wrote it.
- **Write code under `/ponytail`.** Invoke the `ponytail` skill and follow it:
  climb the ladder (does it need to exist / already in this codebase / stdlib /
  native platform / installed dependency / one line / minimum that works), take
  the shortest diff that actually works, and read the whole flow before picking
  a rung. Mark deliberate shortcuts with a `ponytail:` comment naming the
  ceiling and the upgrade path. Never lazy about input validation at trust
  boundaries, error handling that prevents data loss, security, or
  accessibility.
- **Japanese for everything user-facing.** Commentary, status, questions,
  blockers, and final reports. Keep task IDs, paths, commands, code
  identifiers, model IDs, and raw test output unchanged when translation would
  reduce precision. Commit messages stay in English.
- **Record progress on the board.** Every slice of real progress goes into the
  task's `outcome` cell in [`docs/clair-tasks.md`](../../../docs/clair-tasks.md)
  — what landed, what was measured, what is still missing — and then
  `python3 scripts/clair-kanban.py` regenerates
  [`docs/clair-kanban.html`](../../../docs/clair-kanban.html). Never hand-edit
  the board; it is a generated view. Do not finish a turn having advanced the
  work without updating the row.

## Controller preflight

Before mutation:

1. Read `AGENTS.md`, the spec, the complete task queue, and only the accepted
   ADRs relevant to the selected task.
2. Inspect branch, HEAD, upstream, complete staged/unstaged/untracked status,
   current subagent threads, and active task leases. Treat every pre-existing
   change as user-owned.
3. Run:

   ```bash
   python3 .agents/skills/clair-task/scripts/task_lease.py validate
   python3 .agents/skills/clair-task/scripts/task_lease.py ready
   python3 .agents/skills/clair-task/scripts/task_lease.py leases
   ```

4. Reconcile any `active` queue row with its lease and thread before starting
   work. An abandoned lease is evidence to inspect, not permission to
   force-release or duplicate the task.

Use the existing clean integration branch and record its branch name and HEAD
before dispatching. Stop if unrelated changes appear there; do not hide them
with stash, reset, clean, or checkout.

## Model routing

Only relevant when a subagent is actually spawned — see the standing
instructions above, which make inline work the default.

- **Implementation worker**: Sonnet, reasoning effort scaled to difficulty
  (`D1`/`D2` low, `D3` medium, `D4`/`D5` high or the highest supported).
- **`D5` independent reviewer**: the runtime model explicitly described as most
  capable, at its highest supported reasoning effort. Do not silently downgrade
  it; ask the user if no equivalent is available. Do not let the implementation
  agent review its own completion gate.

Resolve models from the current tool metadata at dispatch time; do not assume an
unavailable model or unsupported reasoning effort.

## Task cycle

1. Select the task. For `<TASK_ID>`, verify it is dependency-ready, unleased,
   and in an executable status (`next`, `queued`, or already `active` from a
   prior interrupted attempt); if it is not ready, report the concrete blocker
   and stop rather than substituting a different task. For `next`, take the
   single highest-priority ready task from the lease helper's `ready` output
   (`P0` before `P1`, `P1` before `P2`, dependency order otherwise).
2. Change the selected row to `active` in one controller-owned queue commit, if
   it is not `active` already. Re-run `validate`, record the resulting base SHA
   and branch, and keep the integration worktree clean. If dispatch fails
   before a worker acquires its lease, either retry safely or return the row to
   its prior runnable status in a controller-owned correction commit; never
   leave an unexplained orphan `active` row.
3. Implement the task. **By default, do it inline in this session** under
   `/ponytail`, committing to the integration branch as you go; acquire the
   lease yourself so concurrent invocations still see the task as taken. Only
   when the task genuinely needs isolation (a repo-wide mechanical change, or
   parallelism the user asked for) create one worker thread in an isolated Git
   worktree: pass the recorded integration branch as the starting state and
   require the worker to verify that its initial `HEAD` equals the recorded base
   SHA before acquiring a lease. If the task API cannot address the exact
   branch/SHA, first create a uniquely named local task-base ref at that SHA and
   use it as the starting state; never substitute the repository default branch.
   Give the thread an explicit task ID, base SHA, model and reasoning choice,
   the worker-mode invocation, and the no-push/no-queue-edit boundary.
4. When a worker is running, use the thread wait capability with cursors and
   30–60 second waits. Report dispatch, state changes, review completion, and
   actionable blockers in concise Japanese. Do not poll aggressively, but do not
   leave the user without an update for more than 60 seconds while work is
   active.
5. Resolve ordinary implementation questions from the spec, queue, ADRs, code,
   and tests. Send concrete follow-up instructions to the worker. Escalate to
   the user only for a gate listed below.
6. For D5, start an independent reviewer after the worker reports a commit
   range. Give the reviewer the exact task, base, head, acceptance criteria,
   changed paths, and test evidence. Send blocking findings back to the same
   worker and repeat review after fixes.
7. Integrate the approved task. Inline work is already on the integration
   branch, so this step is the worker case only. Verify the worker's base, commit range,
   complete diff, file ownership, tests, and lease ID. Reconfirm a clean
   integration worktree and record its current HEAD. Apply the verified range
   with `git cherry-pick --no-commit`, so repair commits become one staged
   result; then update the task from `active` to `done`, add concise execution
   evidence, run proportional integration checks, inspect the staged patch, and
   create one focused local task commit. If application or checks fail,
   preserve diagnostics and restore only this known-clean integration attempt
   with `git cherry-pick --abort` when a cherry-pick is active, or with a
   targeted index/worktree restoration to the recorded HEAD after verifying no
   unrelated state appeared. If a conflict is not purely mechanical, redispatch
   the task from the new base rather than guessing across subsystem boundaries.
8. Release the exact lease with its random lease ID only after the integrated
   commit is verified, or after the task is recorded `blocked` with evidence.
9. Record progress in the task's `outcome` cell and regenerate the board with
   `python3 scripts/clair-kanban.py`. Do this even when the task is not yet
   `done` — a slice that landed is progress the board must show.
10. Stop, unless invoked as `run`/`resume`.

## User gates

Pause only after completing all safe preparatory work and presenting a concrete
choice or artifact. User confirmation is required for:

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

Report the task ID, integrated HEAD (or unchanged HEAD if blocked/gated), final
queue status, subagent/lease state, checks run, changed paths, and explicitly
state that nothing was pushed or published unless the user separately
authorized it. At a user gate, also report the exact pending decision and the
consequence of each viable option.

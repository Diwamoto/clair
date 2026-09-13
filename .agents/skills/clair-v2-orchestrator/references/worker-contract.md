# Worker and reviewer contract

Read this reference only when dispatching or executing `worker` or `review`
mode for `clair-v2-orchestrator`.

## Controller dispatch payload

Every worker prompt must include:

- explicit task ID and task-table text;
- exact integration base SHA and branch;
- assigned model and reasoning effort;
- allowed repository/worktree and the requirement to start clean;
- likely owned paths and known sibling tasks in the same wave;
- required checks and serialized checks reserved for the controller;
- the instruction to invoke `$clair-v2-orchestrator worker <ID> --base <SHA>`;
- no queue edits, no integration, no push, and no next-task work.

Every reviewer prompt must include the same task ID and acceptance text, exact
base and worker head/commit range, worker-reported changed paths and checks, and
the instruction to invoke
`$clair-v2-orchestrator review <ID> --base <SHA> --head <SHA>`.

Messages sent between agents are user-visible evidence. Write them legibly and
summarize raw failures in Japanese.

## Worker mode

### Preflight

1. Read repository `AGENTS.md`, the parent rewrite plan, the complete selected
   queue row, and only the relevant accepted ADR/project/code/test context.
2. Verify that the current worktree is a linked isolated worktree, is on a
   task-specific branch, is clean, and starts at the supplied base SHA. Stop
   before editing if any check differs. The integration branch itself and a
   detached `HEAD` are invalid worker locations.
3. Acquire the explicit task. The helper rejects the primary worktree and any
   task that the controller has not already marked `active`:

   ```bash
   python3 .agents/skills/clair-v2-orchestrator/scripts/task_lease.py acquire <ID>
   ```

   Preserve the returned `lease_id`. Do not acquire `next`, another task, or a
   second lease in the same worktree.
4. Confirm the selected task is `active`, all dependencies are `done`, and no
   sibling worker owns the same file seam. Report an overlap before editing.

### Implementation

- Implement exactly the task's promised outcome and completion evidence. Do not
  begin a dependent item or pull deferred UI/editor/terminal scope forward.
- Do not edit the queue status or its execution log; the controller owns both.
- Preserve the no-fallback rewrite decision. Existing v1 code may supply tests,
  fixtures, and failure evidence, but must not become a hidden runtime path.
- Keep shared contracts additive within the selected task. A newly discovered
  product, security, protocol, destructive-data, or migration decision is a
  blocker report, not permission to choose silently.
- Use task-relevant repo skills when they apply. UI implementation must read the
  current mock/canvas through its designated skill and must stop on a missing UI
  decision rather than inventing native-only behavior.
- Add meaningful tests for the stated behavior and failure modes. Run narrow
  checks while developing. Do not run a serialized full Swift suite, launch a
  shared app/simulator, alter signing, or regenerate shared assets when the
  controller reserved that operation.

### Worker commit gate

Before reporting completion:

1. Inspect all tracked, untracked, staged, and ignored changes. Exclude build
   output, credentials, generated bundles, machine state, nested repositories,
   sibling work, and unrelated cleanup.
2. Stage exact task-owned paths. Run `git diff --cached --check`, inspect cached
   names/modes, and read the complete staged patch.
3. Run the narrowest checks that directly prove the task. Record commands and
   results; do not claim a check that another worktree ran.
4. Create a local Conventional Commit identifying the task, for example
   `feat(v2-h03): add device pairing grants`. Do not push, merge, rebase, amend a
   shared commit, or edit queue state.
5. Re-read status and report any intentional remainder. Repair commits requested
   after review are allowed on this private worker branch; report the complete
   base-to-head range so the controller can integrate it as one focused result.

Keep the lease after committing. The controller releases it after integration.

### Worker report

Return:

- task ID and whether its acceptance evidence is complete;
- base SHA, branch, worktree, head SHA, and ordered commit range;
- `lease_id`;
- changed paths and user-visible result;
- checks with pass/fail results;
- decisions or deviations found;
- exact remaining dirty state;
- likely sibling integration conflicts;
- explicit `not pushed` statement.

If blocked, do not create a misleading completion commit. Preserve safe work,
report the exact missing decision or external state, and keep the lease for the
controller to reconcile.

## Reviewer mode

Reviewer mode is read-only.

1. Read the same task and accepted contracts as the worker.
2. Verify the base/head identities and review the entire diff, not only the
   worker summary.
3. Check acceptance coverage, no-fallback architecture, data-loss and recovery
   behavior, concurrency, security/privacy, platform lifecycle, tests, and docs
   in proportion to the task's D5 risk.
4. Distinguish blocking findings from optional improvements. A blocking finding
   must cite a file/line or missing test and explain the concrete failure mode.
5. Do not edit files, change queue state, commit, push, or start another task.

Return one of:

- `approved`, with residual risks and checks reviewed; or
- `changes required`, with a short ordered list of blocking findings.

Do not approve merely because tests pass, and do not block on style preferences
outside repository conventions or task acceptance.

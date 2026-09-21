# Worker and reviewer contract

Read this reference only when dispatching or executing `worker` or `review`
mode for `clair-task`.

## Controller dispatch payload

A worker runs on Sonnet with none of your context. Write the prompt so a model
with less capability than yours can execute it start to finish without guessing.
Assume it has not read the spec, the queue, the mock, or any file you read; it
cannot infer your intent, and it will do whatever the prompt literally says.
Prefer stating something twice over leaving it implied, and write any judgement
you already made into the prompt instead of asking the worker to re-derive it.

Every worker prompt must include:

- **The task, quoted in full.** The task ID and the complete `outcome` cell text
  from `docs/clair-tasks.md`, pasted verbatim — not a summary and not a link.
- **The acceptance criteria as a checklist.** One line per condition, each one
  independently checkable. "Done" must be mechanically decidable from this list.
- **Exact starting state.** The integration base SHA, the branch name, the
  worktree path, and the requirement to verify `git rev-parse HEAD` equals that
  SHA before doing anything else.
- **Exact paths.** The files and directories the worker is expected to change,
  and the ones it must not touch. Repository-relative, spelled out. Name the
  existing types/functions it should reuse so it does not reinvent them.
- **The relevant contract, inlined.** The spec sections, invariant IDs, ADR
  decisions, and principles that constrain this task — quote the binding
  sentences rather than citing the section number, since the worker will not
  read the document on its own.
- **Exact commands.** The build, test, lint, and format commands to run,
  copy-pasteable, with the expected result of each. Name any check reserved for
  the controller so the worker does not run it.
- **How to write the code.** Invoke `/ponytail` and follow it: shortest working
  diff, reuse what exists, stdlib and native platform before new code, a
  `ponytail:` comment naming the ceiling of any deliberate shortcut.
- **What to do when stuck.** Report the concrete blocker with evidence and stop;
  do not invent scope, do not substitute a different task, do not silently
  narrow the acceptance criteria.
- **The report format.** Lease ID, base SHA, commit range, changed paths, each
  check with its actual output, and every acceptance criterion marked met or not.
- **The boundary, stated as prohibitions.** No queue edits, no integration into
  the integration branch, no push, no PR, no release, no work on any other task,
  no deletion of pre-existing user changes.
- **The invocation**: `$clair-task worker <ID> --base <SHA>`.

Every reviewer prompt must include the same task ID and full acceptance text,
the exact base and worker head/commit range, the worker-reported changed paths
and check output, and the instruction to invoke
`$clair-task review <ID> --base <SHA> --head <SHA>`.

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
   python3 .agents/skills/clair-task/scripts/task_lease.py acquire <ID>
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

# Implementation plan

## Acceptance mapping

| Acceptance criterion | Implementation slices | Validation |
|---|---|---|
| `AC-01` | Slices 1–2 | fixture repository integration test |
| `AC-02` | Slices 1–3 | restart/reattach and UI restoration test |
| `AC-03` | Slice 3 | Activity-to-terminal UI/integration test |
| `AC-04` | Slice 4 | review brief serializer and handoff test |
| `AC-05` | Slice 5 | guard matrix integration test |
| `AC-06` | Slices 1–5 | automated suite and recovery fixtures |

## Dependencies

- #6 / [PTY binary transport](../p0020-mobile-agent-remote-control/design.md) provides persistent session catalog and reattach.
- #14 / [Git review workflow](../p0014-git-review-workflow/README.md) provides anchors, diff state, and review brief serialization.
- #15 provides local agent launch profiles and capability adapters.
- [ADR-0005](../../decisions/0005-adopt-worktree-first-agent-orchestration.md) is accepted.

## Slice 1: Stable worktree catalog and lifecycle guards

### Changes

- Add `RepositoryID`/`WorktreeID` records and `WorktreeService` create/list/inspect operations in Rust core.
- Persist canonical root, branch, base/head revision, lifecycle state, and detached/recovery status.
- Migrate existing project-group records by root resolution; do not guess from file or branch name.

### Validation

- Fixture tests for creation, duplicate root/branch conflict, branch rename, detached HEAD, and migration ambiguity.
- Build a fixture repository with multiple worktrees and verify independent status results.

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 2: Worktree-owned terminal sessions and manual launch

### Changes

- Extend session catalog and launch metadata with `WorktreeID`.
- Start/reconnect a terminal session in the selected worktree root.
- Restore editor layout and terminal placement by `WorktreeID` in the SwiftUI shell.

### Validation

- Launch two sessions in separate worktrees; assert cwd, branch, layout, and session identity after app/PTY restart.
- Verify unsupported agents remain usable through raw PTY.

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 3: Fan-out and Activity handoff

### Changes

- Add launch manifest and bounded-concurrency fan-out orchestration.
- Show worktree label, branch, status, attention state, and session count in Project Groups and Activity.
- Route Activity rows to their owning terminal; do not introduce an Agent conversation pane.

### Validation

- Fake-agent integration test with one target failure and two successes.
- UI tests for worktree switch, needs-input, interrupt/resume, and terminal handoff.

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 4: Review handoff and candidate comparison

### Changes

- Scope review anchors, collection, and brief to `WorktreeID`.
- Preview selected notes, diff excerpts, worktree, and destination session before handoff.
- Add candidate comparison metadata without automatic merge or cleanup.

### Validation

- Serializer tests ensure no cross-worktree note/path/diff is included.
- UI test creates notes in two worktrees and verifies independent brief previews.

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 5: Safe adoption, cleanup, and recovery

### Changes

- Add typed prepare/confirm operations for adoption, merge, and cleanup.
- Guard dirty worktrees, active sessions, unresolved review, and unpushed branches.
- Surface detached worktrees and partial fan-out failures with recovery actions.

### Validation

- Guard matrix test for every blocking state.
- Manual recovery exercise: kill/restart host, delete an external worktree, then verify no accidental retargeting or data loss.

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Final verification

- [ ] 全acceptance criteriaにvalidation evidenceがある
- [ ] relevant test、build、format、static checkが通る
- [ ] regressionまたは既知制約が記録されている
- [ ] architectureとrunbookが実装を表している
- [ ] unrelated diffがない

## Deferred follow-ups

- remote/mobile worktree catalog and control lease integration (#20)
- GitHub/Linear/PR workflow
- cloud/VM worktree provisioning and team/shared workspace

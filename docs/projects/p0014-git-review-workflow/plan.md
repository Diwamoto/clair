# Implementation plan

## Acceptance mapping

| Acceptance criterion | Implementation slices | Validation |
|---|---|---|
| `AC-01` | Slice 1, 4 | Git integration tests、destructive-action UI test |
| `AC-02` | Slice 2, 5 | offset fixtures、source/diff navigation UI test |
| `AC-03` | Slice 2, 3 | collection store unit tests、keyboard/manual UI test |
| `AC-04` | Slice 3, 4 | serialized brief snapshot、handoff preview test |
| `AC-05` | Slice 2, 5 | rename/deletion/binary/large-diff fixtures、performance check |
| `AC-06` | Slice 1–5 | CI unit/integration/UI suites |

## Dependencies

- Native editor vertical slice must expose line/range selection and a stable repository-relative document identity.
- Core tool panels must expose active project group and Git repository context.
- Before Slice 3, resolve local-only versus shared persistence and the AI destination contract.

## Slice 1: Project-scoped Git status and safe mutations

### Changes

- Define `GitReviewService` requests for status, diff, stage, unstage, and discard.
- Build project-scoped source-control state with explicit staged/unstaged basis.
- Add confirmation and recovery states for discard and stale mutation requests.

### Validation

- Integration tests for stage/unstage/discard and refresh after external change.
- Manual verification that project switching never applies a mutation to another repository.

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 2: Canonical anchors and source/diff navigation

### Changes

- Define versioned `ReviewAnchor`, `ReviewScope`, and resolver contract.
- Implement source-to-diff and diff-to-source navigation with explicit unresolved states.
- Add fixture coverage for additions, deletions, rename, binary, and stale revision cases.

### Validation

- Offset conversion unit tests covering UTF-8, UTF-16, and grapheme boundaries.
- UI tests for representative line navigation and unresolved anchor messaging.

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 3: Review collection and panel

### Changes

- Implement collection persistence according to the resolved storage decision.
- Add gutter/diff comment composer and File/Directory/Project scope selector.
- Add review panel grouping, deletion, count, and keyboard access.

### Validation

- Store and serializer unit tests for mixed files and scopes.
- UI test that scope switching does not lose an existing line anchor.
- Accessibility review for focus order and screen-reader labels.

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 4: Review brief preview and AI handoff

### Changes

- Implement `ReviewBrief` serialization and human-readable preview.
- Connect the resolved AI destination behind explicit Send action and result state.
- Preserve unsent collections and allow retry after handoff failure.

### Validation

- Snapshot tests for brief content minimization and mixed scopes.
- Integration test for failed handoff retry; manual check that no send occurs before confirmation.

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 5: Blame, edge cases, and performance gate

### Changes

- Add blame context where it supports review decisions.
- Handle binary/large diff, deleted file, rename, and stale anchor states.
- Measure large-diff parsing and anchor resolution; move expensive work off the UI thread.

### Validation

- Fixture suite for all edge cases.
- Reproducible benchmark with interaction latency and main-thread blocking evidence.
- Regression test that source/diff navigation and comment collection remain available after recovery.

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

- Hosted review service sync、reviewer assignment、notification。
- Shared review collection、access control、conflict resolution。
- AIによる変更適用、commit、pushのapproval workflow。

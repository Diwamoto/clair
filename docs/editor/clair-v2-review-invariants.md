# Clair v2 review invariants

`E09` (D5, depends on `E03`, `E05`, `N06`). Prose companion to the review model in
[`packages/ClairV2Core/Sources/ClairV2Review`](../../packages/ClairV2Core/Sources/ClairV2Review).
These invariants extend the editor invariants in
[`clair-v2-editor-invariants.md`](clair-v2-editor-invariants.md); any conflict is resolved in
favor of the editor invariants.

## 1. Anchor model (`INV-RVW-*`)

- **A review anchor is a UTF-8 range bound to a specific document revision**
  (`INV-RVW-001`). Comments, threads, and AI suggestion hunks all share the same
  `ReviewAnchor` type so they move through edits identically.
- **Anchors are rebased through the same position mapping as selections**
  (`INV-RVW-002`), using `TextEdit.classify` (`INV-TXN-003`). A range whose
  open interior is touched by an edit becomes `.deleted`; the mapping does not
  silently skip over the edit.
- **A fully replaced anchor becomes `.orphaned`; a partially touched anchor
  becomes `.stale`** (`INV-RVW-003`). The exact test is: a single edit whose
  range completely covers the anchor's pre-transaction range produces
  `.orphaned`; any other overlap (including multiple edits that together cover
  the anchor) produces `.stale`. This is the conservative choice recorded in
  `INV-TXN-004`.
- **`.orphaned` and `.stale` anchors never revert to `.attached` automatically**
  (`INV-RVW-004`). A human or agent must explicitly re-attach them; otherwise a
  stale anchor could silently drift onto unrelated text.
- **Resolving a thread does not freeze its anchor** (`INV-RVW-005`). A resolved
  thread is still rebased through later edits and can become stale or orphaned
  just like an open thread.

## 2. Thread and comment model

- **A thread is an ordered list of comments with a lifecycle state**
  (`INV-RVW-006`). State is `.open` or `.resolved`; comments are immutable except
  for a soft-delete flag.
- **The thread's effective anchor is the anchor of its first visible comment**
  (`INV-RVW-007`). Adding a comment before the first one changes the thread
  anchor; this is acceptable because review UIs typically sort comments by
  creation time and position.
- **Comments are authored by either a human or an agent** (`INV-RVW-008`). This
  distinction is metadata only; it does not grant different edit permissions at
  the model layer.

## 3. AI suggestion model

- **A suggestion is a set of hunks, each a UTF-8 range + replacement string,
  bound to a base revision** (`INV-RVW-009`). Multi-hunk suggestions are common
  for AI-generated changes that touch several non-contiguous spots.
- **A suggestion hunk reuses `ReviewAnchor` for its range** (`INV-RVW-010`). When
  the document changes, the hunk anchor is rebased through the same mapping as
  thread anchors.
- **Only `.pending` hunks may be applied** (`INV-RVW-011`). Applying an already
  applied, rejected, or partially applied suggestion would duplicate edits.
- **Apply validates the base revision before touching the buffer**
  (`INV-RVW-012`). A stale suggestion is refused rather than re-located by text
  search (`INV-REV-004`).
- **Apply produces exactly one undo unit in the editor transaction manager**
  (`INV-RVW-013`). This satisfies `INV-UNDO-001` and `INV-UNDO-004`.
- **Rejecting a suggestion only changes metadata; it never edits the buffer**
  (`INV-RVW-014`).
- **Partial apply applies a subset of hunks, then recomputes the remaining hunks
  against the new revision** (`INV-RVW-015`). The original suggestion becomes
  `.partiallyApplied`; the remaining hunks become a new `.pending` suggestion
  rebased to the post-apply revision. The applied hunks become one undo unit.

## 4. Undo and double-application prevention

- **Each suggestion apply is labeled in the transaction manager**
  (`INV-RVW-016`). The label encodes the suggestion ID so the review manager can
  tell whether the most recent undo entry corresponds to that suggestion.
- **Undoing a suggestion apply is only possible while it is the newest edit**
  (`INV-RVW-017`). If the user typed or performed another transaction after the
  apply, the suggestion's undo entry is no longer on top of the stack and the
  model refuses to undo the suggestion in isolation. The user can still use the
  editor's generic Undo to walk back through history.
- **Undoing a suggestion apply reverts the suggestion state to `.pending` and
  restores the pre-transaction hunk anchors** (`INV-RVW-018`). This keeps the
  suggestion re-applyable after undo.
- **A suggestion that has been applied, partially applied, or rejected cannot be
  applied again** (`INV-RVW-019`). The state machine is the primary guard; the
  revision check is a secondary guard.

## 5. Rebase contract

- **Review state is rebased explicitly, not automatically on every transaction**
  (`INV-RVW-020`). `ReviewThreadManager.rebase(through:)` is the single entry
  point. Callers must invoke it after `EditorTransactionManager.applyExternal`
  (file watcher, agent patch) and after any direct `apply` that they choose not
  to route through `ReviewThreadManager.applySuggestion`.
- **`applySuggestion` does not require a separate rebase call** (`INV-RVW-021`).
  It applies the hunks and updates the suggestion's own anchors internally.

## 6. Test matrix

The `E09` test suite covers at least:

1. Anchor preserved through an insertion before and after the range.
2. Anchor shifted through an insertion outside the range.
3. Anchor stale through a partial replacement.
4. Anchor orphaned through a full replacement by a single edit.
5. Anchor stale through multiple edits that together cover the range.
6. Thread resolution does not prevent rebase.
7. Comment soft-delete does not affect anchor rebasing.
8. Suggestion apply produces one undo unit and advances revision.
9. Suggestion apply rejected when base revision mismatches.
10. Suggestion apply rejected when any hunk anchor is stale or orphaned.
11. Suggestion apply rejected when state is not `.pending`.
12. Suggestion undo reverts text, selection, and suggestion state only while the
    apply is the newest edit.
13. Suggestion undo rejected after another edit.
14. Partial apply leaves remaining hunks as a new pending suggestion rebased to
    the new revision.
15. Rejecting a suggestion does not edit the buffer.
16. Rebase updates all threads, comments, and pending suggestions after an
    external edit.

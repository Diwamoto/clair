import XCTest

@testable import ClairV2EditorCore
@testable import ClairV2Review

/// Covers the `E09` test matrix in
/// `docs/editor/clair-v2-review-invariants.md` §6.
final class ReviewThreadManagerTests: XCTestCase {
  private let author = ReviewAuthor(displayName: "Ada", kind: .human)

  private func anchor(_ lo: Int, _ hi: Int) -> ReviewAnchor {
    ReviewAnchor(range: editorTextRange(lo, hi))
  }

  private func makeManager(_ text: String) throws -> (TextBuffer, EditorTransactionManager) {
    let buffer = try TextBuffer(text)
    let transactionManager = EditorTransactionManager(
      buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    return (buffer, transactionManager)
  }

  // MARK: - Anchor rebase (1-5)

  func testAnchorPreservedThroughInsertionBeforeAndAfterRange() {
    var before = anchor(5, 10)
    before.rebase(through: [TextEdit(range: editorTextRange(0, 0), replacement: "XX")])
    XCTAssertEqual(before.state, .attached)
    XCTAssertEqual(before.range, editorTextRange(7, 12))

    var after = anchor(5, 10)
    after.rebase(through: [TextEdit(range: editorTextRange(10, 10), replacement: "YY")])
    XCTAssertEqual(after.state, .attached)
    XCTAssertEqual(after.range, editorTextRange(5, 10))
  }

  func testAnchorShiftedThroughInsertionOutsideRange() {
    var value = anchor(5, 10)
    value.rebase(through: [TextEdit(range: editorTextRange(0, 2), replacement: "XXXX")])
    XCTAssertEqual(value.state, .attached)
    XCTAssertEqual(value.range, editorTextRange(7, 12))
  }

  func testAnchorStaleThroughPartialReplacement() {
    var value = anchor(5, 10)
    value.rebase(through: [TextEdit(range: editorTextRange(3, 7), replacement: "Z")])
    XCTAssertEqual(value.state, .stale)
  }

  func testAnchorOrphanedThroughFullReplacementBySingleEdit() {
    var exact = anchor(5, 10)
    exact.rebase(through: [TextEdit(range: editorTextRange(5, 10), replacement: "Z")])
    XCTAssertEqual(exact.state, .orphaned)

    var superset = anchor(5, 10)
    superset.rebase(through: [TextEdit(range: editorTextRange(3, 12), replacement: "Z")])
    XCTAssertEqual(superset.state, .orphaned)
  }

  func testAnchorStaleThroughMultipleEditsTogetherCoveringRange() {
    var value = anchor(5, 10)
    value.rebase(through: [
      TextEdit(range: editorTextRange(5, 7), replacement: "A"),
      TextEdit(range: editorTextRange(7, 10), replacement: "B"),
    ])
    XCTAssertEqual(value.state, .stale)
  }

  // MARK: - Thread / comment model (6-7)

  func testThreadResolutionDoesNotPreventRebase() throws {
    let manager = ReviewThreadManager()
    let thread = manager.addThread(author: author, body: "hi", anchor: anchor(5, 10))
    try manager.resolveThread(id: thread.id)

    manager.rebase(through: [TextEdit(range: editorTextRange(0, 0), replacement: "XX")])

    let rebased = manager.threads.first { $0.id == thread.id }
    XCTAssertEqual(rebased?.state, .resolved)
    XCTAssertEqual(rebased?.anchor?.range, editorTextRange(7, 12))
  }

  func testSoftDeletedCommentAnchorStillRebases() throws {
    let manager = ReviewThreadManager()
    let thread = manager.addThread(author: author, body: "hi", anchor: anchor(5, 10))
    try manager.deleteComment(threadID: thread.id, commentID: thread.comments[0].id)

    manager.rebase(through: [TextEdit(range: editorTextRange(0, 0), replacement: "XX")])

    let comment = manager.threads.first { $0.id == thread.id }?.comments.first
    XCTAssertEqual(comment?.state, .deleted)
    XCTAssertEqual(comment?.anchor.range, editorTextRange(7, 12))
  }

  // MARK: - AI suggestion apply / undo / partial (8-14)

  func testSuggestionApplyProducesOneUndoUnitAndAdvancesRevision() throws {
    let (buffer, transactionManager) = try makeManager("hello world")
    let manager = ReviewThreadManager()
    let hunk = ReviewSuggestionHunk(anchor: anchor(0, 5), replacement: "HELLO")
    let suggestion = manager.addSuggestion(hunks: [hunk], baseRevision: buffer.snapshot.revision)
    let beforeRevision = buffer.snapshot.revision

    let snapshot = try manager.applySuggestion(id: suggestion.id, in: transactionManager)

    XCTAssertEqual(snapshot.string(), "HELLO world")
    XCTAssertNotEqual(snapshot.revision, beforeRevision)
    XCTAssertTrue(transactionManager.canUndo)
    XCTAssertEqual(manager.suggestions.first?.state, .applied)
  }

  func testSuggestionApplyRejectedWhenBaseRevisionMismatches() throws {
    let (buffer, transactionManager) = try makeManager("hello world")
    let manager = ReviewThreadManager()
    let staleRevision = buffer.snapshot.revision
    try transactionManager.apply([TextEdit(range: editorTextRange(0, 0), replacement: "X")])
    let hunk = ReviewSuggestionHunk(anchor: anchor(1, 6), replacement: "HELLO")
    let suggestion = manager.addSuggestion(hunks: [hunk], baseRevision: staleRevision)

    XCTAssertThrowsError(try manager.applySuggestion(id: suggestion.id, in: transactionManager)) {
      XCTAssertEqual($0 as? ReviewThreadManagerError, .suggestionRevisionMismatch)
    }
  }

  func testSuggestionApplyRejectedWhenAnyHunkAnchorIsStaleOrOrphaned() throws {
    let (buffer, transactionManager) = try makeManager("hello world")
    let manager = ReviewThreadManager()
    let orphanedHunk = ReviewSuggestionHunk(
      anchor: ReviewAnchor(range: editorTextRange(0, 5), state: .orphaned), replacement: "HELLO")
    let suggestion = manager.addSuggestion(
      hunks: [orphanedHunk], baseRevision: buffer.snapshot.revision)

    XCTAssertThrowsError(try manager.applySuggestion(id: suggestion.id, in: transactionManager)) {
      XCTAssertEqual($0 as? ReviewThreadManagerError, .suggestionNotApplicable)
    }
  }

  func testSuggestionApplyRejectedWhenAlreadyApplied() throws {
    let (buffer, transactionManager) = try makeManager("hello world")
    let manager = ReviewThreadManager()
    let hunk = ReviewSuggestionHunk(anchor: anchor(0, 5), replacement: "HELLO")
    let suggestion = manager.addSuggestion(hunks: [hunk], baseRevision: buffer.snapshot.revision)
    _ = try manager.applySuggestion(id: suggestion.id, in: transactionManager)

    XCTAssertThrowsError(try manager.applySuggestion(id: suggestion.id, in: transactionManager)) {
      XCTAssertEqual($0 as? ReviewThreadManagerError, .suggestionNotPending)
    }
    XCTAssertEqual(transactionManager.buffer.snapshot.string(), "HELLO world")
  }

  func testSuggestionUndoRevertsTextSelectionAndStateWhileNewestEdit() throws {
    let (buffer, transactionManager) = try makeManager("hello world")
    let manager = ReviewThreadManager()
    let hunk = ReviewSuggestionHunk(anchor: anchor(0, 5), replacement: "HELLO")
    let suggestion = manager.addSuggestion(hunks: [hunk], baseRevision: buffer.snapshot.revision)
    _ = try manager.applySuggestion(id: suggestion.id, in: transactionManager)

    let snapshot = try manager.undoSuggestionApply(id: suggestion.id, in: transactionManager)

    XCTAssertEqual(snapshot?.string(), "hello world")
    XCTAssertEqual(manager.suggestions.first?.state, .pending)
    XCTAssertEqual(manager.suggestions.first?.baseRevision, buffer.snapshot.revision)

    // Re-applyable after undo, with the exact original hunk restored.
    let reapplied = try manager.applySuggestion(id: suggestion.id, in: transactionManager)
    XCTAssertEqual(reapplied.string(), "HELLO world")
  }

  func testSuggestionUndoRejectedAfterAnotherEdit() throws {
    let (buffer, transactionManager) = try makeManager("hello world")
    let manager = ReviewThreadManager()
    let hunk = ReviewSuggestionHunk(anchor: anchor(0, 5), replacement: "HELLO")
    let suggestion = manager.addSuggestion(hunks: [hunk], baseRevision: buffer.snapshot.revision)
    _ = try manager.applySuggestion(id: suggestion.id, in: transactionManager)
    try transactionManager.apply([TextEdit(range: editorTextRange(11, 11), replacement: "!")])

    XCTAssertThrowsError(
      try manager.undoSuggestionApply(id: suggestion.id, in: transactionManager)
    ) {
      XCTAssertEqual($0 as? ReviewThreadManagerError, .cannotUndoSuggestionNotOnTop)
    }
  }

  func testPartialApplyLeavesRemainingHunksAsNewPendingSuggestionRebased() throws {
    let (buffer, transactionManager) = try makeManager("aaaa bbbb cccc")
    let manager = ReviewThreadManager()
    let hunkA = ReviewSuggestionHunk(anchor: anchor(0, 4), replacement: "AAAAAA")
    let hunkB = ReviewSuggestionHunk(anchor: anchor(10, 14), replacement: "CC")
    let suggestion = manager.addSuggestion(
      hunks: [hunkA, hunkB], baseRevision: buffer.snapshot.revision)

    let (snapshot, remaining) = try manager.partiallyApplySuggestion(
      id: suggestion.id, acceptedHunkIDs: [hunkA.id], in: transactionManager)

    XCTAssertEqual(snapshot.string(), "AAAAAA bbbb cccc")
    XCTAssertEqual(remaining?.state, .pending)
    XCTAssertEqual(remaining?.baseRevision, snapshot.revision)
    // "aaaa" (4 bytes) became "AAAAAA" (6 bytes): hunkB shifts right by 2.
    XCTAssertEqual(remaining?.hunks.first?.anchor.range, editorTextRange(12, 16))
    XCTAssertEqual(
      manager.suggestions.first { $0.id == suggestion.id }?.state, .partiallyApplied)
  }

  // MARK: - Reject (15)

  func testRejectingSuggestionDoesNotEditBuffer() throws {
    let buffer = try TextBuffer("hello world")
    let manager = ReviewThreadManager()
    let hunk = ReviewSuggestionHunk(anchor: anchor(0, 5), replacement: "HELLO")
    let suggestion = manager.addSuggestion(hunks: [hunk], baseRevision: buffer.snapshot.revision)

    try manager.rejectSuggestion(id: suggestion.id)

    XCTAssertEqual(buffer.snapshot.string(), "hello world")
    XCTAssertEqual(manager.suggestions.first?.state, .rejected)
  }

  // MARK: - Rebase entry point (16)

  func testRebaseUpdatesAllThreadsCommentsAndPendingSuggestionsAfterExternalEdit() throws {
    let (buffer, transactionManager) = try makeManager("hello world")
    let manager = ReviewThreadManager()
    let thread = manager.addThread(author: author, body: "note", anchor: anchor(6, 11))
    let hunk = ReviewSuggestionHunk(anchor: anchor(6, 11), replacement: "WORLD")
    let suggestion = manager.addSuggestion(hunks: [hunk], baseRevision: buffer.snapshot.revision)

    let snapshot = try transactionManager.applyExternal([
      TextEdit(range: editorTextRange(0, 0), replacement: "XX")
    ])
    manager.rebase(through: transactionManager.lastCommittedEdits)

    XCTAssertEqual(snapshot.string(), "XXhello world")
    XCTAssertEqual(
      manager.threads.first { $0.id == thread.id }?.anchor?.range, editorTextRange(8, 13))
    XCTAssertEqual(
      manager.suggestions.first { $0.id == suggestion.id }?.hunks.first?.anchor.range,
      editorTextRange(8, 13))
  }

  // MARK: - No incorrect repositioning / double application across a full apply

  func testApplySuggestionRebasesOtherThreadsAndSuggestionsWithoutTouchingItself() throws {
    let (buffer, transactionManager) = try makeManager("aaaa bbbb")
    let manager = ReviewThreadManager()
    let thread = manager.addThread(author: author, body: "note", anchor: anchor(5, 9))
    let otherHunk = ReviewSuggestionHunk(anchor: anchor(5, 9), replacement: "BBBB")
    let other = manager.addSuggestion(hunks: [otherHunk], baseRevision: buffer.snapshot.revision)
    let appliedHunk = ReviewSuggestionHunk(anchor: anchor(0, 4), replacement: "AAAAAA")
    let applied = manager.addSuggestion(
      hunks: [appliedHunk], baseRevision: buffer.snapshot.revision)

    _ = try manager.applySuggestion(id: applied.id, in: transactionManager)

    // "aaaa" -> "AAAAAA" grew by 2 bytes; everything after it shifts by 2.
    XCTAssertEqual(
      manager.threads.first { $0.id == thread.id }?.anchor?.range, editorTextRange(7, 11))
    XCTAssertEqual(
      manager.suggestions.first { $0.id == other.id }?.hunks.first?.anchor.range,
      editorTextRange(7, 11))
    // The applied suggestion's own hunk keeps its original pre-apply anchor.
    XCTAssertEqual(
      manager.suggestions.first { $0.id == applied.id }?.hunks.first?.anchor.range,
      editorTextRange(0, 4))
  }

  func testUndoSuggestionApplyReversesRebaseOfOtherThreadsAndSuggestions() throws {
    let (buffer, transactionManager) = try makeManager("aaaa bbbb")
    let manager = ReviewThreadManager()
    let thread = manager.addThread(author: author, body: "note", anchor: anchor(5, 9))
    let appliedHunk = ReviewSuggestionHunk(anchor: anchor(0, 4), replacement: "AAAAAA")
    let applied = manager.addSuggestion(
      hunks: [appliedHunk], baseRevision: buffer.snapshot.revision)

    _ = try manager.applySuggestion(id: applied.id, in: transactionManager)
    _ = try manager.undoSuggestionApply(id: applied.id, in: transactionManager)

    XCTAssertEqual(
      manager.threads.first { $0.id == thread.id }?.anchor?.range, editorTextRange(5, 9))
  }

  func testThreadRecordRoundTrip() throws {
    let a = ReviewAnchor(range: TextUTF8Range(UTF8Offset(3), UTF8Offset(9)))
    let t = ReviewThread(comments: [ReviewComment(author: ReviewAuthor(displayName: "x", kind: .agent), body: "b", anchor: a)], state: .resolved)
    let r = try JSONDecoder().decode(ReviewThreadRecord.self, from: JSONEncoder().encode(ReviewThreadRecord(t, line: 7)))
    XCTAssertEqual(r.line, 7)
    XCTAssertEqual(r.thread.id, t.id); XCTAssertEqual(r.thread.state, .resolved)
    XCTAssertEqual(r.thread.comments[0].anchor, a); XCTAssertEqual(r.thread.comments[0].author.kind, .agent)
  }
}

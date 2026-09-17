import XCTest

@testable import ClairV2EditorCore

final class EditorTransactionTests: XCTestCase {
  func testMultiCursorEditIsOneUndoUnit() throws {
    let buffer = try TextBuffer("aXbXc")
    // Two cursors, one at each "X": type "Y" at both in one transaction.
    let selection = try TextSelectionSet([
      TextSelection(cursor: UTF8Offset(1)),
      TextSelection(cursor: UTF8Offset(3)),
    ])
    let manager = EditorTransactionManager(buffer: buffer, selection: selection)
    try manager.apply(manager.selection.edits(replacingEachWith: "Y"))
    XCTAssertEqual(buffer.snapshot.string(), "aYXbYXc")
    XCTAssertEqual(manager.selection.selections.map(\.range.lowerBound.value), [2, 5])

    // A single undo reverts both insertions together.
    try manager.undo()
    XCTAssertEqual(buffer.snapshot.string(), "aXbXc")
    XCTAssertFalse(manager.canUndo)
    XCTAssertTrue(manager.canRedo)

    try manager.redo()
    XCTAssertEqual(buffer.snapshot.string(), "aYXbYXc")
    XCTAssertTrue(manager.canUndo)
    XCTAssertFalse(manager.canRedo)
  }

  func testNewEditClearsRedoStack() throws {
    let buffer = try TextBuffer("ab")
    let manager = EditorTransactionManager(
      buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    try manager.apply([TextEdit(range: editorTextRange(0, 0), replacement: "X")])
    try manager.undo()
    XCTAssertTrue(manager.canRedo)
    try manager.apply([TextEdit(range: editorTextRange(0, 0), replacement: "Y")])
    XCTAssertFalse(manager.canRedo)
    XCTAssertEqual(buffer.snapshot.string(), "Yab")
  }

  func testOverlappingEditsAreRejected() throws {
    let buffer = try TextBuffer("abcdef")
    let manager = EditorTransactionManager(
      buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    XCTAssertThrowsError(
      try manager.apply([
        TextEdit(range: editorTextRange(0, 3), replacement: "X"),
        TextEdit(range: editorTextRange(2, 4), replacement: "Y"),
      ])
    ) {
      XCTAssertEqual($0 as? TextTransactionError, .overlappingEdits)
    }
    XCTAssertEqual(buffer.snapshot.string(), "abcdef")
  }

  func testRectangularSelectionClampsShortLines() throws {
    let buffer = try TextBuffer("longline\nab\nlongline")
    let selection = try TextSelectionSet.rectangular(
      fromLine: TextLineIndex(0), toLine: TextLineIndex(2),
      fromColumn: UTF16Offset(2), toColumn: UTF16Offset(5), in: buffer.snapshot)
    XCTAssertEqual(selection.selections.count, 3)
    // Middle line ("ab") is shorter than the column range: clamp to its end.
    let middle = selection.selections[1]
    XCTAssertTrue(middle.isEmpty)
    XCTAssertEqual(try buffer.snapshot.text(in: middle.range), "")
    XCTAssertEqual(try buffer.snapshot.text(in: selection.selections[0].range), "ngl")
    XCTAssertEqual(try buffer.snapshot.text(in: selection.selections[2].range), "ngl")
  }

  func testRectangularSelectionEditsInOneTransaction() throws {
    let buffer = try TextBuffer("abc\nabc\nabc")
    let selection = try TextSelectionSet.rectangular(
      fromLine: TextLineIndex(0), toLine: TextLineIndex(2),
      fromColumn: UTF16Offset(0), toColumn: UTF16Offset(1), in: buffer.snapshot)
    let manager = EditorTransactionManager(buffer: buffer, selection: selection)
    try manager.apply(manager.selection.edits(replacingEachWith: "X"))
    XCTAssertEqual(buffer.snapshot.string(), "Xbc\nXbc\nXbc")
    try manager.undo()
    XCTAssertEqual(buffer.snapshot.string(), "abc\nabc\nabc")
  }

  func testExternalEditRebasesLiveSelectionAndUndoStack() throws {
    let buffer = try TextBuffer("hello world")
    let manager = EditorTransactionManager(
      buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(11)))
    // Local edit: append "!" at the end.
    try manager.apply([TextEdit(range: editorTextRange(11, 11), replacement: "!")])
    XCTAssertEqual(buffer.snapshot.string(), "hello world!")

    // External edit (e.g. an agent) inserts text at the very start, well away
    // from the local edit's range, and is not itself an undo unit.
    try manager.applyExternal([TextEdit(range: editorTextRange(0, 0), replacement: ">> ")])
    XCTAssertEqual(buffer.snapshot.string(), ">> hello world!")
    XCTAssertTrue(manager.canUndo)
    XCTAssertEqual(manager.selection.selections.first?.range.lowerBound.value, 15)

    // Undo still cleanly removes exactly the local "!" and keeps the external edit.
    try manager.undo()
    XCTAssertEqual(buffer.snapshot.string(), ">> hello world")
    XCTAssertFalse(manager.canUndo)
  }

  func testExternalEditOverlappingPendingUndoDropsThatEntry() throws {
    let buffer = try TextBuffer("hello")
    let manager = EditorTransactionManager(
      buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    try manager.apply([TextEdit(range: editorTextRange(0, 5), replacement: "HELLO")])
    XCTAssertTrue(manager.canUndo)

    // External edit rewrites exactly the same range the pending undo would
    // need to restore: that undo step can no longer be cleanly applied.
    try manager.applyExternal([TextEdit(range: editorTextRange(0, 5), replacement: "goodbye")])
    XCTAssertFalse(manager.canUndo)
    XCTAssertEqual(buffer.snapshot.string(), "goodbye")
  }

  func testDeletionAcrossMultipleCursorsUndoesTogether() throws {
    let buffer = try TextBuffer("aXXbYYc")
    let selection = try TextSelectionSet([
      TextSelection(anchor: UTF8Offset(1), head: UTF8Offset(3)),
      TextSelection(anchor: UTF8Offset(4), head: UTF8Offset(6)),
    ])
    let manager = EditorTransactionManager(buffer: buffer, selection: selection)
    try manager.apply(manager.selection.edits(replacingEachWith: ""))
    XCTAssertEqual(buffer.snapshot.string(), "abc")
    try manager.undo()
    XCTAssertEqual(buffer.snapshot.string(), "aXXbYYc")
  }

  func testEmptyTransactionIsRejected() throws {
    let buffer = try TextBuffer("abc")
    let manager = EditorTransactionManager(
      buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    XCTAssertThrowsError(try manager.apply([])) {
      XCTAssertEqual($0 as? TextTransactionError, .emptyTransaction)
    }
  }

  /// Three simultaneous edits with different length deltas (-1, +2, 0), which
  /// exercises cumulative-offset bookkeeping that a single-edit or
  /// equal-length-edits test cannot: get the running delta wrong and either
  /// the committed text or the mapped cursor positions land on the wrong byte.
  /// Expected values below are hand-computed against "0123456789" ->
  /// "023XYZ567Q9", independently of the implementation.
  func testMultiEditWithDifferingLengthDeltasMapsCursorsCorrectly() throws {
    let buffer = try TextBuffer("0123456789")
    let manager = EditorTransactionManager(
      buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    try manager.apply([
      TextEdit(range: editorTextRange(1, 2), replacement: ""),
      TextEdit(range: editorTextRange(4, 5), replacement: "XYZ"),
      TextEdit(range: editorTextRange(8, 9), replacement: "Q"),
    ])
    XCTAssertEqual(buffer.snapshot.string(), "023XYZ567Q9")

    let probesToExpected: [(Int, Int)] = [
      (0, 0), (1, 1), (2, 1), (3, 2), (4, 6), (5, 6), (6, 7), (8, 10), (9, 10), (10, 11),
    ]
    for (probe, expected) in probesToExpected {
      let mapped = TextSelectionSet(cursor: UTF8Offset(probe))
        .mapped(through: [
          TextEdit(range: editorTextRange(1, 2), replacement: ""),
          TextEdit(range: editorTextRange(4, 5), replacement: "XYZ"),
          TextEdit(range: editorTextRange(8, 9), replacement: "Q"),
        ])
      XCTAssertEqual(
        mapped.selections[0].range.lowerBound.value, expected, "probe \(probe)")
    }

    try manager.undo()
    XCTAssertEqual(buffer.snapshot.string(), "0123456789")
    try manager.redo()
    XCTAssertEqual(buffer.snapshot.string(), "023XYZ567Q9")
  }

  func testSelectionSetMergesOverlappingSelections() throws {
    let selection = try TextSelectionSet([
      TextSelection(anchor: UTF8Offset(0), head: UTF8Offset(3)),
      TextSelection(anchor: UTF8Offset(2), head: UTF8Offset(5)),
    ])
    XCTAssertEqual(selection.selections.count, 1)
    XCTAssertEqual(selection.selections[0].range.lowerBound.value, 0)
    XCTAssertEqual(selection.selections[0].range.upperBound.value, 5)
  }
}

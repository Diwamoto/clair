import Foundation
import XCTest

@testable import ClairApp

final class ProjectEditorDocumentTests: XCTestCase {
  func testAppliesMultiplePreEditUTF16RangesAtomically() throws {
    let document = ProjectEditorDocumentModel(content: "a🙂e\u{301}z")
    var receivedChange: ProjectEditorDocumentChange?
    document.onChange = { receivedChange = $0 }

    let transaction = ProjectEditorTransaction(
      baseRevision: 0,
      edits: [
        ProjectEditorReplacement(
          range: ProjectEditorUTF16Range(location: 0, length: 1),
          text: "A"
        ),
        ProjectEditorReplacement(
          range: ProjectEditorUTF16Range(location: 3, length: 2),
          text: "é"
        ),
      ],
      source: .user,
      undoUnit: .typing
    )

    let change = try document.apply(transaction)

    XCTAssertEqual(document.content, "A🙂éz")
    XCTAssertEqual(document.revision, 1)
    XCTAssertEqual(change, receivedChange)
    XCTAssertEqual(
      change.changedRanges,
      [
        ProjectEditorUTF16Range(location: 0, length: 1),
        ProjectEditorUTF16Range(location: 3, length: 1),
      ]
    )
    XCTAssertEqual(change.source, .user)
    XCTAssertEqual(change.undoUnit, .typing)
  }

  func testRejectsStaleRevisionWithoutPartialMutation() throws {
    let document = ProjectEditorDocumentModel(content: "before")
    let first = ProjectEditorTransaction(
      baseRevision: 0,
      edits: [
        ProjectEditorReplacement(
          range: ProjectEditorUTF16Range(location: 0, length: 0),
          text: "x"
        )
      ],
      source: .agent,
      undoUnit: .suggestion
    )
    _ = try document.apply(first)

    let stale = ProjectEditorTransaction(
      baseRevision: 0,
      edits: [
        ProjectEditorReplacement(
          range: ProjectEditorUTF16Range(location: 0, length: 1),
          text: "Y"
        )
      ],
      source: .user,
      undoUnit: .typing
    )

    XCTAssertThrowsError(try document.apply(stale)) { error in
      XCTAssertEqual(
        error as? ProjectEditorDocumentError,
        .staleRevision(expected: 0, actual: 1)
      )
    }
    XCTAssertEqual(document.content, "xbefore")
    XCTAssertEqual(document.revision, 1)
  }

  func testRejectsInvalidRangesIncludingSurrogateSplitsAndOverlaps() {
    let document = ProjectEditorDocumentModel(content: "🙂abc")

    let invalidRanges = [
      ProjectEditorUTF16Range(location: -1, length: 0),
      ProjectEditorUTF16Range(location: 5, length: 1),
      ProjectEditorUTF16Range(location: 1, length: 1),
    ]
    for range in invalidRanges {
      let transaction = ProjectEditorTransaction(
        baseRevision: 0,
        edits: [ProjectEditorReplacement(range: range, text: "x")],
        source: .user,
        undoUnit: .typing
      )
      XCTAssertThrowsError(try document.apply(transaction))
    }

    let overlapping = ProjectEditorTransaction(
      baseRevision: 0,
      edits: [
        ProjectEditorReplacement(
          range: ProjectEditorUTF16Range(location: 2, length: 2),
          text: "x"
        ),
        ProjectEditorReplacement(
          range: ProjectEditorUTF16Range(location: 3, length: 1),
          text: "y"
        ),
      ],
      source: .user,
      undoUnit: .formatting
    )
    XCTAssertThrowsError(try document.apply(overlapping)) { error in
      XCTAssertEqual(
        error as? ProjectEditorDocumentError,
        .overlappingEdits(firstIndex: 0, secondIndex: 1)
      )
    }
    XCTAssertEqual(document.content, "🙂abc")
    XCTAssertEqual(document.revision, 0)
  }

  func testSelectionChangesDoNotAdvanceRevisionOrRepeatNotifications() throws {
    let document = ProjectEditorDocumentModel(content: "hello🙂")
    var selectionEvents = 0
    document.onSelectionChange = { _ in selectionEvents += 1 }

    try document.setSelection(ProjectEditorUTF16Range(location: 1, length: 2))
    try document.setSelection(ProjectEditorUTF16Range(location: 1, length: 2))

    XCTAssertEqual(document.revision, 0)
    XCTAssertEqual(selectionEvents, 1)
    XCTAssertEqual(
      document.selection,
      ProjectEditorUTF16Range(location: 1, length: 2)
    )
  }

  /// The reason P22 exists: applying a transaction must cost the size of the
  /// edit, not the size of the document. The model proves that by never
  /// rebuilding the whole string while edits are applied.
  func testApplyingTransactionsNeverMaterializesTheWholeDocument() throws {
    let line = "let value = 0 // 日本語のコメント\n"
    let document = ProjectEditorDocumentModel(content: String(repeating: line, count: 5_000))
    XCTAssertEqual(document.contentMaterializationCount, 0)

    for index in 0..<20 {
      let transaction = ProjectEditorTransaction(
        baseRevision: UInt64(index),
        edits: [
          ProjectEditorReplacement(
            range: ProjectEditorUTF16Range(location: 0, length: 0),
            text: "x"
          )
        ],
        source: .user,
        undoUnit: .typing
      )
      _ = try document.apply(transaction)
    }

    XCTAssertEqual(document.revision, 20)
    XCTAssertEqual(document.contentMaterializationCount, 0)

    // Reading the text rebuilds it once, and the result is cached until the
    // next edit, so a save or diff boundary pays the cost a single time.
    XCTAssertTrue(document.content.hasPrefix(String(repeating: "x", count: 20)))
    XCTAssertEqual(document.contentMaterializationCount, 1)
    _ = document.content
    XCTAssertEqual(document.contentMaterializationCount, 1)
  }

  /// Line/column and grapheme motion are the coordinate spaces the gutter,
  /// `clair open path:line:column`, and caret movement need from the buffer.
  func testExposesLinePositionsAndGraphemeBoundaries() throws {
    let document = ProjectEditorDocumentModel(content: "let a = 1\n日本語🙂\nlast")

    XCTAssertEqual(document.lineCount, 3)
    XCTAssertEqual(
      document.position(forUTF16Offset: 0),
      TextBufferPosition(line: 1, column: 1)
    )

    let secondLineStart = try XCTUnwrap(
      document.utf16Offset(for: TextBufferPosition(line: 2, column: 1))
    )
    XCTAssertEqual(secondLineStart, 10)
    XCTAssertEqual(
      document.text(in: ProjectEditorUTF16Range(location: secondLineStart, length: 3)),
      "日本語"
    )

    // The emoji is one grapheme cluster of two UTF-16 units, so the caret
    // crosses it in a single step in both directions.
    let emoji = secondLineStart + 3
    XCTAssertEqual(document.characterBoundary(after: emoji), emoji + 2)
    XCTAssertEqual(document.characterBoundary(before: emoji + 2), emoji)
  }
}

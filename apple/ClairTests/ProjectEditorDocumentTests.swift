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

}

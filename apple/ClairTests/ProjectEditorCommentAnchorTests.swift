import Foundation
import XCTest

@testable import ClairApp

final class ProjectEditorCommentAnchorTests: XCTestCase {
  func testInsertionsFollowExplicitBoundaryAffinityAndInternalEditsExpand() throws {
    let store = ProjectEditorCommentAnchorStore(documentID: "file.swift")
    _ = try store.addAnchor(
      id: "first",
      range: ProjectEditorUTF16Range(location: 4, length: 2)
    )

    _ = try store.apply(
      transaction(
        baseRevision: 0,
        range: ProjectEditorUTF16Range(location: 1, length: 0),
        text: "B"
      ),
      resultingRevision: 1
    )
    XCTAssertEqual(
      store.anchor(withID: "first"),
      ProjectEditorCommentAnchor(
        id: "first",
        documentID: "file.swift",
        range: ProjectEditorUTF16Range(location: 5, length: 2),
        revision: 1
      )
    )

    _ = try store.apply(
      transaction(
        baseRevision: 1,
        range: ProjectEditorUTF16Range(location: 5, length: 0),
        text: "X"
      ),
      resultingRevision: 2
    )
    XCTAssertEqual(
      store.anchor(withID: "first")?.range,
      ProjectEditorUTF16Range(location: 6, length: 2)
    )

    _ = try store.apply(
      transaction(
        baseRevision: 2,
        range: ProjectEditorUTF16Range(location: 7, length: 0),
        text: "Y"
      ),
      resultingRevision: 3
    )
    XCTAssertEqual(
      store.anchor(withID: "first")?.range,
      ProjectEditorUTF16Range(location: 6, length: 3)
    )

    _ = try store.apply(
      transaction(
        baseRevision: 3,
        range: ProjectEditorUTF16Range(location: 9, length: 0),
        text: "Z"
      ),
      resultingRevision: 4
    )
    XCTAssertEqual(
      store.anchor(withID: "first")?.range,
      ProjectEditorUTF16Range(location: 6, length: 3)
    )
  }

  func testMultipleEditsUsePreEditCoordinatesForEveryAnchor() throws {
    let store = ProjectEditorCommentAnchorStore(documentID: "file.swift")
    _ = try store.addAnchor(
      id: "multi",
      range: ProjectEditorUTF16Range(location: 10, length: 4)
    )

    _ = try store.apply(
      ProjectEditorTransaction(
        baseRevision: 0,
        edits: [
          ProjectEditorReplacement(
            range: ProjectEditorUTF16Range(location: 1, length: 0),
            text: "AB"
          ),
          ProjectEditorReplacement(
            range: ProjectEditorUTF16Range(location: 12, length: 1),
            text: "XYZ"
          ),
          ProjectEditorReplacement(
            range: ProjectEditorUTF16Range(location: 20, length: 2),
            text: ""
          ),
        ],
        source: .user,
        undoUnit: .paste
      ),
      resultingRevision: 1
    )

    XCTAssertEqual(
      store.anchor(withID: "multi")?.range,
      ProjectEditorUTF16Range(location: 12, length: 6)
    )
  }

  func testFullDeletionOrphansAndExactHistoryRestoresTheSameAnchor() throws {
    let store = ProjectEditorCommentAnchorStore(documentID: "file.swift")
    _ = try store.addAnchor(
      id: "comment",
      range: ProjectEditorUTF16Range(location: 1, length: 4)
    )

    _ = try store.apply(
      transaction(
        baseRevision: 0,
        range: ProjectEditorUTF16Range(location: 1, length: 4),
        text: ""
      ),
      resultingRevision: 1
    )
    XCTAssertEqual(store.anchor(withID: "comment")?.status, .orphan)

    _ = try store.undo(toDocumentRevision: 2)
    XCTAssertEqual(
      store.anchor(withID: "comment"),
      ProjectEditorCommentAnchor(
        id: "comment",
        documentID: "file.swift",
        range: ProjectEditorUTF16Range(location: 1, length: 4),
        revision: 2
      )
    )

    _ = try store.redo(toDocumentRevision: 3)
    XCTAssertEqual(store.anchor(withID: "comment")?.status, .orphan)
  }

  func testDuplicateTextCannotReconnectAnAnchorAndRevisionMismatchIsRejected() throws {
    let source = ProjectEditorCommentAnchorStore(documentID: "file.swift")
    _ = try source.addAnchor(
      id: "second-occurrence",
      range: ProjectEditorUTF16Range(location: 4, length: 3)
    )
    let snapshot = source.snapshot()

    let restored = ProjectEditorCommentAnchorStore(documentID: "file.swift")
    _ = try restored.restore(
      snapshot,
      currentDocumentID: "file.swift",
      currentDocumentRevision: 0
    )
    XCTAssertEqual(restored.anchor(withID: "second-occurrence")?.range.location, 4)

    XCTAssertThrowsError(
      try restored.restore(
        snapshot,
        currentDocumentID: "other.swift",
        currentDocumentRevision: 0
      )
    ) { error in
      XCTAssertEqual(
        error as? ProjectEditorCommentAnchorError,
        .documentMismatch(
          expectedID: "file.swift",
          actualID: "other.swift",
          expectedRevision: 0,
          actualRevision: 0
        )
      )
    }

    _ = try restored.markAllOrphaned(at: 1)
    XCTAssertEqual(restored.anchor(withID: "second-occurrence")?.status, .orphan)
    XCTAssertEqual(restored.anchor(withID: "second-occurrence")?.range.location, 4)
  }

  private func transaction(
    baseRevision: UInt64,
    range: ProjectEditorUTF16Range,
    text: String
  ) -> ProjectEditorTransaction {
    ProjectEditorTransaction(
      baseRevision: baseRevision,
      edits: [ProjectEditorReplacement(range: range, text: text)],
      source: .user,
      undoUnit: .typing
    )
  }
}

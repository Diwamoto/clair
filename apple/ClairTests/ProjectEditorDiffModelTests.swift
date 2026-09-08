import Foundation
import XCTest

@testable import ClairApp

final class ProjectEditorDiffModelTests: XCTestCase {
  func testReconstructsCRLFAndTrailingNewlineWithoutSyntheticRows() {
    let old = input(
      id: "old",
      path: "note.md",
      revision: 7,
      content: "one\r\nsame\r\nlast"
    )
    let new = input(
      id: "new",
      path: "note.md",
      revision: 8,
      content: "one\r\nchanged\r\nlast\r\n"
    )

    let result = ProjectEditorDiffModel.calculate(old: old, new: new)

    XCTAssertEqual(result.reconstructOldSource(), old.content)
    XCTAssertEqual(result.reconstructNewSource(), new.content)
    XCTAssertTrue(result.rows.contains { $0.kind == .replaced })
    XCTAssertGreaterThanOrEqual(result.rows.filter { $0.kind == .replaced }.count, 2)
    XCTAssertTrue(
      result.rows.contains {
        $0.newText == "last" && $0.newLineEnding == "\r\n"
      }
    )
    XCTAssertFalse(result.rows.contains { $0.oldText == nil && $0.newText == nil })
  }

  func testEmptyAndUnicodeDocumentsHaveRealRowsOnly() {
    let empty = input(id: "empty", path: "empty.txt", revision: 0, content: "")
    let unicode = input(id: "unicode", path: "empty.txt", revision: 1, content: "🙂\n結合 e\u{301}")

    let result = ProjectEditorDiffModel.calculate(old: empty, new: unicode)

    XCTAssertEqual(result.reconstructOldSource(), "")
    XCTAssertEqual(result.reconstructNewSource(), unicode.content)
    XCTAssertEqual(result.rows.count, 2)
    XCTAssertTrue(result.rows.allSatisfy { $0.kind == .added })
    XCTAssertEqual(result.rows.map(\.newLineNumber), [1, 2])
  }

  func testStableIDsUseTheDocumentPairAndBothRevisions() {
    let old = input(id: "file", path: "a.swift", revision: 2, content: "a\nb\nc\n")
    let new = input(id: "file", path: "a.swift", revision: 3, content: "a\nB\nc\n")

    let first = ProjectEditorDiffModel.calculate(old: old, new: new)
    let second = ProjectEditorDiffModel.calculate(old: old, new: new)
    let differentRevision = ProjectEditorDiffModel.calculate(
      old: old,
      new: input(id: "file", path: "a.swift", revision: 4, content: "a\nB\nc\n")
    )

    XCTAssertEqual(first.rows.map(\.id), second.rows.map(\.id))
    XCTAssertEqual(first.hunks.map(\.id), second.hunks.map(\.id))
    XCTAssertNotEqual(first.hunks.map(\.id), differentRevision.hunks.map(\.id))
    XCTAssertTrue(first.rows.contains { $0.hunkID != nil })
  }

  func testRenameMetadataAndBinarySupportStaySeparateFromTextRows() {
    let rename = ProjectEditorDiffModel.calculate(
      old: input(id: "old", path: "old.swift", revision: 1, content: "old"),
      new: input(
        id: "new",
        path: "new.swift",
        revision: 2,
        content: "new",
        renameFrom: "old.swift",
        renameTo: "new.swift"
      )
    )
    XCTAssertEqual(rename.metadata.renameFrom, "old.swift")
    XCTAssertEqual(rename.metadata.renameTo, "new.swift")
    XCTAssertFalse(rename.metadata.isBinary)
    XCTAssertFalse(rename.rows.isEmpty)

    let binary = ProjectEditorDiffModel.calculate(
      old: input(id: "old", path: "asset", revision: 1, content: nil, isBinary: true),
      new: input(id: "new", path: "asset", revision: 2, content: nil, isBinary: true)
    )
    XCTAssertTrue(binary.isBinary)
    XCTAssertTrue(binary.rows.isEmpty)
    XCTAssertNotNil(binary.metadata.unsupportedReason)
  }

  func testCoordinatorCanCancelAndReturnsCurrentRevisionResult() async {
    let coordinator = ProjectEditorDiffCoordinator()
    await coordinator.cancel()
    let result = await coordinator.calculate(
      old: input(id: "old", path: "a", revision: 1, content: "a"),
      new: input(id: "new", path: "a", revision: 2, content: "b")
    )

    XCTAssertEqual(result?.oldRevision, 1)
    XCTAssertEqual(result?.newRevision, 2)
  }

  func testTenThousandLineDiffRunsInBackgroundWithTwoThousandReplacements() async {
    let oldContent = makeLargeDocument(changed: false)
    let newContent = makeLargeDocument(changed: true)
    let coordinator = ProjectEditorDiffCoordinator()
    let startedAt = Date()

    let result = await coordinator.calculate(
      old: input(id: "large", path: "large.txt", revision: 10, content: oldContent),
      new: input(id: "large", path: "large.txt", revision: 11, content: newContent)
    )

    let elapsed = Date().timeIntervalSince(startedAt)
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.reconstructOldSource(), oldContent)
    XCTAssertEqual(result?.reconstructNewSource(), newContent)
    XCTAssertEqual(result?.rows.filter { $0.kind == .replaced }.count, 2_000)
    XCTAssertLessThan(elapsed, 10, "10,000-line / 2,000-replacement diff took \(elapsed)s")
  }

  func testCoordinatorDiscardsAStaleCalculationAfterCancellation() async {
    let coordinator = ProjectEditorDiffCoordinator()
    let firstOld = input(
      id: "first",
      path: "a.txt",
      revision: 1,
      content: makeLargeDocument(changed: false)
    )
    let firstNew = input(
      id: "first",
      path: "a.txt",
      revision: 2,
      content: makeLargeDocument(changed: true)
    )
    let first = Task {
      await coordinator.calculate(old: firstOld, new: firstNew)
    }

    try? await Task.sleep(nanoseconds: 1_000_000)
    await coordinator.cancel()

    let staleResult = await first.value
    XCTAssertNil(staleResult)
  }

  private func input(
    id: String,
    path: String,
    revision: UInt64,
    content: String?,
    isBinary: Bool = false,
    renameFrom: String? = nil,
    renameTo: String? = nil
  ) -> ProjectEditorDiffInput {
    ProjectEditorDiffInput(
      documentID: id,
      path: path,
      revision: revision,
      content: content,
      isBinary: isBinary,
      renameFrom: renameFrom,
      renameTo: renameTo
    )
  }

  private func makeLargeDocument(changed: Bool) -> String {
    let lines = (0..<10_000).map { index in
      changed && index < 2_000 ? "changed-\(index)" : "line-\(index)"
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

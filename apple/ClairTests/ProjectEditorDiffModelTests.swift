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

  func testLargeDiffBenchmark() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["CLAIR_RUN_BENCHMARKS"] == "1",
      "Run make benchmark-diff for the large-input measurement.")
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
    print("diff benchmark: 10,000 lines / 2,000 replacements, \(elapsed)s")
  }

  func testCoordinatorDiscardsCancelledResultAndAcceptsNextRevision() async {
    let gate = DiffCalculationGate()
    let coordinator = ProjectEditorDiffCoordinator { old, new, contextLines in
      if old.documentID == "first" { await gate.pause() }
      return ProjectEditorDiffModel.calculate(old: old, new: new, contextLines: contextLines)
    }
    let old = input(id: "first", path: "a", revision: 1, content: "a")
    let new = input(id: "first", path: "a", revision: 2, content: "b")
    let first = Task { await coordinator.calculate(old: old, new: new) }
    await gate.waitUntilStarted()
    await coordinator.cancel()
    await gate.resume()
    let stale = await first.value
    XCTAssertNil(stale)

    let current = await coordinator.calculate(
      old: input(id: "next", path: "a", revision: 2, content: "b"),
      new: input(id: "next", path: "a", revision: 3, content: "c")
    )
    XCTAssertEqual(current?.oldRevision, 2)
    XCTAssertEqual(current?.newRevision, 3)
    XCTAssertEqual(current?.reconstructNewSource(), "c")
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

private actor DiffCalculationGate {
  private var started = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var completion: CheckedContinuation<Void, Never>?

  func pause() async {
    started = true
    startWaiter?.resume()
    startWaiter = nil
    await withCheckedContinuation { completion = $0 }
  }

  func waitUntilStarted() async {
    if !started {
      await withCheckedContinuation { startWaiter = $0 }
    }
  }

  func resume() {
    completion?.resume()
    completion = nil
  }
}

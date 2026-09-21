import ClairEditorFixtures
import ClairReview
import Foundation
import XCTest

@testable import ClairEditorCore

/// `E10`: the editor integration gate. `E02`-`E09` each tested one layer in
/// isolation (storage, transactions, search, review) — this wires them into one
/// document and exercises edit, multi-cursor, search/replace, review, save, and
/// external agent edit together, on both the small-document correctness axis and
/// the 10MB/long-line performance axis from `../../../../docs/clair-spec.md`.
///
/// Every place below that calls `EditorTransactionManager.apply`/`applyExternal`
/// directly (not through `ReviewThreadManager`) also calls `reviews.rebase(through:)`
/// right after. That pairing is the integration contract a future host (the Mac/iOS
/// view, `U05`) must also follow: `ReviewThreadManager` only rebases automatically
/// for its own `applySuggestion`/`partiallyApplySuggestion`/`undoSuggestionApply`.
final class EditorIntegrationGateTests: XCTestCase {
  private let human = ReviewAuthor(displayName: "Ada", kind: .human)

  // MARK: - Functional gate

  func testEditMultiCursorSearchReplaceReviewSaveAndExternalEditPipeline() throws {
    let buffer = try TextBuffer("let a = 1\nlet b = 2\nlet c = 3\n")
    let transactions = EditorTransactionManager(
      buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    let reviews = ReviewThreadManager()

    // 1. A plain single edit.
    try transactions.apply([TextEdit(range: editorTextRange(8, 9), replacement: "10")])
    reviews.rebase(through: transactions.lastCommittedEdits)
    XCTAssertEqual(buffer.snapshot.string(), "let a = 10\nlet b = 2\nlet c = 3\n")

    // 2. Multi-cursor edit: every `let ` becomes `var ` in one undo unit.
    // `BASE-CE-011` recorded the CodeEdit PoC needing 3 separate Undo presses
    // for one multi-cursor gesture; this pipeline must need exactly 1.
    let occurrences = try TextSearch.find(.literal("let "), in: buffer.snapshot)
    XCTAssertEqual(occurrences.count, 3)
    try transactions.apply(occurrences.map { TextEdit(range: $0.range, replacement: "var ") })
    reviews.rebase(through: transactions.lastCommittedEdits)
    XCTAssertEqual(buffer.snapshot.string(), "var a = 10\nvar b = 2\nvar c = 3\n")

    XCTAssertTrue(transactions.canUndo)
    try transactions.undo()
    reviews.rebase(through: transactions.lastCommittedEdits)
    XCTAssertEqual(
      buffer.snapshot.string(), "let a = 10\nlet b = 2\nlet c = 3\n",
      "one undo must revert the whole 3-cursor batch, not one cursor at a time")
    try transactions.redo()
    reviews.rebase(through: transactions.lastCommittedEdits)
    XCTAssertEqual(buffer.snapshot.string(), "var a = 10\nvar b = 2\nvar c = 3\n")

    // 3. A review thread anchored to line 1, which nothing below edits again:
    // it must stay `.attached` through every later step.
    let line1Range = try buffer.snapshot.line(at: TextLineIndex(0)).contentRange
    reviews.addThread(author: human, body: "why 10?", anchor: ReviewAnchor(range: line1Range))

    // 4. A pending AI suggestion anchored to line 2, created now, and a review
    // thread anchored to the very same range (to observe what happens to a
    // sibling comment once the suggestion on that range is later applied).
    let line2Range = try buffer.snapshot.line(at: TextLineIndex(1)).contentRange
    let staleSuggestion = reviews.addSuggestion(
      hunks: [
        ReviewSuggestionHunk(anchor: ReviewAnchor(range: line2Range), replacement: "var b = 20")
      ],
      description: "widen b", baseRevision: buffer.snapshot.revision)
    reviews.addThread(
      author: human, body: "should this be let?", anchor: ReviewAnchor(range: line2Range))

    // ...and then an unrelated search/replace scoped to line 3 moves the
    // document to a new revision before the suggestion is ever applied.
    let line3Range = try buffer.snapshot.line(at: TextLineIndex(2)).contentRange
    let line3Scope = try TextSelectionSet([
      TextSelection(anchor: line3Range.lowerBound, head: line3Range.upperBound)
    ])
    let replacements = try TextSearch.preview(
      .literal("3"), replacingWith: "30", in: buffer.snapshot, scope: line3Scope)
    XCTAssertEqual(replacements.count, 1)
    try transactions.apply(replacements: replacements)
    reviews.rebase(through: transactions.lastCommittedEdits)
    XCTAssertEqual(buffer.snapshot.string(), "var a = 10\nvar b = 2\nvar c = 30\n")
    XCTAssertEqual(
      reviews.threads[0].anchor?.state, .attached, "line 1's thread is untouched by a line-3 edit")
    XCTAssertEqual(
      reviews.threads[1].anchor?.state, .attached,
      "line 2's thread is also untouched by a line-3 edit")

    // 5. `INV-REV-004` must hold across the whole pipeline, not just inside
    // one component's own unit tests: a suggestion whose base revision is
    // behind the live document is rejected outright rather than silently
    // reapplied against text it no longer describes.
    XCTAssertThrowsError(try reviews.applySuggestion(id: staleSuggestion.id, in: transactions)) {
      error in
      XCTAssertEqual(error as? ReviewThreadManagerError, .suggestionRevisionMismatch)
    }

    // A fresh suggestion at the current revision applies cleanly, and —
    // because its hunk exactly covers the same range as the sibling review
    // thread on line 2 — that thread's anchor is orphaned by the full-range
    // replacement (the same rule `ReviewAnchor` already applies to any other
    // full overlap).
    let freshLine2Range = try buffer.snapshot.line(at: TextLineIndex(1)).contentRange
    let suggestion = reviews.addSuggestion(
      hunks: [
        ReviewSuggestionHunk(
          anchor: ReviewAnchor(range: freshLine2Range), replacement: "var b = 20")
      ],
      description: "widen b", baseRevision: buffer.snapshot.revision)
    try reviews.applySuggestion(id: suggestion.id, in: transactions)
    XCTAssertEqual(buffer.snapshot.string(), "var a = 10\nvar b = 20\nvar c = 30\n")
    XCTAssertEqual(reviews.threads[0].anchor?.state, .attached, "line 1's thread still untouched")
    XCTAssertEqual(
      reviews.threads[1].anchor?.state, .orphaned,
      "the line-2 thread's range was fully replaced by the applied suggestion")

    // 6. Save: an explicit, streaming materialization boundary — never a
    // second full in-memory copy via `.string()` twice — then a round trip
    // through disk reproduces the exact bytes.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("Example.swift")
    var saved = Data()
    buffer.snapshot.forEachTextChunk { saved.append(contentsOf: $0.utf8) }
    try saved.write(to: fileURL, options: .atomic)
    XCTAssertEqual(try Data(contentsOf: fileURL), Data(buffer.snapshot.string().utf8))

    // 7. External agent edit: another process appends a line straight to the
    // saved file; the host reconciles it as a single insertion at EOF, which
    // must rebase every open anchor and the undo stack, but must not itself
    // become an undo unit (it is not a user action).
    let externalAddition = "var d = 4\n"
    saved.append(contentsOf: externalAddition.utf8)
    try saved.write(to: fileURL, options: .atomic)
    let eof = UTF8Offset(buffer.snapshot.utf8Count)
    try transactions.applyExternal([
      TextEdit(range: TextUTF8Range(eof, eof), replacement: externalAddition)
    ])
    reviews.rebase(through: transactions.lastCommittedEdits)
    XCTAssertEqual(buffer.snapshot.string(), "var a = 10\nvar b = 20\nvar c = 30\nvar d = 4\n")
    XCTAssertEqual(reviews.threads[0].anchor?.state, .attached)
    XCTAssertEqual(
      reviews.threads[1].anchor?.state, .orphaned, "INV-RVW-004: an orphaned anchor never reverts")

    // Undo must still target the last real user edit (the suggestion apply)
    // and skip straight over the external insert, proving the external edit
    // truly never entered the undo stack. This also exercises the regression
    // this task fixed in `EditorTransactionManager.rebase`: `applyExternal`
    // used to silently drop every pending undo entry's label, which made
    // `undoSuggestionApply` permanently unusable for any suggestion applied
    // before an external edit arrived.
    try reviews.undoSuggestionApply(id: suggestion.id, in: transactions)
    XCTAssertEqual(buffer.snapshot.string(), "var a = 10\nvar b = 2\nvar c = 30\nvar d = 4\n")
  }

  // MARK: - Performance gate

  /// This is `E01`'s harness and recorded failure ceilings, reused exactly as
  /// `EditorTextPerformanceTests` does for storage alone, but pushed through the
  /// same transaction+review pipeline the functional test above exercises.
  func testTenMegabyteFixtureEditSearchSaveStayWellBelowRecordedPoCFailures() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try XCTUnwrap(
      EditorFixtureGenerator.canonicalFixtures.first { $0.name == "10mb" })
    let sourceURL = try EditorFixtureGenerator.generate(fixture, into: directory)
    let originalText = try String(contentsOf: sourceURL, encoding: .utf8)

    let probe = try EditorIntegrationProbe(text: originalText)

    // A review comment far from every edit below (line 100 of ~200,000): an
    // anchor at a distance must survive untouched and unmoved in content.
    let observedLine = try await probe.line(at: 100)
    let originalObservedText = observedLine.text
    await probe.addThread(
      author: human, body: "trailing note", anchor: ReviewAnchor(range: observedLine.range))

    // 1. A single localized edit at the very start must resegment only a
    // small, bounded amount of text (`E02`'s own proof, repeated through the
    // full transaction+review pipeline instead of a raw `TextBuffer.replace`).
    try await probe.apply([TextEdit(range: editorTextRange(0, 0), replacement: "// header\n")])
    let workAfterHeaderEdit = await probe.lastResegmentedUTF8
    XCTAssertLessThan(
      workAfterHeaderEdit, 10 * TextRopeBuilder.leafTarget,
      "a localized edit must not resegment the whole 10MB document")

    // 2. Full-document search, a transacted replace, and a disk save in one
    // measurement. `BASE-CM-001` recorded 2997.26 ms just to hand a 10MB
    // document across the WKWebView bridge once; this does strictly more work
    // per iteration and must still land well under that single-operation
    // baseline.
    let ceiling = try XCTUnwrap(
      EditorBaselineEvidence.regressionCeiling(
        fixture: "10mb.swift", metric: "set_document_round_trip"))
    let savedURL = directory.appendingPathComponent("10mb-saved.swift")
    let operation = EditorBenchmark.Operation(
      name: "search+replace+save", fixture: "10mb", iterations: 3
    ) {
      let snapshot = await probe.snapshot()
      let matches = try TextSearch.find(.literal("example_00000001"), in: snapshot)
      if !matches.isEmpty {
        try await probe.apply(
          matches.map { TextEdit(range: $0.range, replacement: "renamed_00000001") })
      }
      try await probe.save(to: savedURL)
    }
    let result = try await EditorBenchmark.run(operation)
    EditorBenchmark.print(result)
    XCTAssertLessThan(Double(result.medianNanos) / 1_000_000, ceiling)
    XCTAssertLessThan(
      Double(EditorBenchmark.currentMaxRSS()) / (1024 * 1024), 1077.7,
      "must beat BASE-CE-002's cumulative RSS failure")

    // 3. What actually landed on disk is exactly the live in-memory content.
    let reloaded = try Data(contentsOf: savedURL)
    var expected = Data()
    (await probe.snapshot()).forEachTextChunk { expected.append(contentsOf: $0.utf8) }
    XCTAssertEqual(reloaded, expected)

    // 4. External agent edit at EOF must stay just as local as a normal one,
    // and the distant review anchor must still point at its original text.
    let eof = UTF8Offset((await probe.snapshot()).utf8Count)
    try await probe.applyExternal([
      TextEdit(range: TextUTF8Range(eof, eof), replacement: "// agent appended\n")
    ])
    let workAfterExternalEdit = await probe.lastResegmentedUTF8
    XCTAssertLessThan(workAfterExternalEdit, 10 * TextRopeBuilder.leafTarget)
    let stateAfterExternalEdit = await probe.threadAnchorState(0)
    XCTAssertEqual(stateAfterExternalEdit, .attached)
    let textUnderAnchorAfterExternalEdit = try await probe.textUnderThreadAnchor(0)
    XCTAssertEqual(textUnderAnchorAfterExternalEdit, originalObservedText)
  }

  /// `BASE-CE-004`/`005` recorded 684.86/693.29 ms per keystroke on a 1 MiB
  /// single line. Mirrors that scenario, but every "keystroke" is a full
  /// `apply` + review-rebase, the same shape an `NSTextInputClient`/
  /// `UITextInput` marked-text commit (`E07`/`E08`) drives per commit.
  func testLongLineFixtureEditsThroughFullPipelineStayFastAndLocal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try XCTUnwrap(
      EditorFixtureGenerator.canonicalFixtures.first { $0.name == "long-line" })
    let url = try EditorFixtureGenerator.generate(fixture, into: directory)
    let text = try String(contentsOf: url, encoding: .utf8)

    let probe = try EditorIntegrationProbe(text: text)
    await probe.addThread(
      author: human, body: "start", anchor: ReviewAnchor(range: editorTextRange(0, 1)))

    // The fixture is pure ASCII, so any single byte is a full grapheme.
    let midpoint = text.utf8.count / 2
    let range = editorTextRange(midpoint, midpoint + 1)
    let operation = EditorBenchmark.Operation(
      name: "IME-style commit", fixture: "long-line", iterations: 20
    ) {
      try await probe.applyToggled(range)
    }
    let result = try await EditorBenchmark.run(operation)
    EditorBenchmark.print(result)

    let medianCeiling = try XCTUnwrap(
      EditorBaselineEvidence.regressionCeiling(fixture: "long-line.ts", metric: "keystroke_median"))
    let p95Ceiling = try XCTUnwrap(
      EditorBaselineEvidence.regressionCeiling(fixture: "long-line.ts", metric: "keystroke_p95"))
    XCTAssertLessThan(Double(result.medianNanos) / 1_000_000, medianCeiling)
    XCTAssertLessThan(Double(result.p95Nanos) / 1_000_000, p95Ceiling)
    let lastResegmentedUTF8 = await probe.lastResegmentedUTF8
    XCTAssertLessThan(lastResegmentedUTF8, 10 * TextRopeBuilder.leafTarget)
    let finalThreadState = await probe.threadAnchorState(0)
    XCTAssertEqual(
      finalThreadState, .attached,
      "an anchor at the start of a 1MB single line must be untouched by an edit at its midpoint")
  }
}

/// Owns one document's transaction manager and review manager on a single
/// actor, the way a real host must (both types document that they are not
/// `Sendable` and must live on one serial context). Lets an `EditorBenchmark`
/// `@Sendable` closure drive them without violating that contract, exactly as
/// `EditorTextPerformanceProbe` does for storage alone in
/// `EditorTextPerformanceTests.swift`.
private actor EditorIntegrationProbe {
  private let buffer: TextBuffer
  private let transactions: EditorTransactionManager
  private let reviews: ReviewThreadManager
  private var toggle = false

  init(text: String) throws {
    buffer = try TextBuffer(text)
    transactions = EditorTransactionManager(
      buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    reviews = ReviewThreadManager()
  }

  func addThread(author: ReviewAuthor, body: String, anchor: ReviewAnchor) {
    reviews.addThread(author: author, body: body, anchor: anchor)
  }

  @discardableResult
  func apply(_ edits: [TextEdit]) throws -> TextSnapshot {
    let snapshot = try transactions.apply(edits)
    reviews.rebase(through: transactions.lastCommittedEdits)
    return snapshot
  }

  @discardableResult
  func applyExternal(_ edits: [TextEdit]) throws -> TextSnapshot {
    let snapshot = try transactions.applyExternal(edits)
    reviews.rebase(through: transactions.lastCommittedEdits)
    return snapshot
  }

  @discardableResult
  func applyToggled(_ range: TextUTF8Range) throws -> TextSnapshot {
    toggle.toggle()
    return try apply([TextEdit(range: range, replacement: toggle ? "X" : "Y")])
  }

  func snapshot() -> TextSnapshot { buffer.snapshot }
  var lastResegmentedUTF8: Int { buffer.lastEditWork.resegmentedUTF8 }
  func threadAnchorState(_ index: Int) -> ReviewAnchorState? {
    reviews.threads[index].anchor?.state
  }

  func textUnderThreadAnchor(_ index: Int) throws -> String? {
    guard let anchor = reviews.threads[index].anchor else { return nil }
    return try buffer.snapshot.text(in: anchor.range)
  }

  func line(at index: Int) throws -> (range: TextUTF8Range, text: String) {
    let line = try buffer.snapshot.line(at: TextLineIndex(index))
    return (line.contentRange, try buffer.snapshot.text(in: line.contentRange))
  }

  func save(to url: URL) throws {
    var data = Data()
    buffer.snapshot.forEachTextChunk { data.append(contentsOf: $0.utf8) }
    try data.write(to: url, options: .atomic)
  }
}

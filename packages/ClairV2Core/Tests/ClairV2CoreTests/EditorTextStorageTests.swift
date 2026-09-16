import ClairV2EditorFixtures
import XCTest

@testable import ClairV2EditorCore

final class EditorTextStorageTests: XCTestCase {
  func testStableLineIDsFollowSurvivingBreaksThroughSplitAndJoin() throws {
    let buffer = try TextBuffer("one\ntwo\r\nthree\u{2028}")
    let original = buffer.snapshot
    let ids = try lineIDs(original)
    try buffer.replace(editorTextRange(5, 6), with: "W", basedOn: buffer.snapshot.revision)
    XCTAssertEqual(try lineIDs(buffer.snapshot), ids)
    try buffer.replace(editorTextRange(1, 1), with: "\nnew", basedOn: buffer.snapshot.revision)
    let split = try lineIDs(buffer.snapshot)
    XCTAssertEqual(split[0], ids[0])
    XCTAssertFalse(ids.contains(split[1]))
    XCTAssertEqual(Array(split.dropFirst(2)), Array(ids.dropFirst()))
    try buffer.replace(editorTextRange(1, 2), with: "", basedOn: buffer.snapshot.revision)
    XCTAssertEqual(try lineIDs(buffer.snapshot), ids)
    try buffer.replace(
      buffer.snapshot.fullRange, with: "\nreplacement\n", basedOn: buffer.snapshot.revision)
    let replacement = try lineIDs(buffer.snapshot)
    XCTAssertEqual(replacement[0], ids[0])
    XCTAssertTrue(Set(replacement.dropFirst()).isDisjoint(with: ids + split))
    XCTAssertEqual(try lineIDs(original), ids)
    XCTAssertEqual(original.string(), "one\ntwo\r\nthree\u{2028}")
  }

  func testCRLFFusionKeepsExistingIdentityBeforeNewIdentity() throws {
    for (text, range, insertion, expected) in [
      ("a\nb", editorTextRange(1, 1), "\r", "a\r\nb"),
      ("a\rb", editorTextRange(2, 2), "\n", "a\r\nb"),
      ("a\rX\nb", editorTextRange(2, 3), "", "a\r\nb"),
    ] {
      let buffer = try TextBuffer(text)
      let old = buffer.snapshot
      let surviving = try old.line(at: TextLineIndex(1)).id
      try buffer.replace(range, with: insertion, basedOn: old.revision)
      try assertEditorTextEquivalent(buffer.snapshot, expected)
      XCTAssertEqual(try buffer.snapshot.line(at: TextLineIndex(1)).id, surviving)
      XCTAssertEqual(try old.line(at: TextLineIndex(1)).id, surviving)
    }
  }

  func testNoOpsFailuresAndForeignRevisionsNeverAdvanceOrPartiallyMutate() throws {
    let buffer = try TextBuffer("a👨‍👩‍👧‍👦\r\ne\u{301}")
    let before = buffer.snapshot
    let ids = try lineIDs(before)
    try buffer.replace(before.fullRange, with: before.string(), basedOn: before.revision)
    try buffer.replace(editorTextRange(0, 0), with: "", basedOn: before.revision)
    XCTAssertEqual(buffer.snapshot.revision, before.revision)
    XCTAssertTrue(buffer.snapshot.root === before.root)
    for range in [
      editorTextRange(-1, 0), editorTextRange(2, 2), editorTextRange(27, 27), editorTextRange(4, 1),
      editorTextRange(0, Int.max),
    ] {
      XCTAssertThrowsError(try buffer.replace(range, with: "bad\n", basedOn: before.revision))
      XCTAssertEqual(buffer.snapshot.revision, before.revision)
      XCTAssertEqual(try lineIDs(buffer.snapshot), ids)
      XCTAssertTrue(buffer.snapshot.root === before.root)
    }
    let foreign = try TextBuffer(before.string()).snapshot.revision
    XCTAssertNotEqual(foreign, before.revision)
    XCTAssertThrowsError(try buffer.replace(before.fullRange, with: "", basedOn: foreign)) {
      XCTAssertEqual($0 as? TextStorageError, .staleRevision)
    }
    try buffer.replace(editorTextRange(0, 1), with: "A", basedOn: before.revision)
    XCTAssertEqual(buffer.snapshot.revision.sequence, 1)
    XCTAssertLessThan(before.revision, buffer.snapshot.revision)
    XCTAssertThrowsError(
      try buffer.replace(editorTextRange(0, 1), with: "B", basedOn: before.revision)
    ) {
      XCTAssertEqual($0 as? TextStorageError, .staleRevision)
    }
    XCTAssertEqual(buffer.snapshot.string(), "A👨‍👩‍👧‍👦\r\ne\u{301}")
    XCTAssertEqual(before.string(), "a👨‍👩‍👧‍👦\r\ne\u{301}")
  }

  func testDeletingEachE01GraphemeRemovesExactlyOneVisibleCharacter() throws {
    for text in UnicodeCorpus.deleteBoundaryCases {
      let buffer = try TextBuffer("a" + text + "z")
      let start = try buffer.snapshot.convert(GraphemeOffset(1), to: UTF8Unit.self)
      let end = try buffer.snapshot.convert(GraphemeOffset(2), to: UTF8Unit.self)
      try buffer.replace(TextUTF8Range(start, end), with: "", basedOn: buffer.snapshot.revision)
      XCTAssertEqual(buffer.snapshot.string(), "az")
    }
  }

  func testRetainedSnapshotsCanBeReadAcrossTasksDuringEdits() async throws {
    let buffer = try TextBuffer(UnicodeCorpus.concatenated)
    let before = buffer.snapshot
    let reader = Task.detached {
      for _ in 0..<100 {
        try assertEditorTextEquivalent(before, UnicodeCorpus.concatenated)
      }
    }
    for _ in 0..<100 {
      try buffer.replace(editorTextRange(0, 0), with: "x\n", basedOn: buffer.snapshot.revision)
    }
    try await reader.value
    XCTAssertEqual(buffer.snapshot.revision.sequence, 100)
    XCTAssertEqual(before.revision.sequence, 0)
  }

  private func lineIDs(_ snapshot: TextSnapshot) throws -> [TextLineID] {
    try (0..<snapshot.lineCount).map { try snapshot.line(at: TextLineIndex($0)).id }
  }
}

final class EditorTextSeamTests: XCTestCase {
  func testUnicodeSeamsAndUnboundedRegionalIndicatorPropagation() throws {
    let padding = String(repeating: "a", count: 2_048)
    let cases: [(String, TextUTF8Range, String)] = [
      (padding + "\nb", editorTextRange(2_048, 2_048), "\r"),
      (padding + "b", editorTextRange(2_048, 2_048), "\u{301}"),
      (padding + "👩💻z", editorTextRange(2_052, 2_052), "\u{200D}"),
      (padding + "\u{600}a", editorTextRange(2_048, 2_048), "\u{600}"),
      (padding + "कष", editorTextRange(2_051, 2_051), "्‍"),
      (padding + String(repeating: "🇯🇵", count: 2_000) + "z", editorTextRange(2_048, 2_048), "🇺"),
      (padding + String(repeating: "🇯🇵", count: 2_000) + "z", editorTextRange(2_048, 2_056), "🇺"),
      (padding + "\rX\nb", editorTextRange(2_049, 2_050), ""),
    ]
    for (text, range, inserted) in cases {
      let buffer = try TextBuffer(text)
      let old = buffer.snapshot
      var expected = Array(text.utf8)
      expected.replaceSubrange(range.lowerBound.value..<range.upperBound.value, with: inserted.utf8)
      let oracle = try XCTUnwrap(String(bytes: expected, encoding: .utf8))
      try buffer.replace(range, with: inserted, basedOn: old.revision)
      try assertEditorTextEquivalent(buffer.snapshot, oracle)
      XCTAssertEqual(Array(old.string().utf8), Array(text.utf8))
    }
  }

  func testSingleGraphemeLargerThanLeafBudgetRemainsIndivisible() throws {
    let huge = "e" + String(repeating: "\u{301}", count: 8_192)
    let buffer = try TextBuffer("x" + huge + "y\n")
    XCTAssertEqual(buffer.snapshot.graphemeCount, 4)
    XCTAssertThrowsError(try buffer.snapshot.convert(UTF8Offset(2), to: UTF16Unit.self))
    try buffer.replace(editorTextRange(1, 1), with: "\u{600}", basedOn: buffer.snapshot.revision)
    try assertEditorTextEquivalent(buffer.snapshot, "x\u{600}" + huge + "y\n")
  }

  func testManySmallEditsPreserveAVLBalanceAndShareUntouchedLeaves() throws {
    let text = String(repeating: "0123456789\n", count: 2_000)
    let buffer = try TextBuffer(text)
    let before = buffer.snapshot
    let oldLeaves = leaves(before.root)
    var expected = text
    var random = EditorTextRandom(state: 29)
    for iteration in 0..<600 {
      let start = random.next(expected.utf8.count + 1)
      let inserted = iteration.isMultiple(of: 7) ? "\n" : "x"
      let index = expected.utf8.index(expected.startIndex, offsetBy: start)
      expected.insert(contentsOf: inserted, at: index)
      try buffer.replace(
        editorTextRange(start, start), with: inserted, basedOn: buffer.snapshot.revision)
      _ = assertEditorTextTree(buffer.snapshot.root)
    }
    try assertEditorTextEquivalent(buffer.snapshot, expected, checkCoordinates: false)
    XCTAssertEqual(before.string(), text)
    let local = try TextBuffer(String(repeating: "abc\n", count: 20_000))
    let localBefore = local.snapshot
    let originalLeaves = leaves(localBefore.root)
    try local.replace(editorTextRange(20_000, 20_001), with: "X", basedOn: local.snapshot.revision)
    XCTAssertGreaterThan(
      originalLeaves.intersection(leaves(local.snapshot.root)).count, originalLeaves.count - 5)
    XCTAssertLessThan(local.lastEditWork.resegmentedUTF8, 10 * TextRopeBuilder.leafTarget)
    XCTAssertGreaterThan(oldLeaves.count, 1)
  }

  private func leaves(_ node: TextNode?) -> Set<ObjectIdentifier> {
    guard let node else { return [] }
    if node.leaf != nil { return [ObjectIdentifier(node)] }
    return leaves(node.left).union(leaves(node.right))
  }
}

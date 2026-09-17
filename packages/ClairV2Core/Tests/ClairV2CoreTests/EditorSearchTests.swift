import XCTest

@testable import ClairV2EditorCore

final class EditorSearchTests: XCTestCase {
  func testLiteralSearchFindsAllNonOverlappingMatches() throws {
    let buffer = try TextBuffer("foo bar foo baz foo")
    let matches = try TextSearch.find(.literal("foo"), in: buffer.snapshot)
    XCTAssertEqual(matches.count, 3)
    XCTAssertEqual(matches.map { try! buffer.snapshot.text(in: $0.range) }, ["foo", "foo", "foo"])
    XCTAssertEqual(matches.map(\.range.lowerBound.value), [0, 8, 16])
  }

  func testLiteralSearchIsCaseSensitiveByDefault() throws {
    let buffer = try TextBuffer("Foo foo FOO")
    let sensitive = try TextSearch.find(.literal("foo"), in: buffer.snapshot)
    XCTAssertEqual(sensitive.count, 1)
    let insensitive = try TextSearch.find(
      .literal("foo", caseSensitive: false), in: buffer.snapshot)
    XCTAssertEqual(insensitive.count, 3)
  }

  func testRegexSearchMatchesPattern() throws {
    let buffer = try TextBuffer("a1 b22 c333")
    let matches = try TextSearch.find(.regex(#"[a-z]\d+"#), in: buffer.snapshot)
    XCTAssertEqual(matches.map { try! buffer.snapshot.text(in: $0.range) }, ["a1", "b22", "c333"])
  }

  func testInvalidRegexThrows() {
    let buffer = try! TextBuffer("abc")
    XCTAssertThrowsError(try TextSearch.find(.regex("("), in: buffer.snapshot)) {
      XCTAssertEqual($0 as? SearchError, .invalidRegex)
    }
  }

  func testZeroLengthRegexTerminatesWithNonOverlappingMatches() throws {
    let buffer = try TextBuffer("aXbXXc")
    // Matches every run of "X" plus the empty gaps between other characters,
    // without hanging or producing overlapping/duplicate ranges.
    let matches = try TextSearch.find(.regex("X*"), in: buffer.snapshot)
    XCTAssertFalse(matches.isEmpty)
    for index in 1..<matches.count {
      XCTAssertLessThanOrEqual(
        matches[index - 1].range.upperBound.value, matches[index].range.lowerBound.value)
    }
    XCTAssertTrue(matches.contains { try! buffer.snapshot.text(in: $0.range) == "X" })
    XCTAssertTrue(matches.contains { try! buffer.snapshot.text(in: $0.range) == "XX" })
  }

  func testMatchNeverSplitsAGraphemeCluster() throws {
    // "e" + COMBINING ACUTE ACCENT is one grapheme ("é") stored as two scalars;
    // a raw regex match on the bare "e" scalar must snap out to the whole
    // cluster instead of landing between the base letter and its accent.
    let buffer = try TextBuffer("e\u{0301}bc")
    let matches = try TextSearch.find(.literal("e"), in: buffer.snapshot)
    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(try buffer.snapshot.text(in: matches[0].range), "e\u{0301}")
  }

  func testSelectionScopeRestrictsSearchToNonEmptySelections() throws {
    let buffer = try TextBuffer("foo foo foo")
    let scope = try TextSelectionSet([
      TextSelection(anchor: UTF8Offset(4), head: UTF8Offset(7))
    ])
    let matches = try TextSearch.find(.literal("foo"), in: buffer.snapshot, scope: scope)
    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(matches[0].range.lowerBound.value, 4)
  }

  func testCursorOnlyScopeSearchesWholeDocument() throws {
    let buffer = try TextBuffer("foo foo")
    let scope = TextSelectionSet(cursor: UTF8Offset(0))
    let matches = try TextSearch.find(.literal("foo"), in: buffer.snapshot, scope: scope)
    XCTAssertEqual(matches.count, 2)
  }

  func testReplaceOneAppliesAsSingleUndoUnit() throws {
    let buffer = try TextBuffer("foo bar foo")
    let manager = EditorTransactionManager(buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    let matches = try TextSearch.find(.literal("foo"), in: buffer.snapshot)
    try manager.apply(replacements: [SearchReplacement(match: matches[0], replacement: "FOO")])
    XCTAssertEqual(buffer.snapshot.string(), "FOO bar foo")
    try manager.undo()
    XCTAssertEqual(buffer.snapshot.string(), "foo bar foo")
  }

  func testReplaceAllAppliesEveryMatchAsOneUndoUnit() throws {
    let buffer = try TextBuffer("foo bar foo baz foo")
    let manager = EditorTransactionManager(buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    let replacements = try TextSearch.preview(.literal("foo"), replacingWith: "FOO", in: buffer.snapshot)
    try manager.apply(replacements: replacements)
    XCTAssertEqual(buffer.snapshot.string(), "FOO bar FOO baz FOO")
    XCTAssertTrue(manager.canUndo)
    try manager.undo()
    XCTAssertEqual(buffer.snapshot.string(), "foo bar foo baz foo")
  }

  func testStaleMatchIsRejectedNotReapplied() throws {
    let buffer = try TextBuffer("foo bar")
    let manager = EditorTransactionManager(buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    let matches = try TextSearch.find(.literal("foo"), in: buffer.snapshot)
    // Advance the buffer past the revision the match was computed against.
    try manager.apply([TextEdit(range: editorTextRange(0, 0), replacement: "X")])
    XCTAssertThrowsError(
      try manager.apply(replacements: [SearchReplacement(match: matches[0], replacement: "FOO")])
    ) {
      XCTAssertEqual($0 as? TextStorageError, .staleRevision)
    }
    XCTAssertEqual(buffer.snapshot.string(), "Xfoo bar")
  }
}

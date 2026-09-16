import ClairV2EditorCore
import ClairV2EditorFixtures
import XCTest

final class EditorTextCoordinateTests: XCTestCase {
  func testCorpusRoundTripsAllCoordinateSpacesAndLines() throws {
    for (_, text) in UnicodeCorpus.namedCases + [
      ("empty", ""), ("all-breaks", "a\rb\nc\r\nd\u{85}e\u{2028}f\u{2029}"),
      ("nul", "a\0b"), ("decomposed", "é/e\u{301}"),
      ("indic", "क्‍षक्ष"), ("prepend", "\u{600}a"),
    ] {
      try assertEditorTextEquivalent(TextBuffer(text).snapshot, text)
    }
  }

  func testEveryInteriorUnitRejectsOrExplicitlyRoundsOutward() throws {
    let text = UnicodeCorpus.concatenated + "\r\n\u{600}aक्‍ष"
    let snapshot = try TextBuffer(text).snapshot
    let boundaries = editorTextBoundaries(text)
    try assertRounding(
      snapshot, boundaries: boundaries.map(\.utf8), bytes: boundaries.map(\.utf8),
      unit: UTF8Unit.self)
    try assertRounding(
      snapshot, boundaries: boundaries.map(\.utf16), bytes: boundaries.map(\.utf8),
      unit: UTF16Unit.self)
    try assertRounding(
      snapshot, boundaries: boundaries.map(\.scalar), bytes: boundaries.map(\.utf8),
      unit: ScalarUnit.self)
    try assertRounding(
      snapshot, boundaries: boundaries.map(\.grapheme), bytes: boundaries.map(\.utf8),
      unit: GraphemeUnit.self)
  }

  private func assertRounding<Unit: TextCoordinateUnit>(
    _ snapshot: TextSnapshot, boundaries: [Int], bytes: [Int], unit: Unit.Type
  ) throws {
    for offset in 0...boundaries.last! {
      let coordinate = TextOffset<Unit>(offset)
      let lower = boundaries.lastIndex { $0 <= offset }!
      let upper = boundaries.firstIndex { $0 >= offset }!
      if lower == upper {
        XCTAssertEqual(try snapshot.convert(coordinate, to: UTF8Unit.self).value, bytes[lower])
      } else {
        XCTAssertThrowsError(try snapshot.convert(coordinate, to: UTF8Unit.self)) {
          XCTAssertEqual($0 as? TextStorageError, .invalidBoundary)
        }
      }
      XCTAssertEqual(
        try snapshot.convert(coordinate, to: UTF8Unit.self, rounding: .down).value, bytes[lower])
      XCTAssertEqual(
        try snapshot.convert(coordinate, to: UTF8Unit.self, rounding: .up).value, bytes[upper])
    }
    for invalid in [-1, Int.min, boundaries.last! + 1, Int.max] {
      for rounding: TextBoundaryRounding in [.strict, .down, .up] {
        XCTAssertThrowsError(
          try snapshot.convert(TextOffset<Unit>(invalid), to: UTF8Unit.self, rounding: rounding)
        ) {
          XCTAssertEqual($0 as? TextStorageError, .outOfBounds)
        }
      }
    }
  }

  func testLineColumnsExcludeTerminatorsAndValidateBeforeArithmetic() throws {
    let snapshot = try TextBuffer("👨‍👩‍👧‍👦\r\na\n").snapshot
    XCTAssertEqual(snapshot.lineCount, 3)
    let interior = TextLinePosition(line: TextLineIndex(0), column: UTF16Offset(2))
    XCTAssertThrowsError(try snapshot.offset(at: interior))
    XCTAssertEqual(try snapshot.offset(at: interior, rounding: .down), UTF8Offset(0))
    XCTAssertEqual(try snapshot.offset(at: interior, rounding: .up), UTF8Offset(25))
    for (line, column) in [(-1, 0), (3, 0), (0, -1), (0, 12), (1, 2), (2, 1), (1, Int.max)] {
      XCTAssertThrowsError(
        try snapshot.offset(
          at: TextLinePosition(line: TextLineIndex(line), column: UTF16Offset(column)))
      ) { XCTAssertEqual($0 as? TextStorageError, .outOfBounds) }
    }
  }

  func testRangesExpandWithoutSplittingCRLFCombiningOrEmoji() throws {
    let snapshot = try TextBuffer("e\u{301}\r\n👨‍👩‍👧‍👦").snapshot
    XCTAssertEqual(try snapshot.expandingToGraphemes(editorTextRange(1, 4)), editorTextRange(0, 5))
    XCTAssertEqual(try snapshot.expandingToGraphemes(editorTextRange(6, 6)), editorTextRange(5, 30))
    XCTAssertThrowsError(try snapshot.expandingToGraphemes(editorTextRange(5, 1))) {
      XCTAssertEqual($0 as? TextStorageError, .reversedRange)
    }
    XCTAssertThrowsError(try snapshot.text(in: editorTextRange(0, 1)))
    XCTAssertEqual(try snapshot.text(in: editorTextRange(3, 5)), "\r\n")
  }

  func testStrictUTF8LoadAndReplacementNeverNormalizeOrRepairBytes() throws {
    let valid = "\u{FEFF}é/e\u{301}/\u{FFFD}/\0/👩🏽‍💻"
    let buffer = try TextBuffer(utf8: Array(valid.utf8))
    XCTAssertEqual(Array(buffer.snapshot.string().utf8), Array(valid.utf8))
    let revision = buffer.snapshot.revision
    for invalid: [UInt8] in [
      [0x80], [0xC0, 0xAF], [0xE2, 0x82], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xFF],
    ] {
      XCTAssertThrowsError(try TextBuffer(utf8: invalid)) {
        XCTAssertEqual($0 as? TextStorageError, .invalidUTF8)
      }
      XCTAssertThrowsError(
        try buffer.replace(buffer.snapshot.fullRange, withUTF8: invalid, basedOn: revision))
      XCTAssertEqual(buffer.snapshot.revision, revision)
      XCTAssertEqual(Array(buffer.snapshot.string().utf8), Array(valid.utf8))
    }
    let normalized = try TextBuffer("é")
    try normalized.replace(
      normalized.snapshot.fullRange, with: "e\u{301}", basedOn: normalized.snapshot.revision)
    XCTAssertEqual(
      normalized.snapshot.revision.sequence, 1, "canonical equivalence is not byte equality")
    XCTAssertEqual(Array(normalized.snapshot.string().utf8), [0x65, 0xCC, 0x81])
    try normalized.replace(
      normalized.snapshot.fullRange, withUTF8: Array(valid.utf8),
      basedOn: normalized.snapshot.revision
    )
    XCTAssertEqual(Array(normalized.snapshot.string().utf8), Array(valid.utf8))
  }
}

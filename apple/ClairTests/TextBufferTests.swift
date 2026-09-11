import Foundation
import XCTest

@testable import ClairApp

final class TextBufferTests: XCTestCase {
  func testInvalidUTF8IsRejectedAndValidBytesLoad() throws {
    XCTAssertThrowsError(try TextBuffer(utf8: Data([0x61, 0xFF, 0x62]))) { error in
      XCTAssertEqual(error as? TextBufferError, .invalidUTF8)
    }
    XCTAssertThrowsError(try TextBuffer(utf8: Data([0xE6, 0x97]))) { error in
      XCTAssertEqual(error as? TextBufferError, .invalidUTF8)
    }

    let buffer = try TextBuffer(utf8: Data("ok 日本 🙂\n".utf8))
    XCTAssertEqual(buffer.content, "ok 日本 🙂\n")
    XCTAssertEqual(buffer.lineCount, 2)
  }

  func testByteAndUTF16OffsetsConvertBothWaysAndRejectSurrogateSplits() {
    let buffer = TextBuffer("a日🙂b")

    XCTAssertEqual(buffer.utf16Length, 5)
    XCTAssertEqual(buffer.byteLength, 9)
    XCTAssertEqual(buffer.byteOffset(forUTF16Offset: 0), 0)
    XCTAssertEqual(buffer.byteOffset(forUTF16Offset: 1), 1)
    XCTAssertEqual(buffer.byteOffset(forUTF16Offset: 2), 4)
    XCTAssertNil(buffer.byteOffset(forUTF16Offset: 3))
    XCTAssertEqual(buffer.byteOffset(forUTF16Offset: 4), 8)
    XCTAssertEqual(buffer.byteOffset(forUTF16Offset: 5), 9)
    XCTAssertNil(buffer.byteOffset(forUTF16Offset: 6))

    XCTAssertEqual(buffer.utf16Offset(forByteOffset: 0), 0)
    XCTAssertEqual(buffer.utf16Offset(forByteOffset: 4), 2)
    XCTAssertEqual(buffer.utf16Offset(forByteOffset: 8), 4)
    XCTAssertEqual(buffer.utf16Offset(forByteOffset: 9), 5)

    XCTAssertFalse(buffer.isScalarBoundary(utf16Offset: 3))
    XCTAssertTrue(buffer.isScalarBoundary(utf16Offset: 4))
    XCTAssertEqual(buffer.text(inUTF16Range: 1..<4), "日🙂")
    XCTAssertNil(buffer.text(inUTF16Range: 1..<3))
  }

  func testCaretMovesAcrossWholeGraphemeClusters() {
    let buffer = TextBuffer("a👨‍👩‍👧‍👦e\u{301}日\r\nb")

    var boundaries = [0]
    var cursor = 0
    while let next = buffer.characterBoundary(after: cursor) {
      boundaries.append(next)
      cursor = next
    }
    XCTAssertEqual(boundaries, [0, 1, 12, 14, 15, 17, 18])
    XCTAssertEqual(buffer.utf16Length, 18)

    var backwards = [buffer.utf16Length]
    cursor = buffer.utf16Length
    while let previous = buffer.characterBoundary(before: cursor) {
      backwards.append(previous)
      cursor = previous
      if cursor == 0 {
        break
      }
    }
    XCTAssertEqual(backwards, boundaries.reversed())

    for offset in [2, 5, 11, 13, 16] {
      XCTAssertFalse(
        buffer.isCharacterBoundary(utf16Offset: offset),
        "\(offset) is inside a cluster"
      )
    }
    for offset in boundaries {
      XCTAssertTrue(buffer.isCharacterBoundary(utf16Offset: offset))
    }
  }

  func testGraphemeQueriesStayCorrectInsideAVeryLongLine() {
    let filler = String(repeating: "x", count: 512 * 1024)
    let buffer = TextBuffer(filler + "👩🏽‍🚀" + filler)
    let clusterStart = filler.utf16.count

    XCTAssertTrue(buffer.isCharacterBoundary(utf16Offset: clusterStart))
    XCTAssertFalse(buffer.isCharacterBoundary(utf16Offset: clusterStart + 1))
    XCTAssertEqual(buffer.characterBoundary(after: clusterStart), clusterStart + 7)
    XCTAssertEqual(buffer.characterBoundary(before: clusterStart + 7), clusterStart)
    XCTAssertEqual(buffer.lineCount, 1)
  }

  func testLineIndexKeepsCRLFAndATrailingNewline() {
    let text = "one\r\n日本\r\n\r\n"
    let buffer = TextBuffer(text)

    XCTAssertEqual(Data(buffer.content.utf8), Data(text.utf8))
    XCTAssertEqual(buffer.lineCount, 4)
    XCTAssertEqual(buffer.lineText(line: 1), "one")
    XCTAssertEqual(buffer.lineText(line: 2), "日本")
    XCTAssertEqual(buffer.lineText(line: 3), "")
    XCTAssertEqual(buffer.lineText(line: 4), "")
    XCTAssertNil(buffer.lineText(line: 5))

    XCTAssertEqual(buffer.position(forUTF16Offset: 0), TextBufferPosition(line: 1, column: 1))
    XCTAssertEqual(buffer.position(forUTF16Offset: 5), TextBufferPosition(line: 2, column: 1))
    XCTAssertEqual(buffer.position(forUTF16Offset: 6), TextBufferPosition(line: 2, column: 2))
    XCTAssertEqual(
      buffer.utf16Offset(for: TextBufferPosition(line: 2, column: 2)),
      6
    )
    XCTAssertNil(buffer.utf16Offset(for: TextBufferPosition(line: 2, column: 9)))
  }

  func testLineIndexIsUpdatedIncrementallyByEdits() throws {
    let buffer = TextBuffer("alpha\nbravo\ncharlie\n")
    XCTAssertEqual(buffer.lineCount, 4)

    try buffer.replace(utf16Range: 6..<6, with: "one\ntwo\n")
    XCTAssertEqual(buffer.lineCount, 6)
    XCTAssertEqual(buffer.lineText(line: 2), "one")
    XCTAssertEqual(buffer.lineText(line: 3), "two")
    XCTAssertEqual(buffer.lineText(line: 4), "bravo")
    XCTAssertEqual(buffer.utf16Offset(forLine: 4), 14)

    let bravo = try XCTUnwrap(buffer.lineUTF16Range(line: 4))
    try buffer.replace(utf16Range: bravo.lowerBound..<(bravo.upperBound + 1), with: "")
    XCTAssertEqual(buffer.lineCount, 5)
    XCTAssertEqual(buffer.lineText(line: 4), "charlie")
    XCTAssertEqual(buffer.content, "alpha\none\ntwo\ncharlie\n")

    buffer.replaceAll(with: "fresh\n")
    XCTAssertEqual(buffer.lineCount, 2)
    XCTAssertEqual(buffer.content, "fresh\n")
    XCTAssertEqual(buffer.metrics.appendedByteCount, 0)
  }

  func testEditsMatchAStringReferenceAcrossManyRandomOperations() throws {
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func nextValue(below bound: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      guard bound > 0 else {
        return 0
      }
      return Int((seed >> 33) % UInt64(bound))
    }

    let insertions = ["", "a", "日本", "\n", "🙂", "e\u{301}", "\r\n", "ab\ncd"]
    var reference = "seed 日本\nline\n"
    let buffer = TextBuffer(reference)

    for _ in 0..<400 {
      let characterCount = reference.count
      let start = nextValue(below: characterCount + 1)
      let length = nextValue(below: min(4, characterCount - start) + 1)
      let startIndex = reference.index(reference.startIndex, offsetBy: start)
      let endIndex = reference.index(startIndex, offsetBy: length)
      let location = reference.utf16.distance(from: reference.startIndex, to: startIndex)
      let end = reference.utf16.distance(from: reference.startIndex, to: endIndex)
      let insertion = insertions[nextValue(below: insertions.count)]

      try buffer.replace(utf16Range: location..<end, with: insertion)
      reference.replaceSubrange(startIndex..<endIndex, with: insertion)

      XCTAssertEqual(Data(buffer.content.utf8), Data(reference.utf8))
      XCTAssertEqual(buffer.utf16Length, reference.utf16.count)
      XCTAssertEqual(
        buffer.lineCount,
        reference.split(separator: "\n", omittingEmptySubsequences: false).count
      )
    }
  }

  func testEditingATenMegabyteDocumentCostsTheSizeOfTheEditOnly() throws {
    let line = "let value = 0123456789\n"
    let large = String(repeating: line, count: 500_000)
    XCTAssertGreaterThan(large.utf8.count, 10 * 1024 * 1024)

    let largeBuffer = TextBuffer(large)
    let smallBuffer = TextBuffer(line)
    XCTAssertEqual(largeBuffer.metrics.pieceCount, 1)

    let largeCaret = try XCTUnwrap(largeBuffer.utf16Offset(forLine: 250_000))
    let smallCaret = try XCTUnwrap(smallBuffer.utf16Offset(forLine: 1))
    let typed = "日本 text"
    var largeOffset = largeCaret
    var smallOffset = smallCaret
    for character in typed {
      let piece = String(character)
      try largeBuffer.replace(utf16Range: largeOffset..<largeOffset, with: piece)
      try smallBuffer.replace(utf16Range: smallOffset..<smallOffset, with: piece)
      largeOffset += piece.utf16.count
      smallOffset += piece.utf16.count
    }

    // The only thing an edit costs is the edit: the original bytes are never
    // rewritten and the appended bytes are exactly what was typed. Both buffers
    // land on identical storage metrics even though one document is 10MB and the
    // other is one line.
    XCTAssertEqual(largeBuffer.metrics.appendedByteCount, Data(typed.utf8).count)
    XCTAssertEqual(
      largeBuffer.metrics.appendedByteCount,
      smallBuffer.metrics.appendedByteCount
    )
    XCTAssertEqual(largeBuffer.metrics.pieceCount, smallBuffer.metrics.pieceCount)
    XCTAssertEqual(largeBuffer.metrics.originalByteCount, large.utf8.count)
    XCTAssertEqual(largeBuffer.metrics.utf16Length, large.utf16.count + typed.utf16.count)
    XCTAssertEqual(largeBuffer.metrics.lineCount, 500_001)

    let edited = try XCTUnwrap(largeBuffer.lineText(line: 250_000))
    XCTAssertEqual(edited, typed + "let value = 0123456789")
    XCTAssertEqual(
      largeBuffer.position(forUTF16Offset: largeCaret),
      TextBufferPosition(line: 250_000, column: 1)
    )
  }

  func testDeletingAcrossManyPiecesKeepsTheDocumentConsistent() throws {
    let buffer = TextBuffer("0123456789")
    for offset in stride(from: 10, through: 1, by: -1) {
      try buffer.replace(utf16Range: offset..<offset, with: "-")
    }
    XCTAssertEqual(buffer.content, "0-1-2-3-4-5-6-7-8-9-")
    XCTAssertGreaterThan(buffer.metrics.pieceCount, 10)

    try buffer.replace(utf16Range: 3..<17, with: "…")
    XCTAssertEqual(buffer.content, "0-1…8-9-")
    XCTAssertEqual(buffer.utf16Length, 8)
    XCTAssertEqual(buffer.byteOffset(forUTF16Offset: 8), buffer.byteLength)

    try buffer.replace(utf16Range: 0..<buffer.utf16Length, with: "")
    XCTAssertEqual(buffer.content, "")
    XCTAssertEqual(buffer.utf16Length, 0)
    XCTAssertEqual(buffer.lineCount, 1)
    XCTAssertEqual(buffer.metrics.pieceCount, 0)
  }

  func testInvalidRangesAreRejectedWithoutChangingTheBuffer() {
    let buffer = TextBuffer("🙂abc")

    XCTAssertThrowsError(try buffer.replace(utf16Range: 1..<2, with: "x"))
    XCTAssertThrowsError(try buffer.replace(utf16Range: 4..<9, with: "x"))
    XCTAssertThrowsError(try buffer.replace(utf16Range: -1..<0, with: "x"))
    XCTAssertEqual(buffer.content, "🙂abc")
    XCTAssertEqual(buffer.metrics.appendedByteCount, 0)
  }
}

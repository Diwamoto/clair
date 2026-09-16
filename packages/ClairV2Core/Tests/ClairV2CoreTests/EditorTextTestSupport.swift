import XCTest

@testable import ClairV2EditorCore

struct EditorTextOracleBoundary {
  let index: String.Index
  let utf8: Int
  let utf16: Int
  let scalar: Int
  let grapheme: Int
}

func editorTextBoundaries(_ text: String) -> [EditorTextOracleBoundary] {
  var result: [EditorTextOracleBoundary] = []
  var bytes = 0
  var units = 0
  var scalars = 0
  for index in text.indices {
    result.append(
      EditorTextOracleBoundary(
        index: index, utf8: bytes, utf16: units, scalar: scalars, grapheme: result.count
      )
    )
    let character = String(text[index])
    bytes += character.utf8.count
    units += character.utf16.count
    scalars += character.unicodeScalars.count
  }
  result.append(
    EditorTextOracleBoundary(
      index: text.endIndex, utf8: bytes, utf16: units, scalar: scalars, grapheme: result.count
    )
  )
  return result
}

struct EditorTextOracleLine {
  let start: Int
  let contentEnd: Int
  let end: Int
  let ending: TextLineEnding?
}

/// Independent scalar scanner, deliberately not TextLineEnding.classify or rope metadata.
func editorTextLines(_ text: String) -> [EditorTextOracleLine] {
  let scalars = Array(text.unicodeScalars)
  var result: [EditorTextOracleLine] = []
  var start = 0
  var bytes = 0
  var index = 0
  while index < scalars.count {
    let value = scalars[index].value
    let contentEnd = bytes
    bytes += scalars[index].utf8.count
    index += 1
    let ending: TextLineEnding?
    switch value {
    case 10: ending = .lf
    case 13:
      if index < scalars.count && scalars[index].value == 10 {
        bytes += 1
        index += 1
        ending = .crlf
      } else {
        ending = .cr
      }
    case 0x85: ending = .nel
    case 0x2028: ending = .lineSeparator
    case 0x2029: ending = .paragraphSeparator
    default: ending = nil
    }
    if let ending {
      result.append(
        EditorTextOracleLine(start: start, contentEnd: contentEnd, end: bytes, ending: ending))
      start = bytes
    }
  }
  result.append(EditorTextOracleLine(start: start, contentEnd: bytes, end: bytes, ending: nil))
  return result
}

func assertEditorTextEquivalent(
  _ snapshot: TextSnapshot, _ expected: String, checkCoordinates: Bool = true,
  file: StaticString = #filePath, line: UInt = #line
) throws {
  XCTAssertEqual(Array(snapshot.string().utf8), Array(expected.utf8), file: file, line: line)
  XCTAssertEqual(snapshot.utf8Count, expected.utf8.count, file: file, line: line)
  XCTAssertEqual(snapshot.utf16Count, expected.utf16.count, file: file, line: line)
  XCTAssertEqual(snapshot.scalarCount, expected.unicodeScalars.count, file: file, line: line)
  XCTAssertEqual(snapshot.graphemeCount, expected.count, file: file, line: line)
  let expectedLines = editorTextLines(expected)
  XCTAssertEqual(snapshot.lineCount, expectedLines.count, file: file, line: line)
  var ids: Set<TextLineID> = []
  for (index, expectedLine) in expectedLines.enumerated() {
    let actual = try snapshot.line(at: TextLineIndex(index))
    XCTAssertEqual(actual.contentRange.lowerBound.value, expectedLine.start, file: file, line: line)
    XCTAssertEqual(
      actual.contentRange.upperBound.value, expectedLine.contentEnd, file: file, line: line)
    XCTAssertEqual(
      actual.terminatorRange.lowerBound.value, expectedLine.contentEnd, file: file, line: line)
    XCTAssertEqual(
      actual.terminatorRange.upperBound.value, expectedLine.end, file: file, line: line)
    XCTAssertEqual(actual.ending, expectedLine.ending, file: file, line: line)
    XCTAssertTrue(ids.insert(actual.id).inserted, "duplicate line ID", file: file, line: line)
  }
  if checkCoordinates {
    for boundary in editorTextBoundaries(expected) {
      let bytes = UTF8Offset(boundary.utf8)
      XCTAssertEqual(
        try snapshot.convert(bytes, to: UTF16Unit.self).value, boundary.utf16, file: file,
        line: line)
      XCTAssertEqual(
        try snapshot.convert(bytes, to: ScalarUnit.self).value, boundary.scalar, file: file,
        line: line)
      XCTAssertEqual(
        try snapshot.convert(bytes, to: GraphemeUnit.self).value, boundary.grapheme, file: file,
        line: line)
      XCTAssertEqual(
        try snapshot.convert(UTF16Offset(boundary.utf16), to: UTF8Unit.self), bytes, file: file,
        line: line)
      XCTAssertEqual(
        try snapshot.convert(ScalarOffset(boundary.scalar), to: UTF8Unit.self), bytes, file: file,
        line: line)
      XCTAssertEqual(
        try snapshot.convert(GraphemeOffset(boundary.grapheme), to: UTF8Unit.self), bytes,
        file: file, line: line)
      let position = try snapshot.position(at: bytes, columnUnit: UTF16Unit.self)
      let lineIndex = expectedLines.lastIndex { $0.start <= boundary.utf8 }!
      XCTAssertEqual(position.line.value, lineIndex, file: file, line: line)
      XCTAssertEqual(try snapshot.offset(at: position), bytes, file: file, line: line)
      XCTAssertEqual(
        try snapshot.offset(at: snapshot.position(at: bytes, columnUnit: GraphemeUnit.self)),
        bytes, file: file, line: line
      )
      XCTAssertEqual(
        try snapshot.offset(at: snapshot.position(at: bytes, columnUnit: ScalarUnit.self)),
        bytes, file: file, line: line
      )
      XCTAssertEqual(
        try snapshot.offset(at: snapshot.position(at: bytes, columnUnit: UTF8Unit.self)),
        bytes, file: file, line: line
      )
    }
  }
  _ = assertEditorTextTree(snapshot.root, file: file, line: line)
}

@discardableResult
func assertEditorTextTree(
  _ node: TextNode?, file: StaticString = #filePath, line: UInt = #line
) -> TextMetrics {
  guard let node else { return TextMetrics() }
  if let leaf = node.leaf {
    XCTAssertFalse(leaf.text.isEmpty, file: file, line: line)
    XCTAssertEqual(node.height, 1, file: file, line: line)
    let expected = TextMetrics(
      utf8: leaf.text.utf8.count, utf16: leaf.text.utf16.count,
      scalars: leaf.text.unicodeScalars.count, graphemes: leaf.text.count,
      breaks: editorTextLines(leaf.text).count - 1
    )
    XCTAssertEqual(node.metrics, expected, file: file, line: line)
    return expected
  }
  XCTAssertNotNil(node.left, file: file, line: line)
  XCTAssertNotNil(node.right, file: file, line: line)
  let sum =
    assertEditorTextTree(node.left, file: file, line: line)
    + assertEditorTextTree(node.right, file: file, line: line)
  XCTAssertEqual(node.metrics, sum, file: file, line: line)
  XCTAssertLessThanOrEqual(abs(node.left!.height - node.right!.height), 1, file: file, line: line)
  XCTAssertEqual(
    node.height, max(node.left!.height, node.right!.height) + 1, file: file, line: line)
  return sum
}

struct EditorTextRandom {
  var state: UInt64

  mutating func next(_ limit: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 16) % UInt64(limit))
  }
}

func editorTextRange(_ start: Int, _ end: Int) -> TextUTF8Range {
  TextUTF8Range(UTF8Offset(start), UTF8Offset(end))
}

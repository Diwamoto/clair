import ClairEditorCore
import ClairEditorFixtures
import XCTest

final class EditorTextRandomizedTests: XCTestCase {
  func testUnicodeEditsAcrossManyLeavesAndLargeDeletions() throws {
    var random = EditorTextRandom(state: 0xA11C_E02)
    var text = String(repeating: UnicodeCorpus.concatenated + "\r\u{2029}", count: 200)
    let buffer = try TextBuffer(text)
    let original = buffer.snapshot
    let insertions =
      UnicodeCorpus.deleteBoundaryCases + ["\u{301}", "\u{200D}", "🇺", "\r", "\n", "\u{600}", ""]
    for iteration in 0..<300 {
      let boundaries = editorTextBoundaries(text)
      let start = random.next(boundaries.count)
      let deleteLimit = iteration.isMultiple(of: 37) ? 2_000 : 8
      let end = start + random.next(min(deleteLimit, boundaries.count - start))
      let replacement = insertions[random.next(insertions.count)]
      let range = editorTextRange(boundaries[start].utf8, boundaries[end].utf8)
      text.replaceSubrange(boundaries[start].index..<boundaries[end].index, with: replacement)
      try buffer.replace(range, with: replacement, basedOn: buffer.snapshot.revision)
      try assertEditorTextEquivalent(buffer.snapshot, text, checkCoordinates: false)
      let rebuilt = try TextBuffer(text).snapshot
      for _ in 0..<20 {
        let point = GraphemeOffset(random.next(text.count + 1))
        let bytes = try buffer.snapshot.convert(point, to: UTF8Unit.self)
        XCTAssertEqual(bytes, try rebuilt.convert(point, to: UTF8Unit.self))
        XCTAssertEqual(
          try buffer.snapshot.position(at: bytes, columnUnit: UTF16Unit.self),
          try rebuilt.position(at: bytes, columnUnit: UTF16Unit.self)
        )
      }
    }
    XCTAssertEqual(original.revision.sequence, 0)
    try assertEditorTextEquivalent(
      original, String(repeating: UnicodeCorpus.concatenated + "\r\u{2029}", count: 200),
      checkCoordinates: false
    )
  }

  func testSeededEditsDifferentiallyMatchSwiftAndFreshRebuilds() throws {
    let insertions =
      UnicodeCorpus.deleteBoundaryCases + [
        "", "abc", "\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}",
        "\u{301}", "\u{200D}", "🇺", "\u{600}", "क्", "ष", "👩🏽", "💻", "é", "e\u{301}",
      ]
    for seed: UInt64 in [1, 29, 127, 1_337, 0xC1A1, 0xDEAD_BEEF] {
      var random = EditorTextRandom(state: seed)
      var text = UnicodeCorpus.concatenated
      let buffer = try TextBuffer(text)
      var retained: [(TextSnapshot, String)] = []
      var seenIDs: Set<TextLineID> = []
      for index in 0..<buffer.snapshot.lineCount {
        seenIDs.insert(try buffer.snapshot.line(at: TextLineIndex(index)).id)
      }
      for iteration in 0..<400 {
        let before = buffer.snapshot
        let oldText = text
        let boundaries = editorTextBoundaries(text)
        let start = random.next(boundaries.count)
        let length = random.next(min(12, boundaries.count - start))
        let end = start + length
        let replacement = insertions[random.next(insertions.count)]
        let range = editorTextRange(boundaries[start].utf8, boundaries[end].utf8)
        text.replaceSubrange(boundaries[start].index..<boundaries[end].index, with: replacement)
        try buffer.replace(range, with: replacement, basedOn: before.revision)
        let snapshot = buffer.snapshot
        let unchanged = oldText.utf8.elementsEqual(text.utf8)
        XCTAssertEqual(
          snapshot.revision.sequence, before.revision.sequence + (unchanged ? 0 : 1),
          "seed=\(seed), edit=\(iteration)")
        try assertEditorTextEquivalent(snapshot, text)
        let rebuilt = try TextBuffer(text).snapshot
        XCTAssertEqual(snapshot.utf8Count, rebuilt.utf8Count)
        XCTAssertEqual(snapshot.utf16Count, rebuilt.utf16Count)
        XCTAssertEqual(snapshot.scalarCount, rebuilt.scalarCount)
        XCTAssertEqual(snapshot.graphemeCount, rebuilt.graphemeCount)
        XCTAssertEqual(snapshot.lineCount, rebuilt.lineCount)
        try assertLineIDProvenance(
          before: before, oldText: oldText, after: snapshot, newText: text,
          range: range, replacement: replacement, unchanged: unchanged, seen: &seenIDs
        )
        if iteration.isMultiple(of: 41) { retained.append((before, oldText)) }
      }
      for (snapshot, expected) in retained {
        try assertEditorTextEquivalent(snapshot, expected)
      }
    }
  }

  private func assertLineIDProvenance(
    before: TextSnapshot, oldText: String, after: TextSnapshot, newText: String,
    range: TextUTF8Range, replacement: String, unchanged: Bool, seen: inout Set<TextLineID>
  ) throws {
    XCTAssertEqual(before.firstLineID, after.firstLineID)
    let oldLines = editorTextLines(oldText)
    let delta = replacement.utf8.count - (range.upperBound.value - range.lowerBound.value)
    var survivors: [(start: Int, id: TextLineID)] = []
    for (index, line) in oldLines.dropLast().enumerated() {
      let id = try before.line(at: TextLineIndex(index + 1)).id
      if unchanged || line.end <= range.lowerBound.value {
        survivors.append((line.contentEnd, id))
      } else if line.contentEnd >= range.upperBound.value {
        survivors.append((line.contentEnd + delta, id))
      }
    }
    for (index, line) in editorTextLines(newText).dropLast().enumerated() {
      let id = try after.line(at: TextLineIndex(index + 1)).id
      if let expected = survivors.first(where: {
        $0.start >= line.contentEnd && $0.start < line.end
      }) {
        XCTAssertEqual(id, expected.id, "a surviving terminator must keep its identity")
      } else {
        XCTAssertFalse(seen.contains(id), "a new terminator must never reuse a retired ID")
      }
      seen.insert(id)
    }
  }
}

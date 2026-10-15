import XCTest

@testable import ClairEditorView

final class SuspiciousCharacterTests: XCTestCase {
  private func flagged(_ text: String, ideographicSpace: Bool = false) -> [String] {
    suspiciousCharacterRanges(in: text, ideographicSpace: ideographicSpace).map { String(text.unicodeScalars[$0]) }
  }

  func testFlagsLookalikesMixedIntoASCIIWords() {
    XCTAssertEqual(flagged("\u{430}ma ama"), ["\u{430}"])  // Cyrillic а
    XCTAssertEqual(flagged("p\u{3BF}st"), ["\u{3BF}"])  // Greek ο
    XCTAssertEqual(flagged("ｇoogle"), ["ｇ"])
    XCTAssertEqual(flagged("\u{13AA}pple 𝐚dmin \u{2170}d v１"), ["\u{13AA}", "𝐚", "\u{2170}", "１"])
  }

  func testFlagsInvisibleBidiAndControlCharacters() {
    XCTAssertEqual(flagged("a\u{200B}b \u{202E}x \u{1B}[0m \u{7F}"), ["\u{200B}", "\u{202E}", "\u{1B}", "\u{7F}"])
    XCTAssertEqual(flagged("tab\tok"), [])
  }

  func testFlagsHiddenTagsSelectorsAndStackedMarks() {
    XCTAssertEqual(flagged("hi\u{E0041}\u{E0042}"), ["\u{E0041}", "\u{E0042}"])
    XCTAssertEqual(flagged("x\u{FE0F}"), ["\u{FE0F}"])
    XCTAssertEqual(flagged("e\u{301}\u{302}"), ["\u{301}", "\u{302}"])
    XCTAssertEqual(flagged("❤\u{FE0F} か\u{3099}"), [])  // emoji presentation, dakuten
  }

  func testFlagsLookalikeSpacesAndPunctuation() {
    XCTAssertEqual(flagged("a\u{A0}b c\u{37E} 1\u{2212}2"), ["\u{A0}", "\u{37E}", "\u{2212}"])
    XCTAssertEqual(flagged("全角\u{3000}空白"), [])
    XCTAssertEqual(flagged("全角\u{3000}空白", ideographicSpace: true), ["\u{3000}"])
  }

  func testLeavesPlainScriptsAlone() {
    XCTAssertEqual(flagged("let привет = \"日本語abc\"; αβγ 25℃ №1"), [])
  }
}

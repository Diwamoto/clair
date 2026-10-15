import XCTest

@testable import ClairEditorView

final class SuspiciousCharacterTests: XCTestCase {
  private func flagged(_ text: String) -> [String] {
    suspiciousCharacterRanges(in: text).map { String(text.unicodeScalars[$0]) }
  }

  func testFlagsLookalikesMixedIntoASCIIWords() {
    XCTAssertEqual(flagged("\u{430}ma ama"), ["\u{430}"])  // Cyrillic а
    XCTAssertEqual(flagged("p\u{3BF}st"), ["\u{3BF}"])  // Greek ο
    XCTAssertEqual(flagged("ｇoogle"), ["ｇ"])
  }

  func testFlagsInvisibleAndBidiControls() {
    XCTAssertEqual(flagged("a\u{200B}b \u{202E}x"), ["\u{200B}", "\u{202E}"])
  }

  func testLeavesPlainScriptsAlone() {
    XCTAssertEqual(flagged("let привет = \"日本語abc\"; αβγ"), [])
  }
}

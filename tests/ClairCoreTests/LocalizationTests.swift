@testable import ClairShared
import XCTest

final class LocalizationTests: XCTestCase {
  override func tearDown() { ClairLanguage.current = .english }

  func testEnglishIsDefaultAndTranslatesJapaneseLiterals() {
    XCTAssertEqual(ClairLanguage.current, .english)
    XCTAssertEqual(tr("一般"), "General")
    let n = 3
    XCTAssertEqual(tr("%@ 件 / %@ ファイル", n, 4), "3 results in 4 files")
    XCTAssertEqual(tr("設定: %@を %@ にする", "A", "B"), "Settings: set A to B")
    XCTAssertEqual(tr("未登録の文字列"), "未登録の文字列")
  }

  func testJapaneseKeepsJapaneseAndTranslatesEnglishLiterals() {
    ClairLanguage.current = .japanese
    XCTAssertEqual(tr("一般"), "一般")
    XCTAssertEqual(tr("Next Tab"), "次のタブ")
    XCTAssertEqual(tr("Settings…"), "設定…")
  }

  func testFormatReordersAndKeepsPercent() {
    XCTAssertEqual(LocalizedStrings.format("%2$@ then %1$@", ["a", "b"]), "b then a")
    XCTAssertEqual(LocalizedStrings.format("%@% left", ["40"]), "40% left")
  }
}

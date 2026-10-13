import XCTest

@testable import ClairWorkspace

/// arc's GLIDE_ROWS rule (packages/ClairWorkspace/PaletteGlide.swift).
final class PaletteGlideTests: XCTestCase {
  func testRowsClosingAGapGlide() {
    // "a" dropped out; the rest each move up one row.
    XCTAssertTrue(PaletteGlide.shouldGlide(previous: ["a", "b", "c", "d"], current: ["b", "c", "d"]))
  }

  func testLongJumpSnaps() {
    XCTAssertFalse(PaletteGlide.shouldGlide(previous: (0...20).map(String.init), current: ["17"]))
  }

  func testNewRowsNeverBlockTheGlide() {
    XCTAssertTrue(PaletteGlide.shouldGlide(previous: ["a", "b"], current: ["a", "b", "c", "d", "e"]))
  }

  func testNoSharedRowsSnaps() {
    XCTAssertFalse(PaletteGlide.shouldGlide(previous: ["a"], current: ["x", "y"]))
  }

  func testEmptyPreviousSnaps() {
    XCTAssertFalse(PaletteGlide.shouldGlide(previous: [], current: ["a"]))
  }

  func testPaletteKeyDistinguishesSameIdRows() {
    // Every branch row is `git.switch`; the title keeps keys unique.
    let a = PaletteItem(title: "main", hint: "", id: "git.switch", input: [:])
    let b = PaletteItem(title: "topic", hint: "", id: "git.switch", input: [:])
    XCTAssertNotEqual(a.paletteKey, b.paletteKey)
    XCTAssertTrue(PaletteGlide.shouldGlide(previous: [a.paletteKey, b.paletteKey], current: [b.paletteKey]))
  }
}

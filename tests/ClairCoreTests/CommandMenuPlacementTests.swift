import XCTest
@testable import ClairAppKit

final class CommandMenuPlacementTests: XCTestCase {
  func testCommandsLandInStandardMenus() {
    typealias M = ClairCommandMenu
    XCTAssertEqual(M.menu("settings.open"), .settings)
    XCTAssertEqual(M.menu("file.save"), .file)
    XCTAssertEqual(M.menu("pane.close"), .file)
    XCTAssertEqual(M.menu("palette.find"), .edit)
    XCTAssertEqual(M.menu("sidebar.toggle"), .view)
    XCTAssertEqual(M.menu("editor.definition"), .go)
    XCTAssertEqual(M.menu("debug.restart"), .view)
  }
}

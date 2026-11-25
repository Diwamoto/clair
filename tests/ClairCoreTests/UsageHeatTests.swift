import XCTest

@testable import ClairAppKit

final class UsageHeatTests: XCTestCase {
  func testLevelsAreRelativeToTheCountsOnScreen() {
    let heat = UsageHeat([0, 0] + Array(1...100))
    XCTAssertEqual(heat.level(0), 0)
    XCTAssertEqual(heat.level(1), 1)
    XCTAssertEqual(heat.level(15), 2)
    XCTAssertEqual(heat.level(55), 6)
    XCTAssertEqual(heat.level(100), 10)
    // A heavy user's quiet day is still lighter than their busy day.
    let heavy = UsageHeat([50, 80, 120, 300, 600])
    XCTAssertLessThan(heavy.level(50), heavy.level(600))
    XCTAssertEqual(UsageHeat([]).level(5), 1)
  }
}

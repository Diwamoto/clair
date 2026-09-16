import ClairV2DesignSystem
import XCTest

/// Verifies radius/spacing/chrome-budget/mobile-metric primitives against
/// checklist §2.3, §2.4 and §2.6.
final class SpacingRadiusTests: XCTestCase {
  func testDesktopRadiusMatchesChecklist() {
    XCTAssertEqual(Radius.control, 4)
    XCTAssertEqual(Radius.card, 6)
    XCTAssertEqual(Radius.overlay, 10)
  }

  func testDesktopSpacingScaleMatchesChecklist() {
    XCTAssertEqual(Spacing.scale, [2, 4, 6, 8, 12, 16, 24])
  }

  func testChromeBudgetMatchesChecklist() {
    XCTAssertEqual(ChromeBudget.titlebar, 48)
    XCTAssertEqual(ChromeBudget.sidebarStrip, 34)
    XCTAssertEqual(ChromeBudget.statusBar, 26)
    // §2.4: titlebar (48) + status bar (26) = 74px vertical budget.
    XCTAssertEqual(ChromeBudget.titlebar + ChromeBudget.statusBar, 74)
  }

  func testMobileMetricsMatchChecklist() {
    XCTAssertEqual(MobileMetrics.viewportWidth, 390)
    XCTAssertEqual(MobileMetrics.viewportHeight, 844)
    XCTAssertEqual(MobileMetrics.statusBarInset, 54)
    XCTAssertEqual(MobileMetrics.tabBarHeight, 78)
    XCTAssertEqual(MobileMetrics.gutter, 16)
    XCTAssertEqual(MobileMetrics.touchTarget, 44)
  }

  func testMobileRadiusDiffersFromDesktopRadius() {
    // §2.6: mobile uses card 10 / button+field 8, a different rule from
    // the desktop 4-6-10 scale above — these must not be aliased together.
    XCTAssertEqual(MobileMetrics.Radius.card, 10)
    XCTAssertEqual(MobileMetrics.Radius.button, 8)
    XCTAssertEqual(MobileMetrics.Radius.field, 8)
  }
}

import XCTest

@MainActor
final class ClairMobileUITests: XCTestCase {
  func testFoundationShellLaunchesAndRoutesNavigation() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.navigationBars["Clair Mobile"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["current-destination"].label, "Overview")

    app.buttons["Sessions"].tap()

    XCTAssertEqual(app.staticTexts["current-destination"].label, "Sessions")
  }
}

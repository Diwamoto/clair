import XCTest

@MainActor
final class ClairV2MobileUITests: XCTestCase {
  func testFoundationShellLaunchesAndRoutesNavigation() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.navigationBars["Clair v2 Mobile"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["current-destination"].label, "Overview")

    app.buttons["Sessions"].tap()

    XCTAssertEqual(app.staticTexts["current-destination"].label, "Sessions")
  }
}

import XCTest

@testable import ClairV2Workspace

final class PaneTreeTests: XCTestCase {
  func testInitialLayoutAndFocusOrder() {
    var t = PaneTree()
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .agent, .terminal])
    t.focusNext(); XCTAssertEqual(t.focused, 2)
    t.focusNext(); t.focusNext(); XCTAssertEqual(t.focused, 1)  // wraps
  }

  func testSplitCopiesKindAndFocusesNew() {
    var t = PaneTree()
    t.splitFocused(.vertical)
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .editor, .agent, .terminal])
    XCTAssertEqual(t.focused, 4)
  }

  func testCloseKeepsSiblingAndLastPaneSurvives() {
    var t = PaneTree()
    t.focus(2); t.closeFocused()
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .terminal])
    t.closeFocused(); t.closeFocused(); t.closeFocused()
    XCTAssertEqual(t.leaves.count, 1)
  }

  func testRatioClampAndEqualize() {
    var t = PaneTree()
    t.setRatio(splitContaining: 1, 5)
    guard case .split(_, let r, _, _) = t.root else { return XCTFail() }
    XCTAssertEqual(r, 0.92)
    t.equalize()
    guard case .split(_, let r2, _, _) = t.root else { return XCTFail() }
    XCTAssertEqual(r2, 0.5)
  }

  func testMaximizeFollowsFocus() {
    var t = PaneTree()
    t.toggleMaximize(); XCTAssertEqual(t.maximized, 1)
    t.focusNext(); XCTAssertEqual(t.maximized, 2)
    t.toggleMaximize(); XCTAssertNil(t.maximized)
  }

  func testSwapLeavesExchangesKindButNotShapeOrFocus() {
    var t = PaneTree()
    t.focus(2)
    t.swapLeaves(2, 3)
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .terminal, .agent])
    XCTAssertEqual(t.focused, 2)  // ids/focus stay put; only what they show moves
    guard case .split(_, let ratio, _, let right) = t.root, case .split(_, _, let a, let b) = right
    else { return XCTFail() }
    XCTAssertEqual(ratio, 0.62)
    guard case .leaf(2, .terminal) = a, case .leaf(3, .agent) = b else { return XCTFail() }
  }

  func testSwapLeavesIgnoresSelfOrUnknownID() {
    var t = PaneTree()
    t.swapLeaves(1, 1)
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .agent, .terminal])
    t.swapLeaves(1, 99)
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .agent, .terminal])
  }
}

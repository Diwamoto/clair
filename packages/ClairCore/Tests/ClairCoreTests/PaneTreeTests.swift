import XCTest

@testable import ClairWorkspace

final class PaneTreeTests: XCTestCase {
  func testInitialLayoutAndFocusOrder() {
    var t = PaneTree()
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .terminal, .terminal])
    t.focusNext(); XCTAssertEqual(t.focused, 2)
    t.focusNext(); t.focusNext(); XCTAssertEqual(t.focused, 1)  // wraps
    t.focusPrevious(); XCTAssertEqual(t.focused, 3)  // reverse wraps through terminal
    t.focusPrevious(); t.focusPrevious(); XCTAssertEqual(t.focused, 1)  // includes editor
  }

  func testSplitCopiesKindAndFocusesNew() {
    var t = PaneTree()
    t.splitFocused(.vertical)
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .editor, .terminal, .terminal])
    XCTAssertEqual(t.focused, 4)
  }

  func testMoveLeafSplitsTargetOnEdge() {
    var t = PaneTree()
    t.moveLeaf(3, to: 1, .left)  // cannot displace the anchored editor
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .terminal, .terminal])
    t.moveLeaf(3, to: 1, .right)
    XCTAssertEqual(t.root, .split(axis: .horizontal, ratio: 0.62,
      first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(id: 1, kind: .editor), second: .leaf(id: 3, kind: .terminal)),
      second: .leaf(id: 2, kind: .terminal)))
    XCTAssertEqual(t.focused, 3)
    t.moveLeaf(3, to: 3, .top)  // self: no-op
    t.moveLeaf(2, to: 1, .bottom)
    XCTAssertEqual(t.leaves.map(\.id), [1, 2, 3])
    XCTAssertTrue(t.isValid)
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

  func testRatioMovesOnlyThatDivider() {
    var t = PaneTree()  // editor 1 | (agent 2 / terminal 3)
    t.focus(1); t.splitFocused(.vertical)  // (1 / 4) | (2 / 3)
    t.setRatio(splitContaining: 1, 0.3)  // divider between 1 and 4
    guard case .split(_, let outer, .split(_, let inner, _, _), _) = t.root else { return XCTFail() }
    XCTAssertEqual(outer, 0.62)
    XCTAssertEqual(inner, 0.3)
    t.setRatio(splitContaining: 4, 0.7)  // divider between left column and right column
    guard case .split(_, let outer2, .split(_, let inner2, _, _), _) = t.root else { return XCTFail() }
    XCTAssertEqual(outer2, 0.7)
    XCTAssertEqual(inner2, 0.3)
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
    t.swapLeaves(1, 3)
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .terminal, .terminal])
    XCTAssertEqual(t.focused, 2)  // ids/focus stay put; only what they show moves
    guard case .split(_, let ratio, let left, let right) = t.root, case .split(_, _, _, let b) = right
    else { return XCTFail() }
    XCTAssertEqual(ratio, 0.62)
    guard case .leaf(1, .editor) = left, case .leaf(3, .terminal) = b else { return XCTFail() }
  }

  func testSwapLeavesIgnoresSelfOrUnknownID() {
    var t = PaneTree()
    t.swapLeaves(1, 1)
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .terminal, .terminal])
    t.swapLeaves(1, 99)
    XCTAssertEqual(t.leaves.map(\.kind), [.editor, .terminal, .terminal])
  }

  /// U06: a workspace saved with the removed Agent panel restores it as a terminal.
  func testSavedAgentLeafRestoresAsTerminal() throws {
    let json = #"{"leaf":{"id":2,"kind":"agent"}}"#
    XCTAssertEqual(try JSONDecoder().decode(PaneTree.Node.self, from: Data(json.utf8)), .leaf(id: 2, kind: .terminal))
    XCTAssertThrowsError(try JSONDecoder().decode(PaneKind.self, from: Data(#""chat""#.utf8)))
  }
}

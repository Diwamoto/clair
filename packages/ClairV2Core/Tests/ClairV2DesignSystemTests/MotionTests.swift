import ClairV2DesignSystem
import XCTest

/// Verifies motion primitives against checklist §2.5 (`motion.tsx`'s
/// `SCREEN_MS`/`OVERLAY_MS`, `KIND`, `ORDER` and `transitionFor`).
final class MotionTests: XCTestCase {
  func testDurationsMatchChecklist() {
    XCTAssertEqual(Motion.screenDuration, 0.2, accuracy: 0.0001) // SCREEN_MS = 200
    XCTAssertEqual(Motion.overlayDuration, 0.09, accuracy: 0.0001) // OVERLAY_MS = 90
  }

  func testPerScreenKindMappingMatchesChecklist() {
    let expected: [Screen: Motion.Kind] = [
      .workspace: .depth,
      .review: .slide,
      .graph: .slide,
      .activity: .depth,
      .debug: .depth,
      .debugAgent: .depth,
      .sessions: .lift,
      .settings: .sheet,
    ]
    for screen in Screen.allCases {
      XCTAssertEqual(Motion.kind[screen], expected[screen], "kind[\(screen)]")
    }
    XCTAssertEqual(Motion.kind.count, expected.count)
  }

  func testOrderMatchesChecklist() {
    XCTAssertEqual(
      Motion.order,
      [.workspace, .graph, .review, .debug, .debugAgent, .activity, .sessions, .settings]
    )
  }

  func testOverlayOpenScaleMatchesChecklist() {
    XCTAssertEqual(Motion.overlayOpenScale, 0.97)
  }

  // MARK: - transition(from:to:)

  func testNonSlideTransitionsUseTheEnteredScreensKind() {
    XCTAssertEqual(Motion.transition(from: .workspace, to: .activity), .depth)
    XCTAssertEqual(Motion.transition(from: .workspace, to: .sessions), .lift)
    XCTAssertEqual(Motion.transition(from: .workspace, to: .settings), .sheet)
  }

  func testSlideTransitionDirectionFollowsOrderIndex() {
    // ORDER: workspace, graph, review, debug, debugAgent, activity, sessions, settings.
    // graph (index 1) -> review (index 2): forward.
    XCTAssertEqual(Motion.transition(from: .graph, to: .review), .slideForward)
    // review (index 2) -> graph (index 1): backward.
    XCTAssertEqual(Motion.transition(from: .review, to: .graph), .slideBackward)
  }

  func testReturningToWorkspaceUsesTheLeavingScreensKind() {
    // Leaving `sessions` (kind lift) back to workspace uses `lift`, not
    // workspace's own (always-depth) kind.
    XCTAssertEqual(Motion.transition(from: .sessions, to: .workspace), .lift)
    XCTAssertEqual(Motion.transition(from: .settings, to: .workspace), .sheet)
    // Leaving a `slide` screen back to workspace: direction still follows
    // ORDER, comparing workspace's own index (0).
    XCTAssertEqual(Motion.transition(from: .review, to: .workspace), .slideBackward)
  }

  func testWorkspaceToWorkspaceIsDepth() {
    // Degenerate case: kind[.workspace] is looked up when returning to
    // workspace from workspace, which is depth either way.
    XCTAssertEqual(Motion.transition(from: .workspace, to: .workspace), .depth)
  }
}

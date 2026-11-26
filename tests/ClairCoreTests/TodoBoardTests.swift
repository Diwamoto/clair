import XCTest

@testable import ClairWorkspace

final class TodoBoardTests: XCTestCase {
  func testStaleSandboxes() {
    let cases: [(name: String, listed: String, keep: Set<String>, want: [String])] = [
      ("only Clair's names", "claude-sandbox-life\nclair-a\n", [], ["clair-a"]),
      ("open panes kept", "clair-a\nclair-b\n", ["clair-a"], ["clair-b"]),
      ("nothing listed", "", [], []),
    ]
    for c in cases { XCTAssertEqual(AgentRun.staleSandboxes(c.listed, keep: c.keep), c.want, c.name) }
  }
}

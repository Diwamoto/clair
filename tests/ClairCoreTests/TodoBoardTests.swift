import XCTest

@testable import ClairWorkspace

final class TodoBoardTests: XCTestCase {
  func testCardState() {
    let s = WorkbenchState()
    let cases: [(name: String, todo: ClairTodo, want: TodoBoardCard.State?)] = [
      ("no stage stays off the board", ClairTodo(path: "a", title: "a"), nil),
      ("plan waits for the owner", ClairTodo(path: "b", title: "b").with { $0.stage = "plan" }, .waiting),
      ("submit waits for review", ClairTodo(path: "c", title: "c").with { $0.stage = "submit" }, .waiting),
      ("impl with no live agent waits", ClairTodo(path: "d", title: "d").with { $0.stage = "impl"; $0.agent = "/gone#3" }, .waiting),
      ("too many send-backs", ClairTodo(path: "e", title: "e").with { $0.stage = "impl"; $0.retry = 4 }, .overLimit),
      ("done", ClairTodo(path: "f", title: "f").with { $0.stage = "done" }, .done),
    ]
    for c in cases {
      XCTAssertEqual(s.board([c.todo]).first?.state, c.want, c.name)
    }
  }

  func testStaleSandboxes() {
    let cases: [(name: String, listed: String, keep: Set<String>, want: [String])] = [
      ("only Clair's names", "claude-sandbox-life\nclair-a\n", [], ["clair-a"]),
      ("open panes kept", "clair-a\nclair-b\n", ["clair-a"], ["clair-b"]),
      ("nothing listed", "", [], []),
    ]
    for c in cases { XCTAssertEqual(AgentRun.staleSandboxes(c.listed, keep: c.keep), c.want, c.name) }
  }

  func testHistoryLines() {
    let cases: [(name: String, text: String, want: [String])] = [
      ("stage lines only", "---\nstage: impl\n---\nnote\n- plan /a#1 agreed\n- impl /b#2\n- other\n", ["plan /a#1 agreed", "impl /b#2"]),
      ("front matter ignored", "---\n- plan x\n---\n", []),
    ]
    for c in cases { XCTAssertEqual(TodoBoardCard.history(c.text), c.want, c.name) }
  }
}

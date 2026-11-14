import XCTest

@testable import ClairWorkspace

final class TodoBoardTests: XCTestCase {
  func testCardState() {
    let s = WorkbenchState()
    let cases: [(name: String, todo: ClairTodo, want: TodoBoardCard.State, column: String)] = [
      ("no stage is inbox", ClairTodo(path: "a", title: "a"), .idle, "inbox"),
      ("plan with no agent yet", ClairTodo(path: "b", title: "b").with { $0.stage = "plan" }, .idle, "plan"),
      ("submit reads as review", ClairTodo(path: "c", title: "c").with { $0.stage = "submit" }, .idle, "review"),
      ("agent pane gone", ClairTodo(path: "d", title: "d").with { $0.stage = "impl"; $0.agent = "/gone#3" }, .idle, "impl"),
      ("reported failed", ClairTodo(path: "e", title: "e").with { $0.stage = "impl"; $0.result = "failed" }, .failed, "impl"),
      ("reported ok", ClairTodo(path: "f", title: "f").with { $0.stage = "review"; $0.result = "ok" }, .done, "review"),
      ("done column", ClairTodo(path: "g", title: "g").with { $0.stage = "done" }, .idle, "done"),
    ]
    for c in cases {
      let card = s.board([c.todo]).cards.first ?? s.board([c.todo]).archived.first
      XCTAssertEqual(card?.state, c.want, c.name)
      XCTAssertEqual(card?.column, c.column, c.name)
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

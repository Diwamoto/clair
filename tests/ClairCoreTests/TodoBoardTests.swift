import XCTest

@testable import ClairWorkspace

final class TodoBoardTests: XCTestCase {
  func testCardState() {
    let s = WorkbenchState()
    let cases: [(name: String, todo: ClairTodo, want: TodoBoardCard.State?)] = [
      ("no stage stays off the board", ClairTodo(path: "a", title: "a"), nil),
      ("plan waits for the owner", ClairTodo(path: "b", title: "b").with { $0.stage = "plan" }, .waiting),
      ("submit waits for review", ClairTodo(path: "c", title: "c").with { $0.stage = "submit" }, .waiting),
      ("impl runs", ClairTodo(path: "d", title: "d").with { $0.stage = "impl" }, .running),
      ("too many send-backs", ClairTodo(path: "e", title: "e").with { $0.stage = "impl"; $0.retry = 4 }, .overLimit),
      ("done", ClairTodo(path: "f", title: "f").with { $0.stage = "done" }, .done),
    ]
    for c in cases {
      XCTAssertEqual(s.board([c.todo]).first?.state, c.want, c.name)
    }
  }
}

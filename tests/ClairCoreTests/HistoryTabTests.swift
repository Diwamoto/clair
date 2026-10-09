import XCTest

@testable import ClairWorkspace

/// History chats open as tabs in the leftmost editor, beside file tabs.
final class HistoryTabTests: XCTestCase {
  func testHistoryChatOpensClosesAndReopensAsAnEditorTab() throws {
    let r = CommandRegistry.workbench
    var s = WorkbenchState()
    _ = try r.execute("pane.splitRight", state: &s).get()
    _ = try r.execute("history.open", ["id": .string("Codex:abc")], state: &s).get()
    let path = AgentHistory.tabPrefix + "Codex:abc"
    XCTAssertEqual(AgentHistory.id(tab: path), "Codex:abc")
    XCTAssertNil(AgentHistory.id(tab: "README.md"))
    XCTAssertEqual(s.active, path)
    XCTAssertTrue(s.tabs.contains(path))
    XCTAssertEqual(s.tree.leaves.first?.kind, .editor)
    _ = try r.execute("tab.close", ["path": .string(path)], state: &s).get()
    XCTAssertFalse(s.tabs.contains(path))
    _ = try r.execute("tab.reopenClosed", state: &s).get()
    XCTAssertEqual(s.active, path)
  }
}

import XCTest

@testable import ClairWorkspace

final class ClairTodoTests: XCTestCase {
  func testShippedSkillMatchesRepoSkill() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../.agents/skills/clair-todo/SKILL.md")
    XCTAssertEqual(ClairTodoSkill.markdown, try String(contentsOf: repo, encoding: .utf8))
  }

  func testParseAndSort() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-todo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let dir = ClairTodo.dir(home: home)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "---\ntitle: \"Low\"\npriority: 3\n---\nbody".write(to: dir.appending(path: "a.md"), atomically: true, encoding: .utf8)
    try "---\ntitle: High later\npriority: 1  # high\ndue: 2026-11-02\n---\n".write(to: dir.appending(path: "b.md"), atomically: true, encoding: .utf8)
    try "---\ntitle: High soon\npriority: 1\ndue: 2026-10-30\n---\n".write(to: dir.appending(path: "c.md"), atomically: true, encoding: .utf8)
    try "---\ntitle: Done\npriority: 1\ndone: true\n---\n".write(to: dir.appending(path: "d.md"), atomically: true, encoding: .utf8)
    try "no front matter".write(to: dir.appending(path: "plain.md"), atomically: true, encoding: .utf8)
    XCTAssertEqual(ClairTodo.list(home: home).map(\.title), ["High soon", "High later", "plain", "Low", "Done"])
    XCTAssertEqual(ClairTodo.list(home: home)[1].priority, 1)
  }
}

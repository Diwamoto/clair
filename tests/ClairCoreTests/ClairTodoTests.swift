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

final class ClairTodoWriteTests: XCTestCase {
  func testSaveKeepsBodyAndUnknownKeys() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-todo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    var t = ClairTodo(path: ClairTodo.newPath(title: "a/b: \"c\"", home: home), title: "a/b: \"c\" #x", priority: 1, due: "2026-10-30", done: false)
    XCTAssertTrue(t.path.hasSuffix("/a-b- \"c\".md"))
    try t.save()
    try (String(contentsOf: URL(fileURLWithPath: t.path), encoding: .utf8) + "body\n").write(toFile: t.path, atomically: true, encoding: .utf8)
    XCTAssertEqual(ClairTodo.list(home: home), [t.with { $0.title = "a/b: 'c' #x" }])
    t.done = true; t.due = nil
    var text = try String(contentsOfFile: t.path, encoding: .utf8).replacingOccurrences(of: "done: false", with: "done: false\nowner: me")
    try text.write(toFile: t.path, atomically: true, encoding: .utf8)
    try t.save()
    text = try String(contentsOfFile: t.path, encoding: .utf8)
    XCTAssertTrue(text.hasSuffix("owner: me\n---\nbody\n"))
    XCTAssertFalse(text.contains("due:"))
    XCTAssertEqual(ClairTodo.list(home: home).first?.done, true)
    XCTAssertTrue(ClairTodo.newPath(title: "a/b: \"c\"", home: home).hasSuffix("-2.md"))
  }
}


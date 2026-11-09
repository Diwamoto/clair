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
  func testWorkflowKeysRoundTrip() {
    let t = ClairTodo.parse(path: "/t.md", text: "---\ntitle: x\nstage: impl\nlane: code\nretry: 2\npr: \"https://g/p#1\"\nkr: K1\n---\nbody")
    XCTAssertEqual([t.stage, t.lane, t.pr], ["impl", "code", "https://g/p#1"])
    XCTAssertEqual(t.retry, 2)
    XCTAssertEqual(t.extra, ["kr": "K1"])
    let again = ClairTodo.parse(path: "/t.md", text: t.with { $0.stage = "check-A"; $0.lane = nil }.render(onto: "---\nlane: code\nkr: K1\n---\nbody"))
    XCTAssertEqual(again.stage, "check-A"); XCTAssertNil(again.lane); XCTAssertEqual(again.pr, "https://g/p#1"); XCTAssertEqual(again.extra, ["kr": "K1"])
    XCTAssertNotNil(ClairTodo.invalid(priority: nil, due: nil, stage: "review"))
    XCTAssertNil(ClairTodo.invalid(priority: nil, due: nil, stage: "check-B", lane: "research", retry: 0))
  }

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


final class ClairTodoCommandTests: XCTestCase {
  func testUpdateKeepsUnknownKeysAndAppendsBody() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-todo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let path = ClairTodo.newPath(title: "KR work", home: home)
    try ClairTodo(path: path, title: "KR work").save(appendBody: "context")
    try "---\ntitle: KR work\npriority: 2\nkr: KR1\ndone: false\n---\ncontext\n".write(toFile: path, atomically: true, encoding: .utf8)
    XCTAssertTrue(ClairTodo.isTodoFile(path, home: home))
    let t = ClairTodo.parse(path: path, text: try String(contentsOfFile: path, encoding: .utf8))
    XCTAssertEqual(t.extra, ["kr": "KR1"])
    try t.with { $0.done = true }.save(appendBody: "result: shipped")
    let text = try String(contentsOfFile: path, encoding: .utf8)
    XCTAssertTrue(text.contains("kr: KR1") && text.contains("done: true"))
    XCTAssertTrue(text.hasSuffix("context\nresult: shipped\n"))
    XCTAssertEqual(ClairTodo.parse(path: path, text: text).json["kr"] as? String, "KR1")
  }

  func testMultilineTitleKeepsFrontMatter() {
    let old = "---\ntitle: a\npriority: 1\nkr: KR1\ndone: false\n---\nbody\n"
    let t = ClairTodo.parse(path: "/x.md", text: old).with { $0.title = "x\n---\nfoo" }
    let back = ClairTodo.parse(path: "/x.md", text: t.render(onto: old))
    XCTAssertEqual(back.title, "x --- foo")
    XCTAssertEqual(back.priority, 1)
    XCTAssertEqual(back.extra, ["kr": "KR1"])
  }

  func testInvalidValuesAndPaths() throws {
    XCTAssertNil(ClairTodo.invalid(priority: 1, due: "2026-11-05"))
    XCTAssertNil(ClairTodo.invalid(priority: nil, due: ""))
    XCTAssertNotNil(ClairTodo.invalid(priority: 4, due: nil))
    XCTAssertNotNil(ClairTodo.invalid(priority: nil, due: "2026-13-01"))
    XCTAssertNotNil(ClairTodo.invalid(priority: nil, due: "11/05"))
    let home = URL.temporaryDirectory
    XCTAssertFalse(ClairTodo.isTodoFile(ClairTodo.dir(home: home).path + "/../x.md", home: home))
    XCTAssertFalse(ClairTodo.isTodoFile("/etc/hosts", home: home))
  }

  func testCommandsRejectInvalidInputWithoutWriting() {
    let r = CommandRegistry.workbench
    var s = WorkbenchState()
    for (id, input) in [("todo.add", ["title": CommandArg.string("x"), "priority": .int(9)]),
                        ("todo.add", ["title": .string("x"), "due": .string("tomorrow")]),
                        ("todo.update", ["path": .string("/etc/hosts"), "done": .bool(true)])] {
      if case .success = r.execute(id, input, state: &s) { XCTFail("\(id) \(input) passed") }
    }
  }
}

import Foundation
import Testing

@testable import ClairWorkspace

/// #82: one card, one agent.
@Suite(.serialized) struct TodoRunTests {
  private static func home() throws -> URL {
    let home = URL.temporaryDirectory.appending(path: "clair-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: ClairTodo.dir(home: home), withIntermediateDirectories: true)
    return home
  }

  private static func card(_ home: URL, _ title: String, project: String? = nil) throws -> String {
    let path = ClairTodo.newPath(title: title, home: home)
    try ClairTodo(path: path, title: title).with { $0.project = project }.save(appendBody: "body of \(title)")
    return path
  }

  private static func read(_ path: String) throws -> ClairTodo {
    ClairTodo.parse(path: path, text: try String(contentsOfFile: path, encoding: .utf8))
  }

  private static func state(_ home: URL) throws -> WorkbenchState {
    let dir = home.appending(path: "repo")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var s = WorkbenchState()
    s.projects = [WorkbenchProject(name: "p", path: WorkbenchProject.normalized(dir.path)!)]
    s.project = "p"
    return s
  }

  private static func launch(_ s: WorkbenchState, _ key: String) -> AgentLaunch? {
    s.terminal(key).flatMap { s.withLayoutCopy($0.project).launches[$0.pane] }
  }

  @Test func needsAProjectFirst() throws {
    let home = try Self.home()
    var s = try Self.state(home)
    let path = try Self.card(home, "no project")
    do { try s.runTodo(path: path, home: home); Issue.record("ran without a project") }
    catch { #expect(error.message.contains("needsProject")) }
    #expect(try Self.read(path).agent == nil)
  }

  @Test func runStartsOneAgentThatOwnsTheCard() throws {
    let home = try Self.home()
    var s = try Self.state(home)
    let path = try Self.card(home, "fix thing", project: "p")
    try Self.read(path).with { $0.result = "failed"; $0.note = "old" }.save()
    try s.runTodo(path: path, home: home)
    let t = try Self.read(path)
    let key = try #require(t.agent)
    #expect(t.result == nil && t.note == nil, "a run starts the card over")
    let l = try #require(Self.launch(s, key))
    #expect(l.card == path && l.profile == "claude" && l.resume == nil)
    #expect(l.opening?.contains("カード: \(path)") == true && l.opening?.contains(ClairCardSkill.name) == true)
    #expect(s.cardAgent(key, path: path) && !s.cardAgent(key, path: "/other.md"))
    #expect(l.cwd == s.projects[0].path, "in the Project itself, no worktree")
  }

  @Test func aCardWithAConversationResumesIt() throws {
    let home = try Self.home()
    var s = try Self.state(home)
    let path = try Self.card(home, "again", project: "p")
    let session = "0b8f6f2e-6a4b-4c57-9a3e-2f1d2c3b4a59"
    try Self.read(path).with { $0.session = session; $0.result = "ok" }.save()
    try s.runTodo(path: path, home: home)
    let key = try #require(try Self.read(path).agent)
    let l = try #require(Self.launch(s, key))
    #expect(l.resume == session && l.opening == nil && l.card == path)
  }

  @Test func oldWorkflowKeysLoadAndStayInTheFile() throws {
    let text = "---\ntitle: \"old\"\npriority: 2\ndone: false\nstage: \"impl\"\nlane: \"code\"\nretry: \"1\"\ndifficulty: \"complex\"\nresult: \"ok\"\n---\nbody\n"
    let t = ClairTodo.parse(path: "/x.md", text: text)
    #expect(t.result == "ok" && t.extra["stage"] == "impl" && t.extra["difficulty"] == "complex")
    #expect(WorkbenchState().cardState(t, session: nil, sheet: false) == .done)
    let out = t.render(onto: text)
    #expect(out.contains("stage: \"impl\"") && out.contains("lane: \"code\"") && out.hasSuffix("body\n"))
  }

  @Test(arguments: [
    (ClairTodo(path: "/a.md", title: "a"), false, TodoBoardCard.State.idle, "inbox"),
    (ClairTodo(path: "/b.md", title: "b").with { $0.result = "ok" }, false, .done, "done"),
    (ClairTodo(path: "/c.md", title: "c", done: true), false, .done, "done"),
    (ClairTodo(path: "/d.md", title: "d").with { $0.result = "failed" }, false, .failed, "failed"),
    (ClairTodo(path: "/e.md", title: "e").with { $0.agent = "/gone#3" }, false, .unreported, "failed"),
    (ClairTodo(path: "/f.md", title: "f").with { $0.agent = "/gone#3" }, true, .blocked, "blocked"),
    (ClairTodo(path: "/g.md", title: "g").with { $0.result = "failed" }, true, .blocked, "blocked"),
  ])
  func columnsAreStates(todo: ClairTodo, sheet: Bool, want: TodoBoardCard.State, column: String) {
    let state = WorkbenchState().cardState(todo, session: nil, sheet: sheet)
    #expect(state == want)
    #expect(TodoBoardCard(todo: todo, project: nil, pane: nil, state: state).column == column)
  }

  @Test func onlyTheGUIRunsACard() {
    let ids = Set(CommandRegistry.workbench.commands.map(\.id))
    #expect(CommandRegistry.workbench.commands.first { $0.id == "todo.run" }?.aiAvailable == false)
    #expect(ids.isDisjoint(with: ["todo.move", "todo.skill", "concierge.open", "concierge.close", "concierge.archive", "settings.concierge"]))
  }

  @Test func boardArchivesOldDoneCardsAndSearches() throws {
    let home = try Self.home()
    let now = Date()
    func done(_ title: String, daysAgo: Double) throws -> ClairTodo {
      let path = try Self.card(home, title)
      return try Self.read(path).with {
        $0.result = "ok"; $0.doneAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * 86400))
      }
    }
    let recent = try done("recent", daysAgo: 1), old = try done("old", daysAgo: 8)
    let inbox = [ClairTodo(path: "/a.md", title: "low", priority: 3), ClairTodo(path: "/b.md", title: "high late", priority: 1, due: "2026-12-01"),
                 ClairTodo(path: "/c.md", title: "high soon", priority: 1, due: "2026-11-20")]
    let (cards, archived) = WorkbenchState().board(inbox + [recent, old], now: now)
    #expect(archived.map(\.todo.title) == ["old"])
    #expect(cards.map(\.todo.title) == ["high soon", "high late", "low", "recent"])
    #expect(TodoBoardCard.search(cards, "HIGH soon").map(\.todo.title) == ["high soon"])
    #expect(TodoBoardCard.search(cards, "body recent").map(\.todo.title) == ["recent"])
    #expect(TodoBoardCard.search(cards, "").count == cards.count)
  }

  @Test func cardSkillMatchesTheRepoFile() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../.agents/skills/\(ClairCardSkill.name)/SKILL.md")
    #expect(ClairCardSkill.markdown == (try String(contentsOf: repo, encoding: .utf8)))
  }
}

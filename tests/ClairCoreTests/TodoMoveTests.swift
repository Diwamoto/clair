import Foundation
import Testing

@testable import ClairWorkspace

@Suite(.serialized) struct TodoMoveTests {
  private static func home() throws -> URL {
    let home = URL.temporaryDirectory.appending(path: "clair-move-\(UUID().uuidString)")
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

  private static func state(root: String) -> (state: WorkbenchState, concierge: String) {
    var s = WorkbenchState()
    s.projects = [WorkbenchProject(name: "p", path: root)]
    s.project = "p"
    s.launches[-1] = AgentLaunch(profile: "claude", cwd: root, concierge: "sess")
    return (s, WorkbenchState.terminalKey(root, -1))
  }

  private static func repo(_ home: URL) throws -> String {
    let dir = home.appending(path: "repo")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let root = WorkbenchProject.normalized(dir.path)!
    for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"], ["commit", "--allow-empty", "-q", "-m", "init"]] {
      WorkbenchGit.run(root, args)
    }
    WorkbenchGit.worktreeBase = home.appending(path: "worktrees")
    return root
  }

  @Test(arguments: [
    (nil as String?, false, "inbox"), ("plan", false, "plan"), ("submit", false, "review"), ("check-A", false, "review"),
    ("check-B", false, "review"), ("review", false, "review"), ("impl", true, "done"), ("bogus", false, "inbox"),
  ])
  func columns(stage: String?, done: Bool, want: String) {
    #expect(ClairTodo(path: "/x.md", title: "x", done: done).with { $0.stage = stage }.column == want)
  }

  @Test func needsProjectBeforeLaunching() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var s = Self.state(root: root).state
    let path = try Self.card(home, "no project")
    for stage in ["plan", "impl", "review"] {
      do { try s.moveTodo(path: path, stage: stage, home: home); Issue.record("\(stage) launched without a project") }
      catch { #expect(error.message.contains("needsProject"), "\(stage)") }
    }
    #expect(try Self.read(path).stage == nil)
  }

  @Test func columnsStartAndRecordAnAgent() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var s = Self.state(root: root).state
    let path = try Self.card(home, "fix thing", project: "p")
    for stage in ["plan", "impl", "review"] {
      try s.moveTodo(path: path, stage: stage, home: home)
      let t = try Self.read(path)
      #expect(t.stage == stage && t.result == nil && t.note == nil, "\(stage)")
      #expect(t.agent.flatMap(s.terminal) != nil, "\(stage) records a live agent")
      #expect(TodoBoardCard.history(try String(contentsOfFile: path, encoding: .utf8)).last?.hasPrefix(stage) == true)
    }
    #expect(try Self.read(path).branch == "todo-fix-thing")
  }

  @Test func doneRefusesADirtyWorktreeUnlessForced() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var s = Self.state(root: root).state
    let path = try Self.card(home, "ship", project: "p")
    try s.moveTodo(path: path, stage: "impl", home: home)
    let wt = try #require(s.projects.first { $0.origin == root })
    try "x".write(toFile: wt.path + "/new.txt", atomically: true, encoding: .utf8)
    do { try s.moveTodo(path: path, stage: "done", home: home); Issue.record("dirty worktree was removed") }
    catch { #expect(error.message.contains("dirtyWorktree")) }
    #expect(try Self.read(path).stage == "impl")
    #expect(FileManager.default.fileExists(atPath: wt.path))
    try s.moveTodo(path: path, stage: "done", force: true, home: home)
    let t = try Self.read(path)
    #expect(t.column == "done" && t.doneAt != nil && t.agent == nil)
    #expect(!FileManager.default.fileExists(atPath: wt.path))
    #expect(!WorkbenchGit.branchExists(root, "todo-ship"))
  }

  @Test func onlyAConciergeTerminalIsOne() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var (s, concierge) = Self.state(root: root)
    s.tree.splitFocused(.horizontal, kind: .terminal)
    let pane = s.tree.focused
    s.launches[pane] = AgentLaunch(profile: "claude", cwd: root, parent: concierge)
    let cases: [(key: String?, want: Bool)] = [
      (concierge, true), (WorkbenchState.terminalKey(root, pane), false), (nil, false), ("/nowhere#1", false),
    ]
    for c in cases { #expect(s.isConcierge(c.key) == c.want, "\(c.key ?? "nil")") }
  }

  @Test func conciergeCapNeedsTheApprovalCard() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var (s, concierge) = Self.state(root: root)
    let registry = CommandRegistry.workbench
    s.toggles[WorkbenchState.autoApproveKey("agent.launch")] = true
    let path = try Self.card(home, "capped", project: "p")
    func risk(_ stage: String) -> CommandRisk? {
      try? registry.preflight("todo.update", ["path": .string(path), "stage": .string(stage), "parent": .string(concierge)], s).get()
    }
    for n in 0..<WorkbenchState.conciergeLaunchCap {
      #expect(s.autoApproves("agent.launch", risk: .external, caller: concierge), "launch \(n + 1) skips the card")
      #expect(risk("plan") != .external, "launch \(n + 1) skips the card via todo.update")
      s.conciergeLaunches[concierge, default: 0] += 1
    }
    #expect(!s.autoApproves("agent.launch", risk: .external, caller: concierge))
    #expect(risk("plan") == .external)
    #expect(risk("done") != .external)
    s.conciergeLaunches[concierge] = nil
    #expect(s.autoApproves("agent.launch", risk: .external, caller: concierge))
  }

  @Test func todoMoveIsNotAvailableToAI() {
    #expect(CommandRegistry.workbench.commands.first { $0.id == "todo.move" }?.aiAvailable == false)
    #expect(CommandRegistry.workbench.commands.first { $0.id == "todo.skill" }?.aiAvailable == true)
  }

  @Test func skillChoiceGoesStaleWhenTheFolderListChanges() throws {
    let home = try Self.home(), root = try Self.repo(home)
    try FileManager.default.createDirectory(atPath: root + "/.claude/skills/house", withIntermediateDirectories: true)
    #expect(ClairColumnSkills.choice(project: "p", stage: "impl", root: root, home: home) == nil)
    try ClairColumnSkills.record(project: "p", stage: "impl", skill: "house", root: root, home: home)
    #expect(ClairColumnSkills.choice(project: "p", stage: "impl", root: root, home: home) == "house")
    #expect(ClairColumnSkills.choice(project: "p", stage: "plan", root: root, home: home) == nil)
    try FileManager.default.createDirectory(atPath: root + "/.claude/skills/other", withIntermediateDirectories: true)
    #expect(ClairColumnSkills.choice(project: "p", stage: "impl", root: root, home: home) == nil)
    #expect(ClairColumnSkills.isValid("none", root: root, home: home) && ClairColumnSkills.isValid("other", root: root, home: home))
    #expect(!ClairColumnSkills.isValid("../evil", root: root, home: home))
  }

  @Test func boardArchivesOldDoneCardsAndSearches() throws {
    let home = try Self.home()
    let now = Date()
    func done(_ title: String, daysAgo: Double) throws -> ClairTodo {
      let path = try Self.card(home, title)
      return try Self.read(path).with {
        $0.stage = "done"; $0.doneAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * 86400))
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

  @Test func columnSkillsMatchTheRepoFiles() throws {
    for s in ClairColumnSkill.all {
      let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../.agents/skills/\(s.name)/SKILL.md")
      #expect(s.markdown == (try String(contentsOf: repo, encoding: .utf8)), "\(s.name)")
    }
  }
}

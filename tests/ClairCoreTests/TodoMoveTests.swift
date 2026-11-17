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

  @Test func researchRunsAnAgentAndKeepsTheCardInInbox() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var s = Self.state(root: root).state
    let path = try Self.card(home, "maybe", project: "p")
    try s.moveTodo(path: path, stage: "research", home: home)
    let t = try Self.read(path)
    #expect(t.column == "inbox" && t.stage == nil && t.branch == nil)
    let agent = try #require(t.agent)
    #expect(s.terminal(agent) != nil)
    #expect(s.board([t]).cards.first?.pane != nil, "the Inbox card shows its research pane")
    try s.moveTodo(path: path, stage: "plan", home: home)
    #expect(s.terminal(agent) == nil, "moving on closes the research agent")
    do { try s.moveTodo(path: path, stage: "research", home: home); Issue.record("research left a plan card") }
    catch { #expect(error.message.contains("Inbox")) }
  }

  @Test func boardNewsGoesToTheConciergeThatMovedTheCard() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var (s, concierge) = Self.state(root: root)
    let mine = try Self.card(home, "mine", project: "p"), owners = try Self.card(home, "owners", project: "p")
    try s.moveTodo(path: mine, stage: "plan", concierge: concierge, home: home)
    try s.moveTodo(path: owners, stage: "plan", home: home)
    let cards = s.board([try Self.read(mine), try Self.read(owners)]).cards
    #expect(cards.map { s.boardConcierge($0) } == [concierge, nil])
  }

  @Test func aMoveClosesOnlyTheCardsOwnAgent() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var (s, concierge) = Self.state(root: root)
    let path = try Self.card(home, "forged", project: "p")
    try ClairTodo.parse(path: path, text: try String(contentsOfFile: path, encoding: .utf8)).with { $0.agent = concierge }.save(appendBody: nil)
    try s.moveTodo(path: path, stage: "inbox", home: home)
    #expect(s.terminal(concierge) != nil, "a forged agent= must not close another pane")
    try s.moveTodo(path: path, stage: "plan", home: home)
    let plan = try #require(try Self.read(path).agent)
    try s.moveTodo(path: path, stage: "inbox", home: home)
    #expect(s.terminal(plan) == nil, "the card's own agent is closed")
  }

  @Test func aFailedMoveDoesNotKeepTheClosedAgent() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var s = Self.state(root: root).state
    let path = try Self.card(home, "locked", project: "p")
    try s.moveTodo(path: path, stage: "impl", home: home)
    let agent = try #require(try Self.read(path).agent)
    let wt = try #require(s.projects.first { $0.origin == root })
    WorkbenchGit.run(root, ["worktree", "lock", wt.path])  // a single --force does not remove a locked worktree
    do { try s.moveTodo(path: path, stage: "done", force: true, home: home); Issue.record("locked worktree was removed") } catch {}
    let t = try Self.read(path)
    #expect(s.terminal(agent) == nil && t.agent == nil && t.stage == "impl")
  }

  @Test func aClosedWorktreeProjectIsStillTheCards() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var s = Self.state(root: root).state
    let path = try Self.card(home, "closed wt", project: "p")
    try s.moveTodo(path: path, stage: "impl", home: home)
    let wt = try #require(s.projects.first { $0.origin == root })
    s.projects.removeAll { $0.path == wt.path }  // the owner closed the worktree's Project
    try s.moveTodo(path: path, stage: "review", home: home)
    #expect(try Self.read(path).branch == "todo-closed-wt")
    #expect(s.projects.contains { $0.path == wt.path && $0.origin == root }, "review reopens the worktree")
    s.projects.removeAll { $0.path == wt.path }
    try s.moveTodo(path: path, stage: "done", home: home)
    #expect(!FileManager.default.fileExists(atPath: wt.path))
    #expect(!WorkbenchGit.branchExists(root, "todo-closed-wt"))
  }

  @Test func doneKeepsABranchTheCardDidNotMake() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var s = Self.state(root: root).state
    let path = try Self.card(home, "forged branch", project: "p")
    for other in ["keep", "todo-another-card"] {  // any branch, or another card's
      WorkbenchGit.run(root, ["branch", other])
      try Self.read(path).with { $0.branch = other; $0.done = false }.save(appendBody: nil)
      try s.moveTodo(path: path, stage: "done", force: true, home: home)
      #expect(WorkbenchGit.branchExists(root, other), "\(other)")
    }
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

  /// ADR-0028 Validation: a child's `todo.update stage=` cannot pass as the concierge, so it only records the stage.
  @Test func aChildCannotClaimToBeTheConcierge() throws {
    let home = try Self.home(), root = try Self.repo(home)
    let (_, concierge) = Self.state(root: root)
    let child = WorkbenchState.terminalKey(root, 7)
    let spoofed = WorkbenchIPCRequest(command: "todo.update", input: ["stage": .string("impl"), "parent": .string(concierge)], caller: child)
    #expect(spoofed.callerAsParent().input["parent"] == .string(child))
    #expect(WorkbenchIPCRequest(command: "todo.update", input: ["parent": .string(concierge)]).callerAsParent().input["parent"] == nil)
  }

  @Test func conciergeCapNeedsTheApprovalCard() throws {
    let home = try Self.home(), root = try Self.repo(home)
    var (s, concierge) = Self.state(root: root)
    let registry = CommandRegistry.workbench
    s.toggles[WorkbenchState.autoApproveKey("agent.launch")] = true
    let path = try Self.card(home, "capped", project: "p")
    func overCap(_ stage: String) -> Bool { s.conciergeOverCap(["path": .string(path), "stage": .string(stage), "parent": .string(concierge)]) }
    for n in 0..<WorkbenchState.conciergeLaunchCap {
      #expect(s.autoApproves("agent.launch", risk: .external, caller: concierge), "launch \(n + 1) skips the card")
      #expect(!overCap("plan"), "launch \(n + 1) skips the card via todo.update")
      s.conciergeLaunches[concierge, default: 0] += 1
    }
    #expect(!s.autoApproves("agent.launch", risk: .external, caller: concierge))
    #expect(overCap("plan"))
    #expect(!overCap("done"))
    // Over the cap, a path that is not a TODO is still refused before any card: approving it must not write that file.
    let outside = home.appending(path: "notes.md").path
    try "keep".write(toFile: outside, atomically: true, encoding: .utf8)
    #expect(throws: CommandError.self) {
      try registry.preflight("todo.update", ["path": .string(outside), "stage": .string("plan"), "parent": .string(concierge)], s).get()
    }
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

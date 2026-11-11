import XCTest

@testable import ClairWorkspace

/// ADR-0020: one concierge for all of Clair; its children are agents launched with it as `parent`.
final class WorkbenchConciergeTests: XCTestCase {
  let r = CommandRegistry.workbench

  override func setUp() {
    Concierge.approvals = UserDefaults(suiteName: "clair-concierge-\(UUID().uuidString)")!
  }
  override func tearDown() { Concierge.approvals = .standard }

  func opened() throws -> (WorkbenchState, String) {
    let dir = URL.temporaryDirectory.appending(path: "clair-concierge-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var s = WorkbenchState()
    try r.execute("project.open", ["path": .string(dir.path)], state: &s).get()
    s.conciergeCwd = dir.path
    Concierge.approve(Concierge.fingerprint(prompt: "", cwd: dir.path))  // as the GUI does after the card
    return (s, dir.path)
  }

  func testOpenIsGUIOnlyStartsOnceOffTheLayout() throws {
    var (s, root) = try opened()
    XCTAssertEqual(r.commands.first { $0.id == "concierge.open" }?.aiAvailable, false)
    XCTAssertEqual(r.execute("concierge.open", state: &s).failure?.code, .confirmationRequired)
    let tree = s.tree
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    let c = try XCTUnwrap(s.concierge())
    XCTAssertEqual(c.pane, Concierge.pane)
    XCTAssertEqual(c.key, WorkbenchState.terminalKey(root, Concierge.pane))
    XCTAssertEqual(s.launches[Concierge.pane]?.cwd, root)
    XCTAssertTrue(AgentProfile.isSessionID(c.session))
    // Never drawn: the layout is untouched, and closing panes or re-entering the Project keeps it.
    XCTAssertEqual(s.tree, tree)
    XCTAssertNotNil(s.terminal(c.key))
    try r.execute("terminal.show", state: &s).get()
    try r.execute("pane.close", confirmed: true, state: &s).get()
    XCTAssertEqual(s.concierge()?.session, c.session)
    // Its chat already runs: no second terminal for it.
    try r.execute("concierge.open", ["chat": .string(c.session)], confirmed: true, state: &s).get()
    XCTAssertEqual(s.launches.values.filter { $0.concierge != nil }.count, 1)
  }

  func testItsFolderBecomesAProjectWhereChildrenStart() throws {
    var (s, root) = try opened()
    let shown = s.project
    let folder = URL(fileURLWithPath: root).deletingLastPathComponent().appending(path: "concierge-\(UUID().uuidString)").path
    s.conciergeCwd = folder
    Concierge.approve(Concierge.fingerprint(prompt: "", cwd: folder))
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    let c = try XCTUnwrap(s.concierge())
    XCTAssertEqual(s.project, shown)
    XCTAssertEqual(s.projects.first { $0.name == c.project }?.path, c.launch.cwd)
    try r.execute("agent.launch", ["profile": .string("claude"), "prompt": .string("x"), "parent": .string(c.key)], confirmed: true, state: &s).get()
    XCTAssertEqual(s.conciergeChildren().map(\.launch.cwd), [c.launch.cwd])
    XCTAssertEqual(WorkbenchState().conciergeDir, Concierge.defaultCwd())
  }

  func testChildrenAreAgentsWhoseParentIsTheConcierge() throws {
    var (s, root) = try opened()
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    let pane = Concierge.pane
    let key = WorkbenchState.terminalKey(root, pane)
    try r.execute("agent.launch", ["profile": .string("codex"), "prompt": .string("fix login"), "parent": .string(key)], confirmed: true, state: &s).get()
    try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get()  // not a child
    let children = s.conciergeChildren()
    XCTAssertEqual(children.map(\.launch.prompt), ["fix login"])
  }

  func testOnlyTheConciergeLaunchesIntoAnotherProject() throws {
    var (s, root) = try opened()
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    let pane = Concierge.pane
    guard case .pane(let plain) = try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get() else { return XCTFail() }
    let home = s.project
    let other = URL.temporaryDirectory.appending(path: "clair-concierge-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try r.execute("project.open", ["path": .string(other.path)], state: &s).get()
    let target = try XCTUnwrap(s.projects.first { $0.path == other.path }?.name)
    try r.execute("project.open", ["path": .string(root)], state: &s).get()
    XCTAssertEqual(s.project, home)

    let key = WorkbenchState.terminalKey(root, pane)
    let launched = try r.execute("agent.launch", ["profile": .string("codex"), "prompt": .string("fix login"),
      "parent": .string(key), "project": .string(target)], confirmed: true, state: &s).get()
    guard case .text(let child) = launched, let t = s.terminal(child) else { return XCTFail("\(launched)") }
    XCTAssertEqual(t.project, target)
    XCTAssertEqual(s.project, home)
    XCTAssertEqual(s.withLayoutCopy(target).launches[t.pane]?.cwd, other.path)
    XCTAssertEqual(s.conciergeChildren().map(\.launch.prompt), ["fix login"])

    let denied = r.execute("agent.launch", ["profile": .string("codex"), "parent": .string(WorkbenchState.terminalKey(root, plain)),
      "project": .string(target)], confirmed: true, state: &s)
    XCTAssertEqual(denied.failure?.code, .preconditionFailed)
  }

  func testCommandFixesSessionAndAppendsSettingsPrompt() throws {
    var (s, root) = try opened()
    try r.execute("settings.concierge", ["prompt": .string("テストは make test で")], confirmed: true, state: &s).get()
    Concierge.approve(Concierge.fingerprint(prompt: "テストは make test で", cwd: root))
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    let pane = Concierge.pane
    s.launches[pane]?.concierge = "abc-123"
    let cmd = try XCTUnwrap(s.launches[pane]?.command)
    XCTAssertTrue(cmd.hasPrefix("claude --session-id abc-123 --append-system-prompt '"), cmd)
    XCTAssertTrue(cmd.contains("テストは make test で"))
    XCTAssertTrue(cmd.contains("agent output lines=40"))
    // A hostile session id never reaches the shell.
    XCTAssertEqual(AgentLaunch(profile: "claude", cwd: root, concierge: "x; rm -rf ~").command, "claude")
  }

  func testSettingsAreUserOnlyAndCwdMustBeADirectory() throws {
    var (s, root) = try opened()
    XCTAssertEqual(r.commands.first { $0.id == "settings.concierge" }?.aiAvailable, false)
    XCTAssertEqual(r.execute("settings.concierge", ["cwd": .string("relative")], confirmed: true, state: &s).failure?.code, .preconditionFailed)
    let other = URL.temporaryDirectory.appending(path: "clair-cwd-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
    try r.execute("settings.concierge", ["cwd": .string(other)], confirmed: true, state: &s).get()
    Concierge.approve(Concierge.fingerprint(prompt: "", cwd: other))
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    XCTAssertEqual(s.concierge()?.launch.cwd, WorkbenchProject.normalized(other))
    XCTAssertNotEqual(other, root)
  }

  func testConciergeIsFoundFromAnotherProject() throws {
    var (s, root) = try opened()
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    let pane = Concierge.pane
    let second = URL.temporaryDirectory.appending(path: "clair-concierge-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try r.execute("project.open", ["path": .string(second.path)], state: &s).get()
    let host = try XCTUnwrap(s.projects.first { $0.path == root }?.name)
    XCTAssertNotEqual(s.project, host)
    XCTAssertEqual(s.concierge()?.project, host)
    // Opening it again neither switches Project nor starts a second one.
    let shown = s.project
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    XCTAssertEqual(s.project, shown); XCTAssertEqual(s.concierge()?.pane, pane)
  }

  func testNewConciergeNeedsTheCurrentFingerprintApproved() throws {
    var (s, root) = try opened()
    Concierge.approvals.removeObject(forKey: "approvedConcierge")
    XCTAssertEqual(r.execute("concierge.open", confirmed: true, state: &s).failure?.code, .preconditionFailed)
    Concierge.approve(Concierge.fingerprint(prompt: "", cwd: root))
    // An approval for another folder does not carry over.
    XCTAssertEqual(r.execute("concierge.open", ["cwd": .string("/tmp")], confirmed: true, state: &s).failure?.code, .preconditionFailed)
    try r.execute("concierge.open", ["cwd": .string(root)], confirmed: true, state: &s).get()
    // A changed source asks again — but only for a new concierge, not to focus the running one.
    try r.execute("settings.concierge", ["prompt": .string("new")], confirmed: true, state: &s).get()
    try r.execute("concierge.open", confirmed: true, state: &s).get()
  }

  func testFingerprintChangesWithWhatTheConciergeReads() throws {
    let (_, root) = try opened()
    let a = Concierge.fingerprint(prompt: "p", cwd: root)
    XCTAssertEqual(a, Concierge.fingerprint(prompt: "p", cwd: root))
    XCTAssertNotEqual(a, Concierge.fingerprint(prompt: "q", cwd: root))
    try FileManager.default.createDirectory(atPath: root + "/.claude/skills/x", withIntermediateDirectories: true)
    try "v1".write(toFile: root + "/.claude/skills/x/SKILL.md", atomically: true, encoding: .utf8)
    let b = Concierge.fingerprint(prompt: "p", cwd: root)
    XCTAssertNotEqual(a, b)
    try "v2".write(toFile: root + "/.claude/skills/x/SKILL.md", atomically: true, encoding: .utf8)
    XCTAssertNotEqual(b, Concierge.fingerprint(prompt: "p", cwd: root))
    try "c".write(toFile: root + "/CLAUDE.md", atomically: true, encoding: .utf8)
    XCTAssertNotEqual(b, Concierge.fingerprint(prompt: "p", cwd: root))
  }

  func testMessageSentBeforeStartBecomesTheOpeningPrompt() throws {
    var (s, _) = try opened()
    try r.execute("concierge.open", ["message": .string("README を直して")], confirmed: true, state: &s).get()
    let pane = Concierge.pane
    let cmd = try XCTUnwrap(s.launches[pane]?.command)
    XCTAssertTrue(cmd.hasSuffix(" 'README を直して'"), cmd)
    XCTAssertFalse(AgentLaunch(profile: "claude", cwd: "/x", concierge: "abc").command.hasSuffix("'README を直して'"))
  }

  func testNextConciergeKeepsTheChatOfItsFolderAcrossRestarts() throws {
    var (s, root) = try opened()
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    let first = try XCTUnwrap(s.concierge())
    XCTAssertEqual(s.conciergeChats, [first.session])
    // Launches are not persisted: a restart (or a settings change) drops the running concierge.
    let file = URL.temporaryDirectory.appending(path: "clair-ws-\(UUID().uuidString).json")
    try s.save(to: file)
    var restored = try XCTUnwrap(WorkbenchState.restore(from: file, scanFiles: false))
    XCTAssertNil(restored.concierge())
    XCTAssertEqual(restored.conciergeChats, [first.session])
    try r.execute("concierge.open", ["message": .string("続けて"), "chat": .string(first.session)], confirmed: true, state: &restored).get()
    XCTAssertEqual(restored.concierge()?.session, first.session)
    // Another folder has its own chat.
    restored.withLayout(first.project) { $0.launches[Concierge.pane] = nil }
    let other = URL(fileURLWithPath: root).deletingLastPathComponent().appending(path: "concierge-\(UUID().uuidString)").path
    restored.conciergeCwd = other
    Concierge.approve(Concierge.fingerprint(prompt: "", cwd: other))
    try r.execute("concierge.open", confirmed: true, state: &restored).get()
    XCTAssertNotEqual(restored.concierge()?.session, first.session)
  }

  func testChatsRunSideBySideAndAChangedSettingStartsOver() throws {
    var (s, _) = try opened()
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    let both = s.concierges()
    XCTAssertEqual(both.map(\.pane), [-1, -2])
    XCTAssertEqual(s.conciergeChats, both.map(\.session))
    XCTAssertNotNil(s.terminal(both[1].key))
    try r.execute("agent.launch", ["profile": .string("claude"), "prompt": .string("x"), "parent": .string(both[1].key)], confirmed: true, state: &s).get()
    XCTAssertEqual(s.conciergeChildren().map(\.launch.parent), [both[1].key])
    // `/clear` in one chat: the hook's new session replaces that chat's entry only.
    let cleared = UUID().uuidString.lowercased()
    try r.execute("agent.report", ["state": .string("done"), "session": .string(cleared), "parent": .string(both[0].key)], state: &s).get()
    XCTAssertEqual(s.conciergeChats, [cleared, both[1].session])
    XCTAssertEqual(s.concierge(chat: cleared)?.pane, -1)
    try r.execute("concierge.close", ["chat": .string(both[1].session)], confirmed: true, state: &s).get()
    XCTAssertEqual(s.conciergeChats, [cleared])
    XCTAssertEqual(s.concierges().map(\.pane), [-1])
    try r.execute("settings.concierge", ["prompt": .string("new")], confirmed: true, state: &s).get()
    XCTAssertEqual(s.conciergeChats, [])
  }

  func testResumedChatCarriesTheRequestThatWokeIt() {
    let resumed = AgentLaunch(profile: "claude", cwd: "/x", resume: "abc", concierge: "abc", opening: "続けて").command
    XCTAssertTrue(resumed.hasPrefix("claude --resume abc "), resumed)
    XCTAssertTrue(resumed.hasSuffix(" '続けて'"), resumed)
  }

  func testTranscriptFileIsFoundByIdUnderAnyProjectSlug() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-home-\(UUID().uuidString)")
    let dir = home.appending(path: ".claude/projects/-Users-x-repo")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    XCTAssertNil(Concierge.transcriptFile(session: "s1", home: home))
    try Data().write(to: dir.appending(path: "s1.jsonl"))
    XCTAssertEqual(Concierge.transcriptFile(session: "s1", home: home)?.lastPathComponent, "s1.jsonl")
  }
}

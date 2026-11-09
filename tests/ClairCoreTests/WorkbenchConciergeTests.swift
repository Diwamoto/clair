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
    Concierge.approve(Concierge.fingerprint(prompt: "", cwd: dir.path))  // as the GUI does after the card
    return (s, dir.path)
  }

  func testOpenIsGUIOnlyStartsOnceThenFocuses() throws {
    var (s, root) = try opened()
    XCTAssertEqual(r.commands.first { $0.id == "concierge.open" }?.aiAvailable, false)
    XCTAssertEqual(r.execute("concierge.open", state: &s).failure?.code, .confirmationRequired)
    guard case .pane(let pane) = try r.execute("concierge.open", confirmed: true, state: &s).get() else { return XCTFail() }
    let c = try XCTUnwrap(s.concierge())
    XCTAssertEqual(c.pane, pane)
    XCTAssertEqual(s.launches[pane]?.cwd, root)
    XCTAssertTrue(AgentProfile.isSessionID(c.session))
    // Already running: focuses the same pane, no second concierge.
    s.tree.splitFocused(.horizontal, kind: .terminal)
    guard case .pane(let again) = try r.execute("concierge.open", confirmed: true, state: &s).get() else { return XCTFail() }
    XCTAssertEqual(again, pane)
    XCTAssertEqual(s.tree.focused, pane)
    XCTAssertEqual(s.launches.values.filter { $0.concierge != nil }.count, 1)
  }

  func testChildrenAreAgentsWhoseParentIsTheConcierge() throws {
    var (s, root) = try opened()
    guard case .pane(let pane) = try r.execute("concierge.open", confirmed: true, state: &s).get() else { return XCTFail() }
    let key = WorkbenchState.terminalKey(root, pane)
    try r.execute("agent.launch", ["profile": .string("codex"), "prompt": .string("fix login"), "parent": .string(key)], confirmed: true, state: &s).get()
    try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get()  // not a child
    let children = s.conciergeChildren()
    XCTAssertEqual(children.map(\.launch.prompt), ["fix login"])
  }

  func testCommandFixesSessionAndAppendsSettingsPrompt() throws {
    var (s, root) = try opened()
    try r.execute("settings.concierge", ["prompt": .string("テストは make test で")], confirmed: true, state: &s).get()
    Concierge.approve(Concierge.fingerprint(prompt: "テストは make test で", cwd: root))
    guard case .pane(let pane) = try r.execute("concierge.open", confirmed: true, state: &s).get() else { return XCTFail() }
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
    guard case .pane(let pane) = try r.execute("concierge.open", confirmed: true, state: &s).get() else { return XCTFail() }
    XCTAssertEqual(s.launches[pane]?.cwd, other)
    XCTAssertNotEqual(other, root)
  }

  func testConciergeIsFoundFromAnotherProject() throws {
    var (s, root) = try opened()
    guard case .pane(let pane) = try r.execute("concierge.open", confirmed: true, state: &s).get() else { return XCTFail() }
    let second = URL.temporaryDirectory.appending(path: "clair-concierge-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try r.execute("project.open", ["path": .string(second.path)], state: &s).get()
    let host = try XCTUnwrap(s.projects.first { $0.path == root }?.name)
    XCTAssertNotEqual(s.project, host)
    XCTAssertEqual(s.concierge()?.project, host)
    // Opening it again goes back to its host instead of starting a second one.
    try r.execute("concierge.open", confirmed: true, state: &s).get()
    XCTAssertEqual(s.project, host); XCTAssertEqual(s.tree.focused, pane)
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
    guard case .pane(let pane) = try r.execute("concierge.open", ["message": .string("README を直して")], confirmed: true, state: &s).get()
    else { return XCTFail() }
    let cmd = try XCTUnwrap(s.launches[pane]?.command)
    XCTAssertTrue(cmd.hasSuffix(" 'README を直して'"), cmd)
    XCTAssertFalse(AgentLaunch(profile: "claude", cwd: "/x", concierge: "abc").command.hasSuffix("'README を直して'"))
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

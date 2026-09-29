import XCTest

@testable import ClairWorkspace

/// ADR-0020: one concierge per Project; its children are agents launched with it as `parent`.
final class WorkbenchConciergeTests: XCTestCase {
  let r = CommandRegistry.workbench

  func opened() throws -> (WorkbenchState, String) {
    let dir = URL.temporaryDirectory.appending(path: "clair-concierge-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var s = WorkbenchState()
    try r.execute("project.open", ["path": .string(dir.path)], state: &s).get()
    return (s, dir.path)
  }

  func testOpenIsGUIOnlyStartsOnceThenFocuses() throws {
    var (s, root) = try opened()
    XCTAssertEqual(r.commands.first { $0.id == "concierge.open" }?.aiAvailable, false)
    XCTAssertEqual(r.execute("concierge.open", state: &s).failure?.code, .confirmationRequired)
    guard case .pane(let pane) = try r.execute("concierge.open", confirmed: true, state: &s).get() else { return XCTFail() }
    let c = try XCTUnwrap(s.concierge(in: s.project))
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
    let children = s.conciergeChildren(in: s.project)
    XCTAssertEqual(children.map(\.launch.prompt), ["fix login"])
  }

  func testCommandFixesSessionAndAppendsProjectInstructions() throws {
    let (_, root) = try opened()
    try FileManager.default.createDirectory(atPath: root + "/.clair", withIntermediateDirectories: true)
    try "テストは make test で".write(toFile: root + "/" + Concierge.instructionsPath, atomically: true, encoding: .utf8)
    let cmd = AgentLaunch(profile: "claude", cwd: root, concierge: "abc-123").command
    XCTAssertTrue(cmd.hasPrefix("claude --session-id abc-123 --append-system-prompt '"), cmd)
    XCTAssertTrue(cmd.contains("テストは make test で"))
    XCTAssertTrue(cmd.contains("agent.output --lines 40"))
    // A hostile session id never reaches the shell.
    XCTAssertEqual(AgentLaunch(profile: "claude", cwd: root, concierge: "x; rm -rf ~").command, "claude")
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

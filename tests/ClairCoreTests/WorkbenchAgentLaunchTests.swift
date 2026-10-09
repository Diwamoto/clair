import XCTest

@testable import ClairWorkspace

/// V07: agent launch profiles run as raw terminals in the Project root.
final class WorkbenchAgentLaunchTests: XCTestCase {
  let r = CommandRegistry.workbench

  func opened() throws -> (WorkbenchState, String) {
    let dir = URL.temporaryDirectory.appending(path: "clair-v07-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var s = WorkbenchState()
    try r.execute("project.open", ["path": .string(dir.path)], state: &s).get()
    s.tree = PaneTree()  // editor | agent / terminal: the layout these tests place into, not the single-editor default
    return (s, dir.path)
  }

  func testLaunchNeedsConfirmationAndIsAIAvailableForV16() throws {
    var (s, _) = try opened()
    XCTAssertEqual(r.commands.first { $0.id == "agent.launch" }?.aiAvailable, true)
    XCTAssertEqual(r.execute("agent.launch", ["profile": .string("claude")], state: &s).failure?.code, .confirmationRequired)
    XCTAssertTrue(s.launches.isEmpty)
    XCTAssertEqual(r.execute("agent.launch", ["profile": .string("rm")], confirmed: true, state: &s).failure?.code, .invalidInput)
  }

  func testMultipleLaunchesGetOwnPanesInProjectRootAndCloseDropsThem() throws {
    var (s, root) = try opened()
    s.panesClosed = true
    let a = try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get()
    XCTAssertFalse(s.panesClosed)
    let b = try r.execute("agent.launch", ["profile": .string("codex")], confirmed: true, state: &s).get()
    guard case .pane(let ida) = a, case .pane(let idb) = b else { return XCTFail() }
    XCTAssertNotEqual(ida, idb)
    XCTAssertEqual(s.launches[ida], AgentLaunch(profile: "claude", cwd: root))
    XCTAssertEqual(s.launches[idb]?.command, "codex")
    XCTAssertTrue(s.tree.leaves.contains { $0.id == idb && $0.kind == .terminal })
    try r.execute("pane.close", state: &s).get()
    XCTAssertNil(s.launches[idb])
    XCTAssertNotNil(s.launches[ida])
  }

  func testResumeUsesProviderCommandAndRejectsUnsafeIDs() throws {
    XCTAssertEqual(AgentLaunch(profile: "claude", cwd: "/x", resume: "abc-123").command, "claude --resume abc-123")
    XCTAssertEqual(AgentLaunch(profile: "codex", cwd: "/x", resume: "abc-123").command, "codex resume abc-123")
    XCTAssertEqual(AgentLaunch(profile: "opencode", cwd: "/x", resume: "ses_1").command, "opencode --session ses_1")
    var (s, _) = try opened()
    XCTAssertEqual(r.execute("agent.launch", ["profile": .string("claude"), "resume": .string("x; rm -rf ~")], confirmed: true, state: &s).failure?.code, .preconditionFailed)
    XCTAssertTrue(s.launches.isEmpty)
  }

  func testLaunchesAreNotPersisted() throws {
    var (s, _) = try opened()
    try r.execute("agent.launch", ["profile": .string("opencode")], confirmed: true, state: &s).get()
    let url = URL.temporaryDirectory.appending(path: "clair-v07-\(UUID().uuidString).json")
    try s.save(to: url)
    XCTAssertTrue(try XCTUnwrap(WorkbenchState.restore(from: url)).launches.isEmpty)
  }

  // Mobile registered-profile launch = this same command over V02 IPC: only a profile id, cwd is host-resolved.
  func testClientCannotChooseCwdOrCommand() throws {
    var (s, root) = try opened()
    _ = r.execute("agent.launch", ["profile": .string("claude"), "cwd": .string("/etc"), "command": .string("rm")], confirmed: true, state: &s)
    XCTAssertTrue(s.launches.values.allSatisfy { $0.cwd == root && $0.command == "claude" })
  }

  func testPaletteListsProfiles() throws {
    let (s, _) = try opened()
    XCTAssertEqual(r.paletteItems(.commands, query: "codex", state: s).map(\.input).filter { $0["profile"] != nil }, [["profile": .string("codex")]])
  }

  // agent registry: the settings "既定のAgent" picker and agent.launch's allowed profiles both
  // read the same AgentProfile registry, so a newly registered agent needs no change beyond `all`.
  func testDefaultAgentChoicesMatchRegisteredProfilesAndAreLaunchable() throws {
    XCTAssertEqual(WorkbenchState.choiceOptions["defaultAgent"], AgentProfile.all.map(\.id))
    var (s, _) = try opened()
    for id in ["gemini", "cursor-agent", "copilot", "aider"] {
      s.panesClosed = true
      let result = try r.execute("agent.launch", ["profile": .string(id)], confirmed: true, state: &s).get()
      guard case .pane(let pane) = result else { return XCTFail() }
      XCTAssertEqual(s.launches[pane]?.command, id)
    }
  }

  // Dragging a launched pane's header onto another pane moves the running session with it.
  func testSwapMovesLaunchToTheOtherPane() throws {
    var (s, _) = try opened()
    let a = try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get()
    guard case .pane(let ida) = a else { return XCTFail() }
    let untouched = s.tree.leaves.first { $0.id != ida && $0.kind == .terminal }!.id
    try r.execute("pane.swap", ["idA": .int(ida), "idB": .int(untouched)], state: &s).get()
    XCTAssertNil(s.launches[ida])
    XCTAssertEqual(s.launches[untouched]?.command, "claude")
  }

  func testSwapWithUnknownPaneFails() throws {
    var (s, _) = try opened()
    XCTAssertEqual(r.execute("pane.swap", ["idA": .int(1), "idB": .int(99)], state: &s).failure?.code, .preconditionFailed)
  }

  // V16: an agent in pane 2 fans out three children next to itself; focus and the other panes stay put.
  func testFanOutNextToParentWithoutStealingFocus() throws {
    var (s, root) = try opened()
    try r.execute("pane.focus", ["id": .int(3)], state: &s).get()
    let parent = WorkbenchState.terminalKey(root, 2)
    var keys: [String] = []
    for n in 1...3 {
      guard case .text(let key) = try r.execute(
        "agent.launch", ["profile": .string("claude"), "prompt": .string("task \(n) it's"), "parent": .string(parent)],
        confirmed: true, state: &s
      ).get() else { return XCTFail() }
      keys.append(key)
    }
    XCTAssertEqual(Set(keys).count, 3)
    XCTAssertEqual(s.tree.focused, 3)
    let l = try s.delegated(keys[0])
    XCTAssertEqual(l.parent, parent); XCTAssertEqual(l.cwd, root)
    XCTAssertTrue(l.command.hasPrefix("/bin/sh -c '"))
    XCTAssertTrue(l.command.contains("claude -p"))
    // unknown parent terminal: refused before anything opens
    XCTAssertEqual(r.execute("agent.launch", ["profile": .string("claude"), "parent": .string(root + "#99")], confirmed: true, state: &s).failure?.code, .preconditionFailed)
    // status/output only for delegated agents
    XCTAssertEqual(r.execute("agent.status", ["key": .string(parent)], state: &s).failure?.code, .preconditionFailed)
  }

  // The recorded run: the generated command really records output and the exit status through `script`.
  func testDelegatedRunRecordsOutputAndExit() throws {
    var (s, root) = try opened()
    let bin = URL(fileURLWithPath: root).appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try "#!/bin/sh\necho \"did: $2\"\nexit 3\n".write(to: bin.appending(path: "claude"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "claude").path)
    guard case .text(let key) = try r.execute(
      "agent.launch", ["profile": .string("claude"), "prompt": .string("say 'hi'"), "parent": .string(WorkbenchState.terminalKey(root, 2))],
      confirmed: true, state: &s
    ).get() else { return XCTFail() }
    let l = try s.delegated(key)
    defer { for ext in ["log", "exit"] { try? FileManager.default.removeItem(at: AgentRun.directory.appending(path: "\(l.run!).\(ext)")) } }
    XCTAssertEqual(try r.execute("agent.status", ["key": .string(key)], state: &s).get(), .text("running"))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", l.command]
    p.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
    p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    XCTAssertEqual(try r.execute("agent.status", ["key": .string(key)], state: &s).get(), .text("exited 3"))
    XCTAssertEqual(try r.execute("agent.output", ["key": .string(key)], state: &s).get(), .text("did: say 'hi'"))
  }

  // `agent.list`: every agent terminal with the key agent.status/output/close take; a run's exit file decides its status.
  func testListShowsKeysAndRecordedExit() throws {
    var (s, root) = try opened()
    let parent = WorkbenchState.terminalKey(root, 2)
    guard case .pane(let plain) = try r.execute("agent.launch", ["profile": .string("codex")], confirmed: true, state: &s).get(),
      case .text(let key) = try r.execute(
        "agent.launch", ["profile": .string("claude"), "prompt": .string("x"), "parent": .string(parent)], confirmed: true, state: &s
      ).get()
    else { return XCTFail() }
    XCTAssertEqual(r.commands.first { $0.id == "agent.list" }?.aiAvailable, true)
    XCTAssertEqual(try r.preflight("agent.list", [:], s).get(), .read)
    guard case .agents(let rows) = try r.execute("agent.list", state: &s).get() else { return XCTFail() }
    XCTAssertEqual(rows.map(\.key).sorted(), [WorkbenchState.terminalKey(root, plain), key].sorted())
    let child = try XCTUnwrap(rows.first { $0.key == key })
    XCTAssertEqual(child.profile, "claude"); XCTAssertEqual(child.parent, parent); XCTAssertEqual(child.status, "running")
    XCTAssertTrue(child.delegated)
    XCTAssertEqual(rows.first { $0.key != key }?.delegated, false)
    let run = try XCTUnwrap(s.delegated(key).run)
    let exit = AgentRun.directory.appending(path: "\(run).exit")
    try FileManager.default.createDirectory(at: AgentRun.directory, withIntermediateDirectories: true)
    try "3\n".write(to: exit, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: exit) }
    guard case .agents(let after) = try r.execute("agent.list", state: &s).get() else { return XCTFail() }
    XCTAssertEqual(after.first { $0.key == key }.map { [$0.status, "\($0.exitCode ?? -1)"] }, ["exited", "3"])
  }

  // Closing your own finished child is free; a running one or someone else's needs approval.
  func testCloseRiskAndPlacement() throws {
    var (s, root) = try opened()
    let parent = WorkbenchState.terminalKey(root, 2)
    guard case .text(let key) = try r.execute(
      "agent.launch", ["profile": .string("codex"), "prompt": .string("x"), "parent": .string(parent)], confirmed: true, state: &s
    ).get() else { return XCTFail() }
    XCTAssertEqual(try r.preflight("agent.close", ["key": .string(key), "parent": .string(parent)], s).get(), .write)  // still running
    let l = try s.delegated(key)
    try FileManager.default.createDirectory(at: AgentRun.directory, withIntermediateDirectories: true)
    let exit = AgentRun.directory.appending(path: "\(l.run!).exit")
    try "0\n".write(to: exit, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: exit) }
    XCTAssertEqual(try r.preflight("agent.close", ["key": .string(key), "parent": .string(parent)], s).get(), .read)
    XCTAssertEqual(try r.preflight("agent.close", ["key": .string(key), "parent": .string(root + "#3")], s).get(), .write)
    let focused = s.tree.focused
    try r.execute("agent.close", ["key": .string(key), "parent": .string(parent)], state: &s).get()
    XCTAssertEqual(s.tree.focused, focused)
    XCTAssertNil(s.terminal(key))
  }
}

/// An agent's own hooks report working / blocked / done through `agent.report`.
final class AgentReportTests: XCTestCase {
  let r = CommandRegistry.workbench

  func testReportDrivesStatusAndFocusTurnsDoneIdle() throws {
    let (base, root) = try WorkbenchAgentLaunchTests().opened()
    var s = base
    guard case .pane(let pane) = try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get() else { return XCTFail() }
    let key = WorkbenchState.terminalKey(root, pane)
    XCTAssertEqual(r.commands.first { $0.id == "agent.report" }?.aiAvailable, true)
    // The IPC layer fills `parent` from the caller's terminal; without one there is nothing to report on.
    XCTAssertEqual(r.execute("agent.report", ["state": .string("done")], state: &s).failure?.code, .preconditionFailed)
    XCTAssertEqual(r.execute("agent.report", ["state": .string("sleeping"), "parent": .string(key)], state: &s).failure?.code, .invalidInput)
    func status() -> String? { s.agentList.first { $0.pane == pane }?.status }
    XCTAssertEqual(status(), "running")
    try r.execute("agent.report", ["state": .string("blocked"), "parent": .string(key)], state: &s).get()
    XCTAssertEqual(status(), "blocked")
    // A bell from the same turn does not override the agent's own report.
    s.notices.record(project: s.project, pane: pane, kind: .bell)
    try r.execute("agent.report", ["state": .string("done"), "parent": .string(key)], state: &s).get()
    XCTAssertEqual(status(), "done")
    try r.execute("pane.focus", ["id": .int(pane)], state: &s).get()
    XCTAssertEqual(status(), "idle")
    try r.execute("agent.report", ["state": .string("working"), "parent": .string(key)], state: &s).get()
    XCTAssertEqual(status(), "running")
    // Exit outranks any report.
    s.notices.record(project: s.project, pane: pane, kind: .exited, exitCode: 0)
    XCTAssertEqual(status(), "exited")
  }

  func testReportedSessionResumesOnlyWhereTheShellIsGone() throws {
    let (base, root) = try WorkbenchAgentLaunchTests().opened()
    var s = base
    guard case .pane(let a) = try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get(),
      case .pane(let b) = try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get()
    else { return XCTFail() }
    let id = "8f0c2c1e-aa11-4b3c-9d2e-123456789abc"
    try r.execute("agent.report", ["state": .string("done"), "session": .string(id), "parent": .string(WorkbenchState.terminalKey(root, a))], state: &s).get()
    try r.execute("agent.report", ["state": .string("done"), "session": .string(id), "parent": .string(WorkbenchState.terminalKey(root, b))], state: &s).get()
    // A hook that could not read the id sends it empty: the report still counts, the session is kept.
    try r.execute("agent.report", ["state": .string("working"), "session": .string(""), "parent": .string(WorkbenchState.terminalKey(root, b))], state: &s).get()
    XCTAssertEqual(s.launches[a]?.session, id)
    XCTAssertEqual(s.launches[a]?.command, "claude")  // never changes under a live shell
    s.resumeReportedAgents(live: { $0 == WorkbenchState.terminalKey(root, b) })
    XCTAssertEqual(s.launches[a]?.command, "claude --resume \(id)")
    XCTAssertEqual(s.launches[b]?.command, "claude")
  }

  func testCallerBecomesTheReportingTerminal() {
    let req = WorkbenchIPCRequest(command: "agent.report", input: ["state": .string("done"), "parent": .string("/x#9")], caller: "/p#2")
    XCTAssertEqual(req.callerAsParent().input["parent"], .string("/p#2"))
  }
}

final class ClairClaudeHooksTests: XCTestCase {
  func testInstallAddsOurHooksBesideTheUsersAndUninstallRemovesOnlyOurs() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = ClairClaudeEditor.settings(home: home)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8).write(to: url)
    XCTAssertFalse(ClairClaudeHooks.isInstalled(home: home))
    try ClairClaudeHooks.install(home: home)
    try ClairClaudeHooks.install(home: home)  // reinstall replaces, never duplicates
    XCTAssertTrue(ClairClaudeHooks.isInstalled(home: home))
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    var hooks = json["hooks"] as! [String: [[String: Any]]]
    XCTAssertEqual(hooks["Stop"]?.count, 2)
    XCTAssertEqual(hooks["Notification"]?.first?["matcher"] as? String, "permission_prompt|elicitation_dialog")
    XCTAssertTrue(((hooks["Stop"]?.last?["hooks"] as? [[String: Any]])?.first?["command"] as? String)?.contains("$CLAIR_TERMINAL_KEY") == true)
    try ClairClaudeHooks.uninstall(home: home)
    json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    hooks = json["hooks"] as! [String: [[String: Any]]]
    XCTAssertEqual(Array(hooks.keys), ["Stop"])
    XCTAssertEqual((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String, "say done")
    XCTAssertEqual(json["model"] as? String, "opus")
  }
}

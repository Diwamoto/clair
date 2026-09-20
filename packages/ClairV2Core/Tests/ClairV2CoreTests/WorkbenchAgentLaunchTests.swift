import XCTest

@testable import ClairV2Workspace

/// V07: agent launch profiles run as raw terminals in the Project root.
final class WorkbenchAgentLaunchTests: XCTestCase {
  let r = CommandRegistry.workbench

  func opened() throws -> (WorkbenchState, String) {
    let dir = URL.temporaryDirectory.appending(path: "clair-v07-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var s = WorkbenchState()
    try r.execute("project.open", ["path": .string(dir.path)], state: &s).get()
    return (s, dir.path)
  }

  func testLaunchNeedsConfirmationAndIsNotAIAvailable() throws {
    var (s, _) = try opened()
    XCTAssertEqual(r.commands.first { $0.id == "agent.launch" }?.aiAvailable, false)
    XCTAssertEqual(r.execute("agent.launch", ["profile": .string("claude")], state: &s).failure?.code, .confirmationRequired)
    XCTAssertTrue(s.launches.isEmpty)
    XCTAssertEqual(r.execute("agent.launch", ["profile": .string("rm")], confirmed: true, state: &s).failure?.code, .invalidInput)
  }

  func testMultipleLaunchesGetOwnPanesInProjectRootAndCloseDropsThem() throws {
    var (s, root) = try opened()
    let a = try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get()
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
    XCTAssertEqual(r.paletteItems(.commands, query: "codex", state: s).map(\.input), [["profile": .string("codex")]])
  }

  // Dragging a launched pane's header onto another pane moves the running session with it.
  func testSwapMovesLaunchToTheOtherPane() throws {
    var (s, _) = try opened()
    let a = try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get()
    guard case .pane(let ida) = a else { return XCTFail() }
    let untouched = s.tree.leaves.first { $0.id != ida }!.id
    try r.execute("pane.swap", ["idA": .int(ida), "idB": .int(untouched)], state: &s).get()
    XCTAssertNil(s.launches[ida])
    XCTAssertEqual(s.launches[untouched]?.command, "claude")
  }

  func testSwapWithUnknownPaneFails() throws {
    var (s, _) = try opened()
    XCTAssertEqual(r.execute("pane.swap", ["idA": .int(1), "idB": .int(99)], state: &s).failure?.code, .preconditionFailed)
  }
}


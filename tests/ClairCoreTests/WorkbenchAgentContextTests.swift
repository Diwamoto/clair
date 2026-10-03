import XCTest

@testable import ClairWorkspace

/// IDE context for agents: `editor.diagnostics`, `review.threads`, `review.comment`, `review.suggest`.
final class WorkbenchAgentContextTests: XCTestCase {
  let r = CommandRegistry.workbench

  /// Two open Projects with one file each; the first is active.
  func projects() throws -> (WorkbenchState, a: String, b: String) {
    var s = WorkbenchState()
    var roots: [String] = []
    for name in ["a", "b"] {
      let dir = URL.temporaryDirectory.appending(path: "clair-ctx-\(name)-\(UUID().uuidString)").resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: dir.appending(path: "src"), withIntermediateDirectories: true)
      try "one\ntwo\nthree\n".write(to: dir.appending(path: "src/main.go"), atomically: true, encoding: .utf8)
      try r.execute("project.open", ["path": .string(dir.path)], state: &s).get()
      roots.append(dir.path)
    }
    try r.execute("project.switch", ["name": .string(URL(fileURLWithPath: roots[0]).lastPathComponent)], state: &s).get()
    return (s, roots[0], roots[1])
  }

  private func gate(_ id: String, _ input: CommandInput, _ state: WorkbenchState) -> (Result<CommandResult, CommandError>, asked: Int) {
    var asked = 0
    let result = MCPGate.handle(
      WorkbenchIPCRequest(command: id, input: input, via: .mcp), registry: r, snapshot: { state },
      approve: { _, _, _ in asked += 1; return false }, run: { _, _ in .success(.ok) })
    return (result, asked)
  }

  func testCommandsAreAIAvailableAndNeedNoApproval() throws {
    let (s, a, _) = try projects()
    let risks = Dictionary(uniqueKeysWithValues: r.commands.map { ($0.id, ($0.risk, $0.aiAvailable, $0.inPalette)) })
    XCTAssertEqual(risks["editor.diagnostics"]?.0, .read)
    XCTAssertEqual(risks["review.threads"]?.0, .read)
    XCTAssertEqual(risks["review.comment"]?.0, .additive)
    XCTAssertEqual(risks["review.suggest"]?.0, .additive)
    for id in ["editor.diagnostics", "review.threads", "review.comment", "review.suggest"] {
      XCTAssertEqual(risks[id]?.1, true, id); XCTAssertEqual(risks[id]?.2, false, id)
    }
    let comment: CommandInput = ["path": .string(a + "/src/main.go"), "line": .int(2), "body": .string("nil check")]
    let g = gate("review.comment", comment, s)
    XCTAssertNotNil(try? g.0.get()); XCTAssertEqual(g.asked, 0)
    XCTAssertNotNil(try? gate("editor.diagnostics", [:], s).0.get())
    XCTAssertNotNil(try? gate("review.threads", ["path": .string("src/main.go")], s).0.get())  // relative to the active Project
  }

  func testTargetsMustBeFilesInAnOpenProject() throws {
    let (s, a, b) = try projects()
    XCTAssertEqual(try s.agentFile("src/main.go"), AgentFileTarget(root: a, path: "src/main.go"))
    XCTAssertEqual(try s.agentFile(b + "/src/main.go"), AgentFileTarget(root: b, path: "src/main.go"))
    let outside = URL.temporaryDirectory.appending(path: "clair-ctx-out-\(UUID().uuidString).txt")
    try "x".write(to: outside, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: outside) }
    for raw in [outside.path, "../\(URL(fileURLWithPath: b).lastPathComponent)/src/main.go", "src", "src/missing.go", ""] {
      var state = s
      let input: CommandInput = ["path": .string(raw), "line": .int(1), "body": .string("x")]
      XCTAssertNotNil(r.execute("review.comment", input, state: &state).failure, raw)
      XCTAssertEqual(gate("review.comment", input, s).asked, 0, raw)
    }
  }

  func testLinesBodiesAndSuggestionProject() throws {
    var (s, a, b) = try projects()
    let file = a + "/src/main.go"
    func code(_ id: String, _ input: CommandInput) -> CommandError.Code? { r.execute(id, input, state: &s).failure?.code }
    XCTAssertEqual(code("review.comment", ["path": .string(file), "line": .int(0), "body": .string("x")]), .invalidInput)
    XCTAssertEqual(code("review.comment", ["path": .string(file), "line": .int(3), "endLine": .int(2), "body": .string("x")]), .invalidInput)
    XCTAssertEqual(code("review.comment", ["path": .string(file), "line": .int(1), "body": .string("  ")]), .invalidInput)
    XCTAssertNil(code("review.comment", ["path": .string(file), "line": .int(1), "endLine": .int(3), "body": .string("x")]))
    XCTAssertNil(code("review.suggest", ["path": .string(file), "line": .int(2), "replacement": .string("")]))  // deleting lines is a proposal too
    // Suggestions bind to the active Project's buffers; another open Project is refused, not silently retargeted.
    XCTAssertEqual(
      code("review.suggest", ["path": .string(b + "/src/main.go"), "line": .int(1), "replacement": .string("x")]), .preconditionFailed)
  }

  func testReviewLaunchAllowsOnlyClairReviewCommands() {
    let plain = AgentLaunch(profile: "claude", cwd: "/x", prompt: "review")
    let review = AgentLaunch(profile: "claude", cwd: "/x", prompt: "review", review: true)
    XCTAssertFalse(plain.command.contains("allowedTools"))
    XCTAssertTrue(review.command.contains("--allowedTools"))
    XCTAssertTrue(review.command.contains("Bash(clair review.comment:*)"))
    XCTAssertFalse(review.command.contains("Bash(clair:*)"))
    // A provider without a review form runs its plain batch.
    let codex = AgentLaunch(profile: "codex", cwd: "/x", prompt: "p", review: true).command
    XCTAssertTrue(codex.contains("codex exec")); XCTAssertFalse(codex.contains("allowedTools"))
    XCTAssertTrue(AgentReviewRequest.prompt(for: .project).contains("clair review.comment"))
  }
}

import Foundation
import XCTest

@testable import ClairApp

final class AgentWorkflowTests: XCTestCase {
  func testFixedProfilesExposeStableIdentityAndLaunchDetails() {
    XCTAssertEqual(AgentLaunchProfile.all, [.claudeCode, .codex, .openCode])
    XCTAssertEqual(
      AgentLaunchProfile.all.map(\.stableID),
      ["claude-code", "codex", "opencode"]
    )
    XCTAssertEqual(
      AgentLaunchProfile.all.map(\.displayName),
      ["Claude Code", "Codex", "OpenCode"]
    )
    XCTAssertEqual(
      AgentLaunchProfile.all.map(\.executable),
      ["claude", "codex", "opencode"]
    )
    XCTAssertEqual(AgentLaunchProfile.all.map(\.arguments), [[], [], []])
    XCTAssertEqual(
      AgentLaunchProfile.claudeCode.suggestedModels.map(\.id),
      ["sonnet", "opus", "haiku"]
    )
    XCTAssertEqual(AgentLaunchProfile.codex.modelPickerCommand, "/model")
    XCTAssertEqual(AgentLaunchProfile.openCode.modelPickerCommand, "/models")
  }

  func testProfilePassesSelectedModelAsQuotedLaunchArguments() {
    let root = URL(fileURLWithPath: "/tmp/project")
    let command = AgentLaunchProfile.claudeCode.launchCommand(
      for: root,
      modelID: "custom model; $(touch injected)"
    )

    XCTAssertEqual(command.arguments, ["--model", "custom model; $(touch injected)"])
    XCTAssertEqual(
      command.shellCommand,
      "cd -- '/tmp/project' && exec 'claude' '--model' 'custom model; $(touch injected)'"
    )
  }

  func testProfileBuildsProjectRootShellCommandWithQuotedValues() {
    let root = URL(fileURLWithPath: "/tmp/Clair project/O'Reilly;$(touch injected)")
    let command = AgentLaunchProfile.codex.launchCommand(for: root)

    XCTAssertEqual(command.executable, "codex")
    XCTAssertEqual(command.arguments, [])
    XCTAssertEqual(command.cwd, root.standardizedFileURL.path)
    XCTAssertEqual(
      command.shellCommand,
      "cd -- '/tmp/Clair project/O'\\''Reilly;$(touch injected)' && exec 'codex'"
    )
    XCTAssertEqual(command.shellArguments, ["-lc", command.shellCommand])
  }

  func testShellCommandDoesNotExecuteCwdInjection() throws {
    let fixture = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentWorkflowTests-\(UUID().uuidString)", isDirectory: true)
    let injectedMarker = fixture.appendingPathComponent("injected", isDirectory: false)
    let maliciousDirectory = fixture.appendingPathComponent(
      "project; touch injected",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: fixture) }

    try FileManager.default.createDirectory(
      at: maliciousDirectory,
      withIntermediateDirectories: true
    )
    let command = AgentLaunchCommand(
      executable: "/usr/bin/true",
      cwd: maliciousDirectory
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = command.shellArguments
    process.currentDirectoryURL = fixture

    try process.run()
    process.waitUntilExit()

    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: injectedMarker.path))
  }

  func testShellCommandQuotesArgumentsIndependently() {
    let command = AgentLaunchCommand(
      executable: "/usr/bin/printf",
      arguments: ["%s", "value with spaces; $(touch injected)"],
      cwd: URL(fileURLWithPath: "/tmp/project")
    )

    XCTAssertEqual(
      command.shellCommand,
      "cd -- '/tmp/project' && exec '/usr/bin/printf' '%s' 'value with spaces; $(touch injected)'"
    )
  }

  func testAgentSessionLifecycleRoundTripsThroughCodable() throws {
    let sessionID = try XCTUnwrap(UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF"))
    let root = URL(fileURLWithPath: "/tmp/agent-project")
    var session = AgentSession(
      id: sessionID,
      profile: .claudeCode,
      modelID: "sonnet",
      projectRoot: root
    )

    XCTAssertEqual(session.id, sessionID)
    XCTAssertEqual(session.profileID, "claude-code")
    XCTAssertEqual(session.profile, .claudeCode)
    XCTAssertEqual(session.modelID, "sonnet")
    XCTAssertEqual(session.cwd, root.path)
    XCTAssertTrue(session.isActive)
    XCTAssertNil(session.exitCode)

    session.markRunning()
    XCTAssertEqual(session.lifecycle, .running)

    session.markExited(code: 17)
    XCTAssertEqual(session.lifecycle, .exited(17))
    XCTAssertFalse(session.isActive)
    XCTAssertEqual(session.exitCode, 17)

    let decoded = try JSONDecoder().decode(
      AgentSession.self,
      from: JSONEncoder().encode(session)
    )
    XCTAssertEqual(decoded, session)
  }

  func testAgentControlSnapshotSeparatesFactualAttentionFromLifecycle() {
    let projectID = UUID()
    let sessionID = UUID()
    let workflow = AgentWorkflowSession(
      agent: AgentSession(
        id: sessionID,
        profile: .codex,
        projectRoot: URL(fileURLWithPath: "/tmp/agent-project"),
        lifecycle: .running
      ),
      projectID: projectID,
      terminalTabID: "terminal:\(sessionID.uuidString)",
      startedAt: Date(timeIntervalSince1970: 1),
      finishedAt: nil
    )
    let attention = AgentActivity.officialHook(
      projectID: projectID,
      sessionID: sessionID,
      kind: .attention,
      occurredAt: Date(timeIntervalSince1970: 2),
      summary: "Needs input"
    )

    let snapshot = AgentControlSnapshot(session: workflow, lastActivity: attention)

    XCTAssertEqual(snapshot.id, sessionID)
    XCTAssertEqual(snapshot.state, .attention)
    XCTAssertEqual(snapshot.lastActivity?.kind, .attention)
    XCTAssertTrue(snapshot.capabilities.contains(.terminalInput))
    XCTAssertTrue(snapshot.capabilities.contains(.interrupt))
  }
}

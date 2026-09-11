import Foundation
import XCTest

@testable import ClairApp

final class AgentWorkflowTests: XCTestCase {
  func testProfilePassesSelectedModelAsLaunchArguments() {
    let root = URL(fileURLWithPath: "/tmp/project")
    let command = AgentLaunchProfile.claudeCode.launchCommand(
      for: root,
      modelID: "custom model; $(touch injected)"
    )

    XCTAssertEqual(command.arguments, ["--model", "custom model; $(touch injected)"])

  }

  func testShellCommandPreservesCwdAndArgumentsWithoutExecutingTheirContents() throws {
    let fixture = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentWorkflowTests-\(UUID().uuidString)", isDirectory: true)
    let directory = fixture.appendingPathComponent("O'Reilly; $(touch injected)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = fixture.appendingPathComponent("record arguments.sh")
    try Data("#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let arguments = ["space value", "O'Reilly", "; touch injected", "$(touch injected)"]
    let command = AgentLaunchCommand(executable: script.path, arguments: arguments, cwd: directory)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = command.shellArguments
    process.currentDirectoryURL = fixture
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    XCTAssertEqual(lines, [directory.resolvingSymlinksInPath().path] + arguments)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.appendingPathComponent("injected").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected").path))
  }

  func testAgentSessionLifecycleTracksRunningAndExitStatus() throws {
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

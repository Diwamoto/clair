import Foundation
import Testing
import ClairWorkspace

@Suite("Debugger commands") struct DebuggerCommandTests {
  @Test func projectBoundaryAndLaunchConfirmation() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "clair-debug-command-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "main.go")
    try "package main\nfunc main() {}\n".write(to: file, atomically: true, encoding: .utf8)
    var state = WorkbenchState()
    let commands = CommandRegistry.workbench
    _ = try commands.execute("project.open", ["path": .string(root.path)], state: &state).get()
    let launch: CommandInput = ["program": .string(file.path)]
    #expect(commands.preflight("debug.launch", launch, state) == .success(.external))
    #expect(commands.execute("debug.launch", launch, state: &state) == .failure(CommandError(.confirmationRequired, "debug.launch is 外部")))
    #expect(commands.execute("debug.launch", launch, confirmed: true, state: &state) == .success(.ok))
    guard case .failure(let stoppedError) = commands.preflight("debug.continue", [:], state) else { Issue.record("continued without a session"); return }
    #expect(stoppedError.code == .preconditionFailed)
    state.debugPhase = "stopped"
    #expect(commands.preflight("debug.continue", [:], state) == .success(.write))
    state.debugPhase = "idle"
    let outside: CommandInput = ["program": .string("/etc/hosts")]
    guard case .failure(let error) = commands.preflight("debug.launch", outside, state) else { Issue.record("outside path accepted"); return }
    #expect(error.code == .preconditionFailed)
    #expect(commands.execute("debug.breakpoint", ["path": .string(file.path), "line": .int(0)], state: &state) == .failure(CommandError(.preconditionFailed, "行は 1 以上にしてください")))
  }

  @Test func navigationCommandChangesGeneration() throws {
    var state = WorkbenchState()
    let before = state.debugNavigationGeneration
    _ = try CommandRegistry.workbench.execute("debug.open", state: &state).get()
    #expect(state.debugNavigationGeneration == before + 1)
  }
}

#if os(macOS)
  import XCTest
  @testable import ClairAppKit
  @testable import ClairWorkspace

  final class ClairCLIProcessScannerTests: XCTestCase {
    func testOnlyAgentsUnderTheOwnedShellAreDetected() {
      let processes = [
        ClairCLIProcessScanner.ProcessInfo(pid: 10, parent: 1, name: "zsh"),
        ClairCLIProcessScanner.ProcessInfo(pid: 11, parent: 10, name: "node"),
        ClairCLIProcessScanner.ProcessInfo(pid: 12, parent: 11, name: "claude"),
        ClairCLIProcessScanner.ProcessInfo(pid: 20, parent: 1, name: "zsh"),
        ClairCLIProcessScanner.ProcessInfo(pid: 21, parent: 20, name: "codex"),
        ClairCLIProcessScanner.ProcessInfo(pid: 40, parent: 1, name: "zsh"),
        ClairCLIProcessScanner.ProcessInfo(pid: 41, parent: 40, name: "2.1.280", path: "/Users/u/.local/share/claude/versions/2.1.280"),
      ]
      XCTAssertEqual(ClairCLIProcessScanner.profile(shell: 10, processes: processes), "claude")
      XCTAssertEqual(ClairCLIProcessScanner.profile(shell: 20, processes: processes), "codex")
      XCTAssertEqual(ClairCLIProcessScanner.profile(shell: 40, processes: processes), "claude")
      XCTAssertNil(ClairCLIProcessScanner.profile(shell: 30, processes: processes))
    }

    func testDetectedLaunchAppearsInAgentListWithoutReplacingMenuLaunch() {
      var state = WorkbenchState()
      state.project = "clair"
      state.launches[1] = AgentLaunch(profile: "claude", cwd: "/clair")
      state.detectedLaunches["clair"] = [1: AgentLaunch(profile: "codex", cwd: "/clair"),
                                         2: AgentLaunch(profile: "codex", cwd: "/clair")]
      XCTAssertEqual(state.agentSessions.map(\.title), ["Claude Code", "Codex"])
      XCTAssertEqual(state.runningAgents, 2)
      state.detectedLaunches = [:]
      XCTAssertEqual(state.agentSessions.map(\.title), ["Claude Code"])
    }
  }
#endif

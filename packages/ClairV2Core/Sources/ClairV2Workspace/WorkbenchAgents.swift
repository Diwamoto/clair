import Foundation

// V07: agent launch profiles. An agent is a raw terminal running the unmodified TUI in the
// Project root (ADR-0002): Clair never parses its output; the terminal surface owns the PTY,
// so a failing semantic adapter cannot affect the session. Only facts (bell, exit code shown
// by the kept-open pane) are available.
// ponytail: fixed built-in list resolved via PATH; user-defined profiles / managed worktree cwd land with V06.

public struct AgentProfile: Sendable, Equatable {
  public let id: String
  public let title: String
  /// Run by the terminal's login shell, so PATH/aliases match the user's own terminal.
  public let command: String

  public static let all = [
    AgentProfile(id: "claude", title: "Claude Code", command: "claude"),
    AgentProfile(id: "codex", title: "Codex", command: "codex"),
    AgentProfile(id: "opencode", title: "OpenCode", command: "opencode"),
  ]

  public static func named(_ id: String) -> AgentProfile? { all.first { $0.id == id } }
}

public struct AgentLaunch: Sendable, Codable, Equatable {
  public let profile: String
  public let cwd: String
  public var command: String { AgentProfile.named(profile)?.command ?? "" }
}

extension WorkbenchState {
  /// Agent terminals that have not reported an exit (V08 fact) — the reason to keep the Mac awake (V09).
  public var runningAgents: Int {
    var all = layouts.mapValues(\.launches)
    all[project] = launches
    return all.reduce(0) { n, e in
      n + e.value.keys.filter { pane in !notices.items.contains { $0.project == e.key && $0.pane == pane && $0.kind == .exited } }.count
    }
  }

  /// Idle-sleep is blocked only while agents run, and on battery only if the user opted in.
  public func preventsSleep(onACPower: Bool) -> Bool { runningAgents > 0 && (onACPower || toggles["preventSleepOnBattery"] == true) }
}

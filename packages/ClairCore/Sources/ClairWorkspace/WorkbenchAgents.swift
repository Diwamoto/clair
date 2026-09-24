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
  public init(profile: String, cwd: String) { self.profile = profile; self.cwd = cwd }
  public var command: String { AgentProfile.named(profile)?.command ?? "" }
}

/// U06: one row of the session list, derived from facts only (launch + bell/exit notices).
public struct AgentSession: Sendable, Equatable, Identifiable {
  public enum Status: Sendable, Equatable {
    case running, attention, exited(Int?)
    public var isExited: Bool { if case .exited = self { true } else { false } }
  }
  public var id: String { NotificationLog.paneKey(project, pane) }
  public let project: String
  public let pane: Int
  public let title: String
  public let cwd: String
  public let status: Status
}

extension WorkbenchState {
  /// An agent started in a Clair terminal, either through a launch profile or detected in its shell.
  public func agentLaunch(in project: String, pane: Int) -> AgentLaunch? {
    let known = project == self.project ? launches[pane] : layouts[project]?.launches[pane]
    return known ?? detectedLaunches[project]?[pane]
  }

  /// Every agent terminal across Projects; exit wins over bell, an unread bell means it wants you.
  public var agentSessions: [AgentSession] {
    var all = layouts.mapValues(\.launches)
    all[project] = launches
    for (project, detected) in detectedLaunches {
      for (pane, launch) in detected where all[project]?[pane] == nil {
        all[project, default: [:]][pane] = launch
      }
    }
    return all.sorted { $0.key < $1.key }.flatMap { p, ls in
      ls.sorted { $0.key < $1.key }.map { pane, l in
        let mine = notices.items.filter { $0.project == p && $0.pane == pane }  // newest first
        let discovered = detectedLaunches[p]?[pane] != nil && (p == project ? launches[pane] : layouts[p]?.launches[pane]) == nil
        let status: AgentSession.Status =
          (discovered ? nil : mine.first { $0.kind == .exited }.map { .exited($0.exitCode) })
            ?? (mine.contains { $0.kind == .bell && !$0.read } ? .attention : .running)
        return AgentSession(project: p, pane: pane, title: AgentProfile.named(l.profile)?.title ?? l.profile, cwd: l.cwd, status: status)
      }
    }
  }

  /// Agent terminals that have not reported an exit (V08 fact) — the reason to keep the Mac awake (V09).
  public var runningAgents: Int {
    var all = layouts.mapValues(\.launches)
    all[project] = launches
    for (project, detected) in detectedLaunches {
      for (pane, launch) in detected where all[project]?[pane] == nil {
        all[project, default: [:]][pane] = launch
      }
    }
    return all.reduce(0) { n, e in
      n + e.value.keys.filter { pane in
        let discovered = detectedLaunches[e.key]?[pane] != nil
          && (e.key == project ? launches[pane] : layouts[e.key]?.launches[pane]) == nil
        return discovered || !notices.items.contains { $0.project == e.key && $0.pane == pane && $0.kind == .exited }
      }.count
    }
  }

  /// Idle-sleep is blocked only while agents run, and on battery only if the user opted in.
  public func preventsSleep(onACPower: Bool) -> Bool { runningAgents > 0 && (onACPower || toggles["preventSleepOnBattery"] == true) }
}

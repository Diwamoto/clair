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
  /// V16: non-interactive form that takes the prompt as its last argument and exits when done.
  public let batch: String

  public static let all = [
    AgentProfile(id: "claude", title: "Claude Code", command: "claude", batch: "claude -p"),
    AgentProfile(id: "codex", title: "Codex", command: "codex", batch: "codex exec"),
    AgentProfile(id: "opencode", title: "OpenCode", command: "opencode", batch: "opencode run"),
  ]

  public static func named(_ id: String) -> AgentProfile? { all.first { $0.id == id } }
}

public struct AgentLaunch: Sendable, Codable, Equatable {
  public let profile: String
  public let cwd: String
  /// V16: a delegated task. With a prompt the agent runs in batch mode and its output/exit land in `AgentRun` files.
  public var prompt: String?
  /// V16: terminal key (`root#pane`) of the agent that launched this one.
  public var parent: String?
  public var run: String?
  public init(profile: String, cwd: String, prompt: String? = nil, parent: String? = nil) {
    self.profile = profile; self.cwd = cwd; self.prompt = prompt; self.parent = parent
    run = prompt == nil ? nil : UUID().uuidString.lowercased()
  }
  public var command: String {
    guard let p = AgentProfile.named(profile) else { return "" }
    guard let prompt, let run else { return p.command }
    // `script` keeps a TTY for the agent while recording it, and exits with the agent's status.
    // Wrapped in /bin/sh so the user's login shell (zsh, fish, …) only sees one quoted argument.
    let r = AgentRun(id: run), q = AgentRun.quote
    let inner = "mkdir -p \(q(AgentRun.directory.path)); script -q \(q(r.log.path)) \(p.batch) \(q(prompt)); echo $? > \(q(r.exit.path))"
    return "/bin/sh -c \(q(inner))"
  }
}

/// V16: the recorded output and exit status of one delegated (prompted) agent run.
public struct AgentRun: Sendable {
  public let id: String
  public static var directory: URL { ClairChannel.current.dataURL.appending(path: "agents") }
  var log: URL { Self.directory.appending(path: "\(id).log") }
  var exit: URL { Self.directory.appending(path: "\(id).exit") }

  /// nil while running.
  public var exitCode: Int? {
    (try? String(contentsOf: exit, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  /// Last `lines` lines of what the agent printed, with terminal control sequences (and `script`'s `^D` echo at EOF) removed.
  // ponytail: reads the whole log; fine for agent transcripts, seek from the end if logs reach MBs.
  public func output(lines: Int) -> String {
    let raw = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    let plain = raw.replacingOccurrences(of: #"\^D\x08\x08|\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07]*\x07|[\x00-\x08\x0B-\x1F\x7F]"#, with: "", options: .regularExpression)
    return plain.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
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
  /// The terminal's window title (what the agent says it is doing), if it set one.
  public var activity: String? = nil
}

extension WorkbenchState {
  /// Same key the GUI uses for the daemon shell behind a terminal pane (`ClairWorkbenchStore.terminalKey`).
  public static func terminalKey(_ root: String, _ pane: Int) -> String { "\(root)#\(pane)" }

  /// V16: the open Project and terminal pane behind `root#pane`, in any Project (not just the shown one).
  func terminal(_ key: String) -> (project: String, pane: Int)? {
    guard let i = key.lastIndex(of: "#"), let pane = Int(key[key.index(after: i)...]),
      let p = projects.first(where: { $0.path == String(key[..<i]) })
    else { return nil }
    let tree = p.name == project ? tree : layouts[p.name]?.tree
    return tree?.leaves.contains { $0.id == pane && $0.kind == .terminal } == true ? (p.name, pane) : nil
  }

  mutating func withLayout<R>(_ name: String, _ body: (inout ProjectLayout) -> R) -> R {
    if name == project { return body(&layout) }
    var l = layouts[name] ?? ProjectLayout()
    defer { layouts[name] = l }
    return body(&l)
  }

  /// Where agent.launch opens: next to the calling terminal, else the focused pane of the shown Project.
  func launchHome(_ parent: String?) throws(CommandError) -> (project: WorkbenchProject, pane: Int?) {
    if let parent {
      guard let t = terminal(parent), let p = projects.first(where: { $0.name == t.project }) else {
        throw CommandError(.preconditionFailed, "calling terminal \(parent) is not open in Clair")
      }
      return (p, t.pane)
    }
    guard let p = projects.first(where: { $0.name == project }) else { throw CommandError(.preconditionFailed, "no active project") }
    return (p, nil)
  }

  /// A prompted agent launched by agent.launch, still open.
  func delegated(_ key: String) throws(CommandError) -> AgentLaunch {
    guard let t = terminal(key), let l = withLayoutCopy(t.project).launches[t.pane], l.run != nil else {
      throw CommandError(.preconditionFailed, "\(key) is not a delegated agent")
    }
    return l
  }

  private func withLayoutCopy(_ name: String) -> ProjectLayout { name == project ? layout : layouts[name] ?? ProjectLayout() }

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
        return AgentSession(project: p, pane: pane, title: AgentProfile.named(l.profile)?.title ?? l.profile, cwd: l.cwd, status: status,
          activity: paneTitles[NotificationLog.paneKey(p, pane)].flatMap { $0.isEmpty ? nil : $0 })
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

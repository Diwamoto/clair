import Foundation

/// `agent.history` (#69): one agent pane's run, kept after the pane closes so a day's work can be read back.
public struct AgentPaneRecord: Sendable, Codable, Equatable {
  public let key: String
  public let project: String
  public let cwd: String
  public let profile: String
  /// The terminal title the agent last set.
  public var activity: String?
  /// The Clair-managed worktree branch the pane started in.
  public let branch: String?
  /// UTC ISO 8601 (`2026-11-05T09:00:00Z`), so the JSON reads as-is and strings sort as times.
  public let start: String
  /// When the agent exited or the pane closed; nil while it runs.
  public var end: String?
  public var exitCode: Int?
  public let parent: String?
  /// Provider session id, when the agent reported one (resume with `agent.launch resume=`).
  public var sessionID: String?
}

public enum AgentPaneLog {
  public static let retention: TimeInterval = 90 * 86400

  public static var defaultURL: URL { ClairChannel.current.dataURL.appending(path: "agent-history.json") }

  /// Folds the live panes into `records`: a new key (or a key whose last run ended) starts a record, a live
  /// one refreshes it, an open record whose pane is gone ends now. Records older than `retention` drop.
  public static func merge(_ records: [AgentPaneRecord], live: [AgentPaneRecord], now date: Date = .now) -> [AgentPaneRecord] {
    let now = stamp(date), cutoff = stamp(date.addingTimeInterval(-retention))
    var out = records.filter { ($0.end ?? now) > cutoff }
    let liveKeys = Set(live.map(\.key))
    for i in out.indices where out[i].end == nil && !liveKeys.contains(out[i].key) { out[i].end = now }
    for l in live {
      if let i = out.lastIndex(where: { $0.key == l.key && $0.end == nil }) {
        out[i].activity = l.activity ?? out[i].activity
        out[i].sessionID = l.sessionID ?? out[i].sessionID
        if l.end != nil { out[i].end = now; out[i].exitCode = l.exitCode }
      } else if l.end == nil || !out.contains(where: { $0.key == l.key }) {
        // An exited pane still on screen is recorded once (a reused key that exits within one tick is missed).
        out.append(l)
      }
    }
    return out
  }

  public static func load(_ url: URL = defaultURL) -> [AgentPaneRecord] {
    (try? Data(contentsOf: url)).flatMap { try? decoder.decode([AgentPaneRecord].self, from: $0) } ?? []
  }

  public static func save(_ records: [AgentPaneRecord], to url: URL = defaultURL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? encoder.encode(records).write(to: url, options: .atomic)
  }

  /// Runs that overlap [since, until) and, with `project`, belong to that Project name.
  public static func filter(_ records: [AgentPaneRecord], since: Date, until: Date, project: String?) -> [AgentPaneRecord] {
    let since = stamp(since), until = stamp(until)
    return records.filter { r in r.start < until && (r.end ?? "~") >= since && project.map { r.project == $0 } ?? true }
      .sorted { $0.start < $1.start }
  }

  public static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

  static let encoder = JSONEncoder()
  static let decoder = JSONDecoder()
}

extension WorkbenchState {
  /// Every agent pane as a record (start = `now`, used only when it is new), without the file reads `agentList` does.
  public func liveAgentRecords(now date: Date = .now) -> [AgentPaneRecord] {
    let now = AgentPaneLog.stamp(date)
    return agentSessions.compactMap { s in
      guard let root = projects.first(where: { $0.name == s.project })?.path, let l = agentLaunch(in: s.project, pane: s.pane) else { return nil }
      var exit: Int?? = l.run.flatMap { AgentRun(id: $0).exitCode }.map { .some($0) }
      if exit == nil, case .exited(let code) = s.status { exit = .some(code) }
      return AgentPaneRecord(
        key: Self.terminalKey(root, s.pane), project: s.project, cwd: l.cwd, profile: l.profile, activity: s.activity,
        branch: projects.first { $0.path == l.cwd }?.branch, start: now, end: exit == nil ? nil : now, exitCode: exit ?? nil,
        parent: l.parent, sessionID: l.session ?? l.concierge ?? l.resume)
    }
  }
}

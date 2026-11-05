import Foundation

/// `agent.history` (#69): one agent pane's run, kept after the pane closes so a day's work can be read back.
public struct AgentPaneRecord: Sendable, Codable, Equatable {
  public let key: String
  public let project: String
  public let cwd: String
  public let profile: String
  /// The last meaningful terminal title the agent set, without its leading state mark; a bare tool name
  /// ("✳ Claude Code") does not replace it.
  public var activity: String?
  /// The leading state mark of the latest title (`◐`, `✳` …).
  public var activityState: String?
  /// The Clair-managed worktree branch the pane started in.
  public let branch: String?
  /// UTC ISO 8601 (`2026-11-05T09:00:00Z`), so the JSON reads as-is and strings sort as times.
  public let start: String
  /// When the agent exited or the pane closed; nil while it runs.
  public var end: String?
  public var exitCode: Int?
  /// How the run ended: `exited` (the agent's process), `closed` (the pane closed while it ran), `quit` (Clair quit).
  public var endReason: String?
  public let parent: String?
  /// Provider session id, when the agent reported one (resume with `agent.launch resume=`).
  public var sessionID: String?

  enum CodingKeys: String, CodingKey {
    case key, project, cwd, profile, activity, activityState, branch, start, end, exitCode, endReason, parent, sessionID
  }
  /// Writes unknown values as `null` rather than dropping the key (agent.history contract).
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(key, forKey: .key); try c.encode(project, forKey: .project); try c.encode(cwd, forKey: .cwd)
    try c.encode(profile, forKey: .profile); try c.encode(activity, forKey: .activity)
    try c.encode(activityState, forKey: .activityState); try c.encode(branch, forKey: .branch)
    try c.encode(start, forKey: .start); try c.encode(end, forKey: .end); try c.encode(exitCode, forKey: .exitCode)
    try c.encode(endReason, forKey: .endReason); try c.encode(parent, forKey: .parent); try c.encode(sessionID, forKey: .sessionID)
  }
}

public enum AgentPaneLog {
  public static let retention: TimeInterval = 90 * 86400

  /// Overridable for tests.
  nonisolated(unsafe) public static var defaultURL: URL = ClairChannel.current.dataURL.appending(path: "agent-history.json")
  /// Open records started before this process belong to an earlier run that did not end them (a crash).
  static let processStart = stamp(.now)

  /// Folds the live panes into `records`: a new key (or a key whose last run ended) starts a record, a live
  /// one refreshes it. An open record whose pane is gone ends now when it is in `owned` (nil: any), so one
  /// window does not end another window's panes. Records older than `retention` drop.
  public static func merge(
    _ records: [AgentPaneRecord], live: [AgentPaneRecord], owned: Set<String>? = nil, now date: Date = .now
  ) -> [AgentPaneRecord] {
    let now = stamp(date), cutoff = stamp(date.addingTimeInterval(-retention))
    var out = records.filter { ($0.end ?? now) > cutoff }
    let liveKeys = Set(live.map(\.key))
    for i in out.indices where out[i].end == nil && !liveKeys.contains(out[i].key)
      && (owned?.contains(out[i].key) ?? true || out[i].start < processStart) {
      out[i].end = now; out[i].endReason = "closed"
    }
    for l in live {
      if let i = out.lastIndex(where: { $0.key == l.key && $0.end == nil }) {
        out[i].activity = l.activity ?? out[i].activity
        out[i].activityState = l.activityState ?? out[i].activityState
        out[i].sessionID = l.sessionID ?? out[i].sessionID
        if l.end != nil { out[i].end = now; out[i].exitCode = l.exitCode; out[i].endReason = "exited" }
      } else if l.end == nil || !out.contains(where: { $0.key == l.key }) {
        // An exited pane still on screen is recorded once (a reused key that exits within one tick is missed).
        var l = l
        if l.end != nil { l.endReason = "exited" }
        out.append(l)
      }
    }
    return out
  }

  /// One window's detection tick: re-read the file (other windows write it too), fold this window's panes in,
  /// and remember them as `owned` for the next tick.
  public static func record(live: [AgentPaneRecord], owned: inout Set<String>, url: URL = defaultURL, now: Date = .now) {
    let old = load(url)
    let merged = merge(old, live: live, owned: owned, now: now)
    owned = Set(live.map(\.key))
    if merged != old { save(merged, to: url) }
  }

  /// Clair quits: every open run ends now.
  public static func endOpen(url: URL = defaultURL, now: Date = .now) {
    var records = load(url)
    guard records.contains(where: { $0.end == nil }) else { return }
    for i in records.indices where records[i].end == nil { records[i].end = stamp(now); records[i].endReason = "quit" }
    save(records, to: url)
  }

  /// A terminal title split into its leading state mark and its text; the text is nil when it only names the tool.
  static func activity(_ title: String?) -> (state: String?, text: String?) {
    guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return (nil, nil) }
    let mark = title.prefix { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
    let text = title.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
    let generic = text.isEmpty || AgentProfile.all.contains { $0.title == text || $0.id == text.lowercased() }
    return (mark.isEmpty ? nil : String(mark), generic ? nil : text)
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
      let activity = AgentPaneLog.activity(s.activity)
      return AgentPaneRecord(
        key: Self.terminalKey(root, s.pane), project: s.project, cwd: l.cwd, profile: l.profile, activity: activity.text,
        activityState: activity.state, branch: projects.first { $0.path == l.cwd }?.branch, start: now,
        end: exit == nil ? nil : now, exitCode: exit ?? nil, parent: l.parent, sessionID: l.session ?? l.concierge ?? l.resume)
    }
  }
}

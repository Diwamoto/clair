import Foundation

// V07: agent launch profiles. An agent is a raw terminal running the unmodified TUI in the
// Project root (ADR-0002): Clair never parses its output; the terminal surface owns the PTY,
// so a failing semantic adapter cannot affect the session. Only facts (bell, exit code shown
// by the kept-open pane) are available.
// agent registry: this list is the single registry of launchable agents — the palette, the
// settings "既定のAgent" picker, the AI review provider menu, and process detection all read
// `all` instead of naming profiles themselves. Add an agent here and it appears everywhere.
// ponytail: fixed built-in list resolved via PATH; user-defined profiles / managed worktree cwd land with V06.

public struct AgentProfile: Sendable, Equatable {
  public let id: String
  public let title: String
  /// Run by the terminal's login shell, so PATH/aliases match the user's own terminal.
  public let command: String
  /// V16: non-interactive form that takes the prompt as its last argument and exits when done.
  public let batch: String
  /// Command prefix that takes a provider session id as its last argument and reopens that chat.
  public var resume: String? = nil
  /// `batch` for a read-only review that may post its findings back to Clair (`clair review.*`, spec §6).
  /// nil: the plain `batch`, whose agent reports in the terminal only.
  public var reviewBatch: String? = nil
  /// Interactive form that takes a first message as its last argument, submits it and stays open.
  /// nil: the CLI has none, so it cannot be opened with a message.
  public var open: String? = nil

  public static let all = [
    AgentProfile(
      id: "claude", title: "Claude Code", command: "claude", batch: "claude -p", resume: "claude --resume",
      // `-p` denies tools that would ask; allow exactly the Clair review commands (and only those).
      reviewBatch: "claude --allowedTools 'Bash(clair review comment:*)' 'Bash(clair review suggest:*)' 'Bash(clair review threads:*)' -p",
      open: "claude"),
    AgentProfile(id: "codex", title: "Codex", command: "codex", batch: "codex exec", resume: "codex resume", open: "codex"),
    AgentProfile(id: "opencode", title: "OpenCode", command: "opencode", batch: "opencode run", resume: "opencode --session", open: "opencode --prompt"),
    // agent registry: added alongside the original three so users can switch to them; behaviour
    // of claude/codex/opencode above is unchanged.
    AgentProfile(id: "gemini", title: "Gemini CLI", command: "gemini", batch: "gemini -p", open: "gemini -i"),
    AgentProfile(id: "cursor-agent", title: "Cursor CLI", command: "cursor-agent", batch: "cursor-agent -p", open: "cursor-agent"),
    AgentProfile(id: "copilot", title: "GitHub Copilot CLI", command: "copilot", batch: "copilot -p", open: "copilot -i"),
    AgentProfile(id: "aider", title: "Aider", command: "aider", batch: "aider --yes --message"),
  ]

  /// Provider session ids are UUIDs or `ses_…`; anything else never reaches a shell.
  public static func isSessionID(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && s.utf8.count <= 100 }

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
  /// Provider session id to reopen instead of starting a fresh chat.
  public var resume: String?
  /// ADR-0020: the fixed Claude Code session id of Clair's concierge.
  public var concierge: String?
  /// #76: `settings.concierge` prompt at launch. Fixed, like `folders`: a changed command replaces the live shell.
  public var conciergePrompt: String?
  /// First message of an interactive agent (the profile's `open` form); for a concierge, the request typed
  /// before it was running. Unlike `prompt`, the agent stays open in its terminal afterwards.
  public var opening: String?
  /// A read-only review run: uses the profile's `reviewBatch` so it can post findings with `clair review.*`.
  public var review: Bool?
  /// The provider session the agent last reported (`agent.report session=`). Not part of `command`: changing
  /// the command would make the daemon replace a live shell. `resumeReportedAgents` turns it into `resume`
  /// only when the shell is gone.
  public var session: String?
  /// The Project's added folders when this agent started (ADR-0017). Fixed at launch: deriving them live
  /// would change `command` when a folder is added, and a changed command replaces the running shell.
  public var folders: [String]?
  /// #75: sbx sandbox this batch run executes in (`clair-<run>`), removed by agent.close.
  public var sandbox: String?
  public init(
    profile: String, cwd: String, prompt: String? = nil, parent: String? = nil, resume: String? = nil, concierge: String? = nil,
    opening: String? = nil, review: Bool = false, folders: [String]? = nil
  ) {
    self.profile = profile; self.cwd = cwd; self.prompt = prompt; self.parent = parent; self.resume = resume; self.concierge = concierge
    self.opening = opening
    self.review = review ? true : nil
    self.folders = folders?.isEmpty == true ? nil : folders
    run = prompt == nil ? nil : UUID().uuidString.lowercased()
  }
  public var command: String {
    guard let p = AgentProfile.named(profile) else { return "" }
    // Last on the line: `--add-dir` is variadic and would swallow a prompt after it.
    // ponytail: Claude Code only; other CLIs still see just the cwd until their flags are verified.
    let dirs = profile == "claude" ? (folders ?? []).map { " --add-dir \(AgentRun.quote($0))" }.joined() : ""
    if let concierge, AgentProfile.isSessionID(concierge) { return Concierge.command(session: concierge, extra: conciergePrompt ?? "", opening: opening) + dirs }
    if let resume, let prefix = p.resume, AgentProfile.isSessionID(resume) { return "\(prefix) \(resume)\(dirs)" }
    if prompt == nil, let opening, let open = p.open { return "\(open) \(AgentRun.quote(opening))\(dirs)" }
    guard let prompt, let run else { return p.command + dirs }
    // `script` keeps a TTY for the agent while recording it, and exits with the agent's status.
    // Wrapped in /bin/sh so the user's login shell (zsh, fish, …) only sees one quoted argument.
    let r = AgentRun(id: run), q = AgentRun.quote
    let batch = review == true ? p.reviewBatch ?? p.batch : p.batch
    let agent: String
    if let sandbox {
      // #75: the child sees only cwd (bind mount); its claude login is sbx's global secret, never on the host side.
      // ponytail: Claude Code only and no --add-dir folders; mount folders as extra workspaces when needed.
      let steps = """
        command -v sbx >/dev/null || { echo 'sbx is not installed'; exit 127; }; \
        d=$(sbx diagnose 2>&1) || { echo "$d"; exit 1; }; \
        sbx create -q --name \(sandbox) claude \(q(cwd)) >/dev/null && \
        sbx exec -it -w \(q(cwd)) \(sandbox) claude -p --permission-mode acceptEdits \(q(prompt))
        """
      agent = "/bin/sh -c \(q(steps))"
    } else {
      agent = "\(batch) \(q(prompt))\(dirs)"
    }
    let inner = "mkdir -p \(q(AgentRun.directory.path)); script -q \(q(r.log.path)) \(agent); echo $? > \(q(r.exit.path))"
    return "/bin/sh -c \(q(inner))"
  }
}

/// V16: the recorded output and exit status of one delegated (prompted) agent run.
public struct AgentRun: Sendable {
  public let id: String
  public static var directory: URL { ClairChannel.current.dataURL.appending(path: "agents") }
  var log: URL { Self.directory.appending(path: "\(id).log") }
  var exit: URL { Self.directory.appending(path: "\(id).exit") }

  /// #75: `clair-*` names in `listed` (`sbx ls -q`) that no open pane runs in.
  static func staleSandboxes(_ listed: String, keep: Set<String>) -> [String] {
    listed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("clair-") && !keep.contains($0) }
  }

  static func pruneSandboxes(keep: Set<String>) {
    #if os(macOS)
    DispatchQueue.global(qos: .utility).async {
      let p = Process(), out = Pipe()
      p.executableURL = URL(fileURLWithPath: "/bin/zsh")
      // ponytail: skips when sbx is missing instead of starting its daemon just to find nothing.
      p.arguments = ["-lc", "command -v sbx >/dev/null && sbx ls -q 2>/dev/null"]
      p.standardOutput = out; p.standardError = FileHandle.nullDevice
      guard (try? p.run()) != nil else { return }
      let listed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      p.waitUntilExit()
      staleSandboxes(listed, keep: keep).forEach(removeSandbox)
    }
    #endif
  }

  /// #75: `sbx rm` stops the child and deletes its VM; the Clair worktree it worked in stays (worktree.remove).
  /// Login shell so sbx resolves on the user's PATH. Fire and forget: a leftover shows in `sbx ls`.
  static func removeSandbox(_ name: String) {
    #if os(macOS)
    guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "sbx rm --force \(name)"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run()
    #endif
  }

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
/// What the agent itself reported through its official hooks (`agent.report`, `ClairClaudeHooks`).
public struct AgentReport: Sendable, Codable, Equatable {
  public enum State: String, Sendable, Codable, CaseIterable { case working, blocked, done }
  public var state: State
  /// A `done` turns `idle` once the user focuses the pane.
  public var seen = false
}

public struct AgentSession: Sendable, Equatable, Identifiable {
  /// `running`: working, or nothing reported. `attention`: an unread bell from an agent without hooks.
  /// `blocked` / `done` / `idle` come only from the agent's own report.
  public enum Status: Sendable, Equatable {
    case running, attention, blocked, done, idle, exited(Int?)
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

/// One row of `agent.list`. `key` (`root#pane`) is what agent.status / output / wait / close take for a delegated run.
public struct WorkbenchAgent: Sendable, Codable, Equatable {
  public let key: String
  public let project: String
  public let pane: Int
  public let profile: String
  public let cwd: String
  /// `running` / `attention` (rang the bell, unread) / `blocked` (waits on a permission or question) /
  /// `done` (finished a turn, not yet looked at) / `idle` (done and looked at) / `exited`
  public let status: String
  public let exitCode: Int?
  /// The terminal's window title, if the agent set one.
  public let activity: String?
  /// Started with a prompt through agent.launch (its output and exit are recorded).
  public let delegated: Bool
  /// Terminal key of the agent that launched this one.
  public let parent: String?
  public let concierge: Bool
  /// Tokens in the agent's context as of its latest reply, and the window they fill. nil when unknown
  /// (no reported session, or a provider whose usage Clair does not read).
  public var contextTokens: Int? = nil
  public var contextLimit: Int? = nil

  enum CodingKeys: String, CodingKey {
    case key, project, pane, profile, cwd, status, exitCode, activity, delegated, parent, concierge, contextTokens, contextLimit
  }
  /// Writes unknown context as `null` rather than dropping the key (agent.list contract).
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(key, forKey: .key); try c.encode(project, forKey: .project); try c.encode(pane, forKey: .pane)
    try c.encode(profile, forKey: .profile); try c.encode(cwd, forKey: .cwd); try c.encode(status, forKey: .status)
    try c.encodeIfPresent(exitCode, forKey: .exitCode); try c.encodeIfPresent(activity, forKey: .activity)
    try c.encode(delegated, forKey: .delegated); try c.encodeIfPresent(parent, forKey: .parent)
    try c.encode(concierge, forKey: .concierge)
    try c.encode(contextTokens, forKey: .contextTokens); try c.encode(contextLimit, forKey: .contextLimit)
  }
}

public enum AgentContext {
  /// Context size and window of a Claude Code session: the latest main-chain, non-synthetic assistant usage in
  /// its JSONL (input + cache read + cache write) and `limit(...)`. Reads only the file's tail.
  public static func claude(session: String, cwd: String, home: URL = .homeDirectory,
    env: [String: String] = ProcessInfo.processInfo.environment) -> (tokens: Int?, limit: Int?) {
    guard AgentProfile.isSessionID(session) else { return (nil, nil) }
    let root = home.appending(path: ".claude/projects")
    guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
      let file = dirs.lazy.map({ $0.appending(path: "\(session).jsonl") }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
      let handle = try? FileHandle(forReadingFrom: file)
    else { return (nil, nil) }
    defer { try? handle.close() }
    // ponytail: last 1 MiB only; a single reply bigger than that, or a `/model` before it, reads as unknown.
    let end = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: end > 1 << 20 ? end - (1 << 20) : 0)
    let tail = scan((try? handle.readToEnd()) ?? Data())
    guard let tokens = tail.tokens else { return (nil, nil) }
    return (tokens, limit(tokens, switched: tail.model, cwd: cwd, home: home, env: env))
  }

  /// The latest usage, and the latest in-session `/model` switch (its `<local-command-stdout>`).
  static func scan(_ data: Data) -> (tokens: Int?, model: String?) {
    var tokens: Int?, model: String?
    for line in data.split(separator: 10).reversed() where tokens == nil || model == nil {
      guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], o["isSidechain"] as? Bool != true else { continue }
      let message = o["message"] as? [String: Any]
      if model == nil, let text = (o["content"] ?? message?["content"]) as? String,
        text.hasPrefix("<local-command-stdout>Set model to") { model = text }
      if tokens == nil, o["type"] as? String == "assistant", message?["model"] as? String != "<synthetic>",
        let usage = message?["usage"] as? [String: Any] {
        tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
          .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
      }
    }
    return (tokens, model)
  }

  /// The JSONL names the model but not its window, so the window follows the model the session was asked for,
  /// in Claude Code's precedence: in-session `/model` > `ANTHROPIC_MODEL` > `<cwd>/.claude/settings.local.json` >
  /// `<cwd>/.claude/settings.json` > `~/.claude/settings.json`. The first one found decides: `[1m]` / `1M` → 1M,
  /// else nil — an alias (`opus`) or a `/model` display name (`Opus 5.5`) can be 1M by plan default, so 200k is
  /// never assumed (#73: a 160k `opus` pane did not hit a 60% autocompact). Usage over 200k is 1M whatever they say.
  /// ponytail: a `--model` argument, or `ANTHROPIC_MODEL` exported only in the pane's shell, is not visible to
  /// Clair — such a 1M session under 200k reads as nil. Read the claude process's argv/env if that matters.
  static func limit(_ tokens: Int, switched: String?, cwd: String, home: URL, env: [String: String]) -> Int? {
    if tokens > 200_000 { return 1_000_000 }
    func setting(_ url: URL) -> String? {
      (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["model"] as? String
    }
    let dir = URL(filePath: cwd).appending(path: ".claude")
    let asked = switched ?? env["ANTHROPIC_MODEL"] ?? setting(dir.appending(path: "settings.local.json"))
      ?? setting(dir.appending(path: "settings.json")) ?? setting(home.appending(path: ".claude/settings.json"))
    guard let asked else { return nil }
    return asked.lowercased().contains("[1m]") || asked.contains("1M") ? 1_000_000 : nil
  }
}

extension WorkbenchState {
  /// The scrollback+screen text of a terminal pane in the active Project, installed by the GUI
  /// (the PTY bytes live in the daemon; Ghostty holds the rendered text). nil when not mounted.
  nonisolated(unsafe) public static var screenText: (_ pane: Int) -> String? = { _ in nil }
  /// Types `text` into a terminal pane of the active Project and presses Return, installed by the GUI.
  nonisolated(unsafe) public static var screenInput: (_ pane: Int, _ text: String) -> Bool = { _, _ in false }

  /// The active-Project terminal behind `key` that `agent.send` may type into.
  func inputPane(_ key: String) throws(CommandError) -> Int {
    guard let t = terminal(key), t.project == project else {
      throw CommandError(.preconditionFailed, "\(key) is not a terminal in the active Project")
    }
    return t.pane
  }

  /// What `agent.output` reads: a delegated run's log, else any terminal pane's rendered screen.
  func paneOutput(_ key: String, lines: Int) throws(CommandError) -> String {
    if let l = try? delegated(key) { return AgentRun(id: l.run!).output(lines: lines) }
    guard let t = terminal(key) else { throw CommandError(.preconditionFailed, "\(key) is not a terminal") }
    // ponytail: only the active Project's panes are mounted in Ghostty; read the daemon journal for the rest if needed.
    guard t.project == project, let text = Self.screenText(t.pane) else {
      throw CommandError(.preconditionFailed, "\(key) is not in the active Project")
    }
    // Trim first: the blank rows under the cursor would otherwise use up `lines`.
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
  }

  /// Same key the GUI uses for the daemon shell behind a terminal pane (`ClairWorkbenchStore.terminalKey`).
  public static func terminalKey(_ root: String, _ pane: Int) -> String { "\(root)#\(pane)" }

  /// V16: the open Project and terminal pane behind `root#pane`, in any Project (not just the shown one).
  public func terminal(_ key: String) -> (project: String, pane: Int)? {
    guard let i = key.lastIndex(of: "#"), let pane = Int(key[key.index(after: i)...]),
      let p = projects.first(where: { $0.path == String(key[..<i]) })
    else { return nil }
    let tree = p.name == project ? tree : layouts[p.name]?.tree
    return tree?.leaves.contains { $0.id == pane && $0.kind == .terminal } == true ? (p.name, pane) : nil
  }

  /// Removes the terminal pane behind `root#pane`, in any Project, with its launch.
  public mutating func closeTerminal(_ key: String) {
    guard let t = terminal(key) else { return }
    withLayout(t.project) { l in
      if let name = l.launches[t.pane]?.sandbox { AgentRun.removeSandbox(name) }
      l.tree.close(t.pane); l.launches[t.pane] = nil
    }
  }

  /// #75: sandboxes of every open pane, in every Project.
  var openSandboxes: Set<String> {
    Set((Array(launches.values) + layouts.filter { $0.key != project }.values.flatMap(\.launches.values)).compactMap(\.sandbox))
  }

  /// Drops the launches of closed panes; a closed sandboxed child takes its sandbox with it (#75).
  mutating func pruneLaunches() {
    for (id, l) in launches where !tree.leaves.contains(where: { $0.id == id }) {
      if let name = l.sandbox { AgentRun.removeSandbox(name) }
      launches[id] = nil
    }
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

  func withLayoutCopy(_ name: String) -> ProjectLayout { name == project ? layout : layouts[name] ?? ProjectLayout() }

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
        let reported: AgentSession.Status? = agentReports[NotificationLog.paneKey(p, pane)].map {
          switch $0.state {
          case .working: .running
          case .blocked: .blocked
          case .done: $0.seen ? .idle : .done
          }
        }
        let status: AgentSession.Status =
          (discovered ? nil : mine.first { $0.kind == .exited }.map { .exited($0.exitCode) })
            ?? reported
            ?? (mine.contains { $0.kind == .bell && !$0.read } ? .attention : .running)
        return AgentSession(project: p, pane: pane, title: AgentProfile.named(l.profile)?.title ?? l.profile, cwd: l.cwd, status: status,
          activity: paneTitles[NotificationLog.paneKey(p, pane)].flatMap { $0.isEmpty ? nil : $0 })
      }
    }
  }

  /// `agent.list`: the session list (every Project) with what a caller needs to act on each row.
  /// A delegated run's own exit file outranks the notice log, as in `agent.status`.
  public var agentList: [WorkbenchAgent] {
    agentSessions.compactMap { s in
      guard let root = projects.first(where: { $0.name == s.project })?.path, let l = agentLaunch(in: s.project, pane: s.pane) else { return nil }
      var status = "running", exitCode: Int? = nil
      let recorded = l.run.flatMap { AgentRun(id: $0).exitCode }.map { AgentSession.Status.exited($0) }
      switch recorded ?? s.status {
      case .running: break
      case .attention: status = "attention"
      case .blocked: status = "blocked"
      case .done: status = "done"
      case .idle: status = "idle"
      case .exited(let code): status = "exited"; exitCode = code
      }
      let session = l.session ?? l.concierge ?? l.resume
      let context = l.profile == "claude" ? session.map { AgentContext.claude(session: $0, cwd: s.cwd) } : nil
      return WorkbenchAgent(
        key: Self.terminalKey(root, s.pane), project: s.project, pane: s.pane, profile: l.profile, cwd: s.cwd,
        status: status, exitCode: exitCode, activity: s.activity, delegated: l.run != nil, parent: l.parent,
        concierge: l.concierge != nil,
        contextTokens: context?.tokens, contextLimit: context?.limit)
    }
  }

  /// After the daemon lost its shells (Mac restart, Clair quit), an agent pane reopens the conversation its
  /// agent last reported instead of a fresh one. `live(key)` says a shell still runs for `root#pane`: those
  /// keep their command, since a changed command replaces the live shell. Delegated runs and the concierge
  /// keep their own commands.
  public mutating func resumeReportedAgents(live: (String) -> Bool) {
    for p in projects {
      withLayout(p.name) { layout in
        for (pane, l) in layout.launches {
          guard let session = l.session, l.resume != session, l.run == nil, l.concierge == nil,
            AgentProfile.named(l.profile)?.resume != nil, !live(Self.terminalKey(p.path, pane))
          else { continue }
          layout.launches[pane]?.resume = session
        }
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

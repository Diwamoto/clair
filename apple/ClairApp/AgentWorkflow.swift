import Foundation

enum AgentLaunchProfile: String, CaseIterable, Codable, Identifiable, Sendable {
  case claudeCode = "claude-code"
  case codex = "codex"
  case openCode = "opencode"

  static let all = allCases

  var id: String {
    rawValue
  }

  var stableID: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .claudeCode:
      "Claude Code"
    case .codex:
      "Codex"
    case .openCode:
      "OpenCode"
    }
  }

  var executable: String {
    switch self {
    case .claudeCode:
      "claude"
    case .codex:
      "codex"
    case .openCode:
      "opencode"
    }
  }

  var arguments: [String] {
    []
  }

  func launchCommand(for projectRoot: URL) -> AgentLaunchCommand {
    AgentLaunchCommand(profile: self, projectRoot: projectRoot)
  }

  func launchCommand(projectRoot: URL) -> AgentLaunchCommand {
    launchCommand(for: projectRoot)
  }

  func shellCommand(for projectRoot: URL) -> String {
    launchCommand(for: projectRoot).shellCommand
  }

  func shellCommand(cwd: URL) -> String {
    shellCommand(for: cwd)
  }
}

typealias AgentProfile = AgentLaunchProfile

struct AgentLaunchCommand: Codable, Equatable, Sendable {
  let executable: String
  let arguments: [String]
  let cwd: String

  init(profile: AgentLaunchProfile, projectRoot: URL) {
    self.init(
      executable: profile.executable,
      arguments: profile.arguments,
      cwd: projectRoot
    )
  }

  init(executable: String, arguments: [String] = [], cwd: URL) {
    self.executable = executable
    self.arguments = arguments
    self.cwd = cwd.standardizedFileURL.path
  }

  var workingDirectoryURL: URL {
    URL(fileURLWithPath: cwd, isDirectory: true)
  }

  var shellArguments: [String] {
    ["-lc", shellCommand]
  }

  var commandLine: String {
    shellCommand
  }

  /// Returns a zsh command whose dynamic values are independently quoted.
  var shellCommand: String {
    let quotedCommand = ([executable] + arguments)
      .map(Self.shellQuote)
      .joined(separator: " ")
    return [
      "cd",
      "--",
      Self.shellQuote(cwd),
      "&&",
      "exec",
      quotedCommand,
    ].joined(separator: " ")
  }

  /// POSIX single-quote escaping. A quoted value cannot expand shell syntax.
  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

enum AgentSessionLifecycle: Codable, Equatable, Sendable {
  case starting
  case running
  case exited(Int32)

  private enum CodingKeys: String, CodingKey {
    case state
    case exitCode
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state = try container.decode(String.self, forKey: .state)
    switch state {
    case "starting":
      self = .starting
    case "running":
      self = .running
    case "exited":
      self = .exited(try container.decode(Int32.self, forKey: .exitCode))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .state,
        in: container,
        debugDescription: "Unknown agent session lifecycle: \(state)"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .starting:
      try container.encode("starting", forKey: .state)
    case .running:
      try container.encode("running", forKey: .state)
    case .exited(let code):
      try container.encode("exited", forKey: .state)
      try container.encode(code, forKey: .exitCode)
    }
  }

  var isActive: Bool {
    switch self {
    case .starting, .running:
      true
    case .exited:
      false
    }
  }

  var exitCode: Int32? {
    if case .exited(let code) = self {
      return code
    }
    return nil
  }
}

typealias AgentLifecycle = AgentSessionLifecycle

struct AgentSession: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let profileID: String
  let projectRoot: URL
  let worktreeID: WorktreeID?
  var lifecycle: AgentSessionLifecycle

  init(
    id: UUID = UUID(),
    profile: AgentLaunchProfile,
    projectRoot: URL,
    worktreeID: WorktreeID? = nil,
    lifecycle: AgentSessionLifecycle = .starting
  ) {
    self.init(
      id: id,
      profileID: profile.stableID,
      projectRoot: projectRoot,
      worktreeID: worktreeID,
      lifecycle: lifecycle
    )
  }

  init(
    id: UUID = UUID(),
    profileID: String,
    projectRoot: URL,
    worktreeID: WorktreeID? = nil,
    lifecycle: AgentSessionLifecycle = .starting
  ) {
    self.id = id
    self.profileID = profileID
    self.projectRoot = projectRoot.standardizedFileURL
    self.worktreeID = worktreeID
    self.lifecycle = lifecycle
  }

  var profile: AgentLaunchProfile? {
    AgentLaunchProfile(rawValue: profileID)
  }

  var cwd: String {
    projectRoot.path
  }

  var isActive: Bool {
    lifecycle.isActive
  }

  var exitCode: Int32? {
    lifecycle.exitCode
  }

  mutating func markRunning() {
    lifecycle = .running
  }

  mutating func markExited(code: Int32) {
    lifecycle = .exited(code)
  }
}

enum AgentControlState: String, Codable, CaseIterable, Sendable {
  case starting
  case running
  case attention
  case exited
}

enum AgentControlCapability: String, Codable, CaseIterable, Hashable, Sendable {
  case observe
  case terminalInput = "terminal_input"
  case interrupt
  case terminate
}

struct AgentControlSnapshot: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let projectID: UUID
  let profileID: String
  let title: String
  let projectRoot: URL
  let worktreeID: WorktreeID?
  let terminalTabID: String
  let lifecycle: AgentSessionLifecycle
  let state: AgentControlState
  let startedAt: Date
  let finishedAt: Date?
  let lastActivity: AgentActivity?
  let capabilities: Set<AgentControlCapability>

  init(session: AgentWorkflowSession, lastActivity: AgentActivity?) {
    id = session.id
    projectID = session.projectID
    profileID = session.agent.profileID
    title = session.profile?.displayName ?? session.agent.profileID
    projectRoot = session.agent.projectRoot
    worktreeID = session.worktreeID
    terminalTabID = session.terminalTabID
    lifecycle = session.lifecycle
    state = Self.state(for: session.lifecycle, lastActivity: lastActivity)
    startedAt = session.startedAt
    finishedAt = session.finishedAt
    self.lastActivity = lastActivity
    switch session.lifecycle {
    case .starting:
      capabilities = [.observe, .terminate]
    case .running:
      capabilities = [.observe, .terminalInput, .interrupt, .terminate]
    case .exited:
      capabilities = [.observe]
    }
  }

  private static func state(
    for lifecycle: AgentSessionLifecycle,
    lastActivity: AgentActivity?
  ) -> AgentControlState {
    switch lifecycle {
    case .starting:
      .starting
    case .exited:
      .exited
    case .running:
      switch lastActivity?.kind {
      case .attention, .notification, .failed:
        .attention
      case .none, .started, .completed, .unknown:
        .running
      }
    }
  }
}

enum AgentControlOperation: String, Codable, Sendable {
  case input
  case interrupt
  case stop
}

struct AgentControlReceipt: Codable, Equatable, Sendable {
  let operation: AgentControlOperation
  let sessionID: UUID
  let accepted: Bool
}

enum AgentControlError: Error, Equatable, LocalizedError, Sendable {
  case sessionNotFound(UUID)
  case terminalUnavailable(UUID)
  case sessionNotRunning(UUID)
  case emptyInput

  var errorDescription: String? {
    switch self {
    case .sessionNotFound(let sessionID):
      "Agent session \(sessionID.uuidString) was not found."
    case .terminalUnavailable(let sessionID):
      "The terminal for agent session \(sessionID.uuidString) is unavailable."
    case .sessionNotRunning(let sessionID):
      "Agent session \(sessionID.uuidString) is not running."
    case .emptyInput:
      "Agent input must not be empty."
    }
  }
}

import Combine
import Foundation
@preconcurrency import UserNotifications

struct AgentWorkflowSession: Equatable, Identifiable, Sendable {
  var agent: AgentSession
  let projectID: UUID
  let terminalTabID: String
  let startedAt: Date
  var finishedAt: Date?

  var id: UUID {
    agent.id
  }

  var profile: AgentLaunchProfile? {
    agent.profile
  }

  var lifecycle: AgentSessionLifecycle {
    agent.lifecycle
  }

  var isActive: Bool {
    agent.isActive
  }

  var exitCode: Int32? {
    agent.exitCode
  }

  var worktreeID: WorktreeID? {
    agent.worktreeID
  }
}

final class MacOSAgentActivityNotifier: AgentActivityNotifier, @unchecked Sendable {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  func notify(activity: AgentActivity) {
    let content = UNMutableNotificationContent()
    content.title = Self.title(for: activity)
    content.body = activity.summary ?? Self.body(for: activity)
    content.sound = .default
    content.threadIdentifier = activity.sessionID?.uuidString ?? activity.projectID.uuidString

    let request = UNNotificationRequest(
      identifier: activity.id.uuidString,
      content: content,
      trigger: nil
    )
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in
    }
    center.add(request)
  }

  private static func title(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "Agent needs attention"
    case .exit:
      activity.exitStatus == 0 ? "Agent completed" : "Agent exited with an error"
    case .officialHook:
      switch activity.kind {
      case .attention, .notification:
        "Agent notification"
      case .completed:
        "Agent completed"
      case .failed:
        "Agent reported an error"
      case .started, .unknown:
        "Agent activity"
      }
    }
  }

  private static func body(for activity: AgentActivity) -> String {
    switch activity.source {
    case .bell:
      "The agent terminal emitted an attention bell."
    case .exit:
      activity.exitStatus == 0
        ? "The agent terminal exited normally."
        : "The agent terminal exited before completing normally."
    case .officialHook:
      "The agent reported an activity event."
    }
  }
}

@MainActor
final class AgentWorkflowCoordinator: ObservableObject {
  static let activityFileName = "agent-activity-v1.json"
  static let hookDirectoryName = "agent-hooks-v1"
  static let maximumHookFileBytes = 512 * 1024

  @Published private(set) var sessions: [AgentWorkflowSession] = []
  @Published private(set) var activities: [AgentActivity] = []
  @Published private(set) var lastErrorMessage: String?

  let activityStore: AgentActivityStore
  let hookReceiverURL: URL?

  private let fileManager: FileManager
  private let decoder = OfficialHookDecoder()
  private let notificationDispatcher: AgentActivityNotificationDispatcher
  private let hookDirectory: URL?
  private var ledger = AgentActivityLedger()
  private var terminalEventObservers: [UUID: (session: TerminalSession, observerID: UUID)] = [:]
  private var terminalTabOwners: [UUID: ProjectSurfaceModel] = [:]
  private var hookOffsets: [String: Int] = [:]
  private var hookPollingTask: Task<Void, Never>?

  init(
    profile: ClairRuntimeProfile = .current,
    activityStore: AgentActivityStore? = nil,
    notifier: any AgentActivityNotifier = MacOSAgentActivityNotifier(),
    hookReceiverURL: URL? = nil,
    fileManager: FileManager = .default,
    startHookMonitoring: Bool = true
  ) {
    self.fileManager = fileManager
    let resolvedStore =
      activityStore
      ?? Self.makeDefaultActivityStore(profile: profile, fileManager: fileManager)
    self.activityStore = resolvedStore
    self.notificationDispatcher = AgentActivityNotificationDispatcher(notifier: notifier)
    self.hookDirectory = resolvedStore.fileURL?.deletingLastPathComponent()
      .appendingPathComponent(Self.hookDirectoryName, isDirectory: true)
    self.hookReceiverURL = hookReceiverURL ?? Self.defaultHookReceiverURL(fileManager: fileManager)

    if let hookDirectory = self.hookDirectory {
      try? fileManager.createDirectory(
        at: hookDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }

    do {
      ledger = AgentActivityLedger(snapshot: try resolvedStore.load())
    } catch {
      ledger = AgentActivityLedger()
      lastErrorMessage = "Agent activity history could not be loaded: \(error.localizedDescription)"
    }
    activities = ledger.history.activities

    if startHookMonitoring {
      self.startHookMonitoring()
    }
  }

  deinit {
    hookPollingTask?.cancel()
  }

  static func makeDefaultActivityStore(
    profile: ClairRuntimeProfile,
    fileManager: FileManager = .default
  ) -> AgentActivityStore {
    let baseDirectory = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    let directory = baseDirectory?.appendingPathComponent(
      profile.applicationSupportDirectoryName,
      isDirectory: true
    )
    let fileURL = directory?.appendingPathComponent(activityFileName, isDirectory: false)
    return AgentActivityStore(fileURL: fileURL, fileManager: fileManager)
  }

  static func defaultHookReceiverURL(
    filePath: String = #filePath,
    fileManager: FileManager = .default
  ) -> URL? {
    var candidates: [URL] = []
    if let resourceURL = Bundle.main.resourceURL {
      candidates.append(resourceURL.appendingPathComponent("agent-hook.sh"))
    }

    var sourceDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    for _ in 0..<4 {
      candidates.append(
        sourceDirectory.appendingPathComponent("scripts/agent-hook.sh", isDirectory: false)
      )
      sourceDirectory.deleteLastPathComponent()
    }

    var currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    for _ in 0..<4 {
      candidates.append(
        currentDirectory.appendingPathComponent("scripts/agent-hook.sh", isDirectory: false)
      )
      currentDirectory.deleteLastPathComponent()
    }

    var seen = Set<String>()
    for candidate in candidates {
      let standardized = candidate.standardizedFileURL
      guard seen.insert(standardized.path).inserted else {
        continue
      }
      if fileManager.isReadableFile(atPath: standardized.path) {
        return standardized
      }
    }
    return nil
  }

  @discardableResult
  func launch(
    profile: AgentLaunchProfile,
    modelID: String? = nil,
    projectID: UUID,
    projectRoot: URL,
    surface: ProjectSurfaceModel,
    worktree: ManagedWorktree? = nil
  ) -> AgentWorkflowSession? {
    let executionRoot: URL
    let worktreeID: WorktreeID?
    if let worktree {
      guard
        worktree.projectID == projectID,
        worktree.state == .available,
        Self.canonicalURL(for: projectRoot).path == Self.canonicalURL(for: worktree.rootURL).path
      else {
        lastErrorMessage = "The selected managed worktree is no longer available."
        return nil
      }
      executionRoot = worktree.rootURL
      worktreeID = worktree.id
    } else {
      executionRoot = projectRoot
      worktreeID = nil
    }

    guard
      let terminalTabID = surface.openNewTerminal(
        title: profile.displayName,
        agentProfileID: profile.stableID,
        executionRootURL: worktree == nil ? nil : executionRoot,
        worktreeID: worktreeID
      ),
      let terminal = surface.terminalSession(tabID: terminalTabID)
    else {
      lastErrorMessage = "Could not create a terminal for \(profile.displayName)."
      return nil
    }

    let agent = AgentSession(
      id: terminal.sessionID,
      profile: profile,
      modelID: modelID,
      projectRoot: executionRoot,
      worktreeID: worktreeID,
      lifecycle: .starting
    )
    let workflowSession = AgentWorkflowSession(
      agent: agent,
      projectID: projectID,
      terminalTabID: terminalTabID,
      startedAt: Date(),
      finishedAt: nil
    )
    sessions.append(workflowSession)
    terminalTabOwners[workflowSession.id] = surface
    observe(terminal, for: workflowSession.id)
    synchronizeInitialState(of: terminal, for: workflowSession.id)
    terminal.sendCommandWhenReady(
      launchCommand(
        profile: profile,
        modelID: modelID,
        projectRoot: executionRoot,
        projectID: projectID,
        sessionID: workflowSession.id,
        worktreeID: worktreeID
      )
    )
    return workflowSession
  }

  func launchCommand(
    profile: AgentLaunchProfile,
    modelID: String? = nil,
    projectRoot: URL,
    projectID: UUID,
    sessionID: UUID,
    worktreeID: WorktreeID? = nil
  ) -> String {
    var exports = [
      ("CLAIR_AGENT_SESSION_ID", sessionID.uuidString),
      ("CLAIR_AGENT_PROFILE", profile.stableID),
      ("CLAIR_PROJECT_ID", projectID.uuidString),
    ]
    if let worktreeID {
      exports.append(("CLAIR_WORKTREE_ID", worktreeID.uuidString))
    }
    if let hookReceiverURL, let hookFileURL = hookFileURL(for: sessionID) {
      exports.append(("CLAIR_AGENT_HOOK_RECEIVER", hookReceiverURL.path))
      exports.append(("CLAIR_AGENT_HOOK_FILE", hookFileURL.path))
    }

    let exportCommand = exports.map { name, value in
      "export \(name)=\(AgentLaunchCommand.shellQuote(value))"
    }.joined(separator: "; ")
    let agentCommand = profile.shellCommand(for: projectRoot, modelID: modelID)
    return exportCommand.isEmpty ? agentCommand : "\(exportCommand); \(agentCommand)"
  }

  private static func canonicalURL(for url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
  }

  func hookFileURL(for sessionID: UUID) -> URL? {
    hookDirectory?.appendingPathComponent("\(sessionID.uuidString).jsonl", isDirectory: false)
  }

  func activities(for projectID: UUID) -> [AgentActivity] {
    activities.filter { $0.projectID == projectID }
  }

  /// Registers agent tabs restored from the workspace snapshot before the UI
  /// reattaches their PTYs. The control plane must know about these sessions
  /// even when they were created in an earlier Clair process.
  func registerExistingSessions(in workspace: ProjectWorkspaceModel) {
    for project in workspace.projects {
      guard let surface = workspace.materializeSurface(for: project.id) else {
        continue
      }
      for workspaceTab in surface.workspaceTabs {
        let tab = workspaceTab.tab
        guard
          tab.kind == .terminal,
          let sessionID = tab.sessionID,
          let profileID = tab.agentProfileID,
          !sessions.contains(where: { $0.id == sessionID }),
          let terminal = surface.terminalSession(tabID: tab.id)
        else {
          continue
        }

        let workflowSession = AgentWorkflowSession(
          agent: AgentSession(
            id: sessionID,
            profileID: profileID,
            projectRoot: tab.executionRootURL ?? project.rootURL,
            worktreeID: tab.worktreeID,
            lifecycle: .starting
          ),
          projectID: project.id,
          terminalTabID: tab.id,
          startedAt: Date(),
          finishedAt: nil
        )
        sessions.append(workflowSession)
        terminalTabOwners[workflowSession.id] = surface
        observe(terminal, for: sessionID)
        synchronizeInitialState(of: terminal, for: sessionID)
      }
    }
  }

  func controlSnapshots(for projectID: UUID? = nil) -> [AgentControlSnapshot] {
    sessions
      .filter { projectID == nil || $0.projectID == projectID }
      .map { session in
        AgentControlSnapshot(
          session: session,
          lastActivity: activities.last(where: { $0.sessionID == session.id })
        )
      }
  }

  func controlSnapshot(sessionID: UUID) -> AgentControlSnapshot? {
    controlSnapshots().first(where: { $0.id == sessionID })
  }

  @discardableResult
  func sendInput(sessionID: UUID, data: Data) throws -> AgentControlReceipt {
    try sendInput(
      sessionID: sessionID,
      data: data,
      operation: .input
    )
  }

  @discardableResult
  func interrupt(sessionID: UUID) throws -> AgentControlReceipt {
    try sendInput(
      sessionID: sessionID,
      data: Data([0x03]),
      operation: .interrupt
    )
  }

  @discardableResult
  func stop(sessionID: UUID) throws -> AgentControlReceipt {
    guard let session = sessions.first(where: { $0.id == sessionID }) else {
      throw AgentControlError.sessionNotFound(sessionID)
    }
    guard session.isActive else {
      throw AgentControlError.sessionNotRunning(sessionID)
    }
    guard let terminal = terminal(for: sessionID) else {
      throw AgentControlError.terminalUnavailable(sessionID)
    }
    terminal.stop()
    return AgentControlReceipt(operation: .stop, sessionID: sessionID, accepted: true)
  }

  func activeSessionIDs(for worktreeID: WorktreeID) -> Set<UUID> {
    Set(
      sessions
        .filter { $0.worktreeID == worktreeID && $0.isActive }
        .map(\.id)
    )
  }

  func isMuted(projectID: UUID, sessionID: UUID? = nil) -> Bool {
    ledger.isMuted(projectID: projectID, sessionID: sessionID)
  }

  func setMuted(_ muted: Bool, projectID: UUID, sessionID: UUID? = nil) {
    do {
      let snapshot = try activityStore.setMuted(
        muted,
        projectID: projectID,
        sessionID: sessionID
      )
      ledger = AgentActivityLedger(snapshot: snapshot)
      activities = ledger.history.activities
      lastErrorMessage = nil
    } catch {
      var fallback = ledger
      fallback.setMuted(muted, projectID: projectID, sessionID: sessionID)
      ledger = fallback
      activities = ledger.history.activities
      lastErrorMessage =
        "Agent notification mute state could not be saved: \(error.localizedDescription)"
    }
  }

  @discardableResult
  func ingestHook(
    _ data: Data,
    projectID: UUID,
    sessionID: UUID,
    receivedAt: Date = Date()
  ) -> AgentActivity? {
    do {
      guard
        let activity = try decoder.decode(
          data,
          projectID: projectID,
          sessionID: sessionID,
          receivedAt: receivedAt
        )
      else {
        return nil
      }
      record(activity)
      return activity
    } catch {
      lastErrorMessage = "Agent hook event was ignored: \(error.localizedDescription)"
      return nil
    }
  }

  func clearError() {
    lastErrorMessage = nil
  }

  private func sendInput(
    sessionID: UUID,
    data: Data,
    operation: AgentControlOperation
  ) throws -> AgentControlReceipt {
    guard !data.isEmpty else {
      throw AgentControlError.emptyInput
    }
    guard let session = sessions.first(where: { $0.id == sessionID }) else {
      throw AgentControlError.sessionNotFound(sessionID)
    }
    guard session.isActive else {
      throw AgentControlError.sessionNotRunning(sessionID)
    }
    guard let terminal = terminal(for: sessionID) else {
      throw AgentControlError.terminalUnavailable(sessionID)
    }
    guard case .running = terminal.state else {
      throw AgentControlError.sessionNotRunning(sessionID)
    }
    terminal.sendInput(data)
    return AgentControlReceipt(operation: operation, sessionID: sessionID, accepted: true)
  }

  private func terminal(for sessionID: UUID) -> TerminalSession? {
    terminalEventObservers[sessionID]?.session
  }

  private func observe(_ terminal: TerminalSession, for sessionID: UUID) {
    let observerID = terminal.addEventObserver { [weak self] event in
      self?.receive(event, for: sessionID)
    }
    terminalEventObservers[sessionID] = (terminal, observerID)
  }

  private func synchronizeInitialState(of terminal: TerminalSession, for sessionID: UUID) {
    switch terminal.state {
    case .running:
      receive(.attached, for: sessionID)
    case .exited(let status):
      receive(.exited(status), for: sessionID)
    case .failed(let message):
      receive(.failed(message), for: sessionID)
    case .idle, .starting, .stopping, .missing:
      break
    }
  }

  private func receive(_ event: TerminalSession.Event, for sessionID: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
      return
    }
    let current = sessions[index]
    switch event {
    case .attached:
      sessions[index].agent.markRunning()
    case .output:
      break
    case .screenReset:
      break
    case .bell(let count):
      guard count > 0 else {
        return
      }
      record(
        .bell(
          projectID: current.projectID,
          sessionID: sessionID
        )
      )
    case .exited(let status):
      finishSession(at: index, status: Int32(status))
    case .failed:
      finishSession(at: index, status: -1)
    }
  }

  private func finishSession(at index: Int, status: Int32) {
    guard sessions[index].isActive else {
      return
    }
    sessions[index].agent.markExited(code: status)
    sessions[index].finishedAt = Date()
    let session = sessions[index]
    record(
      .exit(
        projectID: session.projectID,
        sessionID: session.id,
        status: Int(status)
      )
    )
    if let observation = terminalEventObservers.removeValue(forKey: session.id) {
      observation.session.removeEventObserver(observation.observerID)
    }
    let surface = terminalTabOwners.removeValue(forKey: session.id)
    surface?.closeTab(id: session.terminalTabID)
  }

  private func record(_ activity: AgentActivity) {
    let muted: Bool
    do {
      let snapshot = try activityStore.append(activity)
      ledger = AgentActivityLedger(snapshot: snapshot)
      muted = ledger.isMuted(for: activity)
      lastErrorMessage = nil
    } catch {
      var fallback = ledger
      fallback.append(activity)
      ledger = fallback
      muted = ledger.isMuted(for: activity)
      lastErrorMessage = "Agent activity history could not be saved: \(error.localizedDescription)"
    }
    activities = ledger.history.activities
    _ = notificationDispatcher.notifyIfNeeded(activity, isMuted: muted)
  }

  private func startHookMonitoring() {
    guard hookDirectory != nil else {
      return
    }
    hookPollingTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else {
          return
        }
        self?.drainHookInbox()
      }
    }
  }

  private func drainHookInbox() {
    guard let hookDirectory,
      let files = try? fileManager.contentsOfDirectory(
        at: hookDirectory,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    for fileURL in files where fileURL.pathExtension == "jsonl" {
      drainHookFile(fileURL)
    }
  }

  private func drainHookFile(_ fileURL: URL) {
    guard
      let sessionID = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent),
      let session = sessions.first(where: { $0.id == sessionID }),
      let data = try? Data(contentsOf: fileURL)
    else {
      return
    }

    if data.count > Self.maximumHookFileBytes {
      try? Data().write(to: fileURL, options: [.atomic])
      hookOffsets[fileURL.path] = 0
      return
    }

    var offset = hookOffsets[fileURL.path] ?? 0
    if offset > data.count {
      offset = 0
    }
    let unread = Data(data.dropFirst(offset))
    guard let lastNewline = unread.lastIndex(of: 0x0a) else {
      return
    }
    let complete = unread.prefix(through: lastNewline)
    for line in complete.split(separator: 0x0a, omittingEmptySubsequences: true) {
      _ = ingestHook(
        Data(line),
        projectID: session.projectID,
        sessionID: sessionID
      )
    }
    offset += complete.count

    if offset >= data.count {
      try? Data().write(to: fileURL, options: [.atomic])
      hookOffsets[fileURL.path] = 0
    } else {
      hookOffsets[fileURL.path] = offset
    }
  }
}

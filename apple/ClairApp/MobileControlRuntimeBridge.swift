import Combine
import Foundation
import ClairMobileKit

/// Connects the native workspace's existing terminal and agent lifecycle to
/// the transport-neutral mobile host. The bridge is deliberately thin: the
/// shared package owns pairing, authorization, replay, and framing while this
/// type only projects local sessions and forwards accepted operations back to
/// the owning MainActor objects.
@MainActor
final class MobileControlRuntimeBridge: ObservableObject {
  static let defaultPort: UInt16 = 47_831
  static let storeFileName = "mobile-host-v1.json"

  @Published private(set) var isEnabled = false
  @Published private(set) var listenerPort: UInt16?
  @Published private(set) var pairingLink: MobilePairingLink?
  @Published private(set) var devices: [MobileDeviceSummary] = []
  @Published private(set) var lastErrorMessage: String?

  let host: MobileControlHost?

  private let listener: MobileControlListener?
  private let workspace: ProjectWorkspaceModel
  private let agentWorkflow: AgentWorkflowCoordinator
  private let worktreeCoordinator: ProjectWorktreeCoordinator
  private var sessionObservers: [UUID: (session: TerminalSession, observerID: UUID)] = [:]
  private var sessionEpochs: [UUID: UInt64] = [:]
  private var sessionOffsets: [UUID: UInt64] = [:]
  private var knownSessionIDs: Set<UUID> = []
  private var workspaceCancellable: AnyCancellable?
  private var agentCancellable: AnyCancellable?

  init(
    profile: ClairRuntimeProfile,
    workspace: ProjectWorkspaceModel,
    agentWorkflow: AgentWorkflowCoordinator,
    worktreeCoordinator: ProjectWorktreeCoordinator,
    fileManager: FileManager = .default
  ) {
    self.workspace = workspace
    self.agentWorkflow = agentWorkflow
    self.worktreeCoordinator = worktreeCoordinator

    let baseDirectory = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let storeURL = profile.applicationSupportURL(baseDirectory: baseDirectory)
      .appendingPathComponent(Self.storeFileName, isDirectory: false)

    let resolvedHost: MobileControlHost?
    let resolvedListener: MobileControlListener?
    do {
      let createdHost = try MobileControlHost(
        store: MobileHostStore(fileURL: storeURL)
      )
      resolvedHost = createdHost
      resolvedListener = MobileControlListener(host: createdHost)
    } catch {
      resolvedHost = nil
      resolvedListener = nil
      lastErrorMessage = "モバイル接続の状態を読み込めませんでした: \(error.localizedDescription)"
    }
    host = resolvedHost
    listener = resolvedListener
    isEnabled = resolvedHost?.isEnabled ?? false

    resolvedListener?.onReady = { [weak self] port in
      Task { @MainActor [weak self] in
        self?.listenerPort = port
        self?.lastErrorMessage = nil
      }
    }
    resolvedListener?.onError = { [weak self] error in
      Task { @MainActor [weak self] in
        self?.lastErrorMessage = "モバイル接続を開始できませんでした: \(error.localizedDescription)"
        self?.listenerPort = nil
      }
    }

    if let resolvedHost {
      for profile in AgentLaunchProfile.all {
        try? resolvedHost.registerAgentProfile(
          profile.stableID,
          title: profile.displayName,
          models: profile.suggestedModels.map {
            MobileAgentModelDescriptor(id: $0.id, title: $0.title)
          },
          capabilities: [.agentLaunch]
        )
      }
      resolvedHost.setOperationHandlers(
        MobileControlHostHandlers(
          terminalInput: { [weak self] accepted in
            Task { @MainActor [weak self] in
              self?.applyTerminalInput(accepted)
            }
          },
          agentInput: { [weak self] accepted in
            Task { @MainActor [weak self] in
              self?.applyAgentInput(accepted)
            }
          },
          agentControl: { [weak self] accepted in
            Task { @MainActor [weak self] in
              self?.applyAgentControl(accepted)
            }
          },
          agentLaunch: { [weak self] accepted in
            Task { @MainActor [weak self] in
              self?.applyAgentLaunch(accepted)
            }
          }
        )
      )
    }

    workspaceCancellable = workspace.objectWillChange.sink { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refreshCatalog()
      }
    }
    agentCancellable = agentWorkflow.objectWillChange.sink { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refreshCatalog()
      }
    }

    refreshCatalog()
    refreshDevices()
    if isEnabled {
      startListener()
    }
  }

  deinit {
    for observation in sessionObservers.values {
      let session = observation.session
      let observerID = observation.observerID
      Task { @MainActor in
        session.removeEventObserver(observerID)
      }
    }
    listener?.stop()
  }

  var hostIdentity: MobileHostIdentity? {
    host?.identity
  }

  var endpointDescription: String {
    "127.0.0.1:\(listenerPort ?? Self.defaultPort)"
  }

  var pairingURLString: String? {
    pairingLink?.deepLinkURL?.absoluteString
  }

  func setEnabled(_ enabled: Bool) {
    guard let host else {
      lastErrorMessage = "モバイル接続のホストが利用できません。"
      return
    }
    do {
      try host.setEnabled(enabled)
      isEnabled = enabled
      if enabled {
        startListener()
      } else {
        listener?.stop()
        listenerPort = nil
        pairingLink = nil
      }
      refreshDevices()
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = "モバイル接続の設定を変更できませんでした: \(error.localizedDescription)"
    }
  }

  func createPairingLink() {
    guard isEnabled else {
      setEnabled(true)
      guard isEnabled else { return }
      createPairingLink()
      return
    }
    guard let host else { return }
    do {
      pairingLink = try host.createPairingLink(
        endpoint: "http://\(endpointDescription)"
      )
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = "ペアリングQRを生成できませんでした: \(error.localizedDescription)"
    }
  }

  func clearPairingLink() {
    pairingLink = nil
  }

  func revoke(_ device: MobileDeviceSummary) {
    guard let host else { return }
    do {
      _ = try host.revokeDevice(device.id)
      refreshDevices()
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = "端末を解除できませんでした: \(error.localizedDescription)"
    }
  }

  func refreshDevices() {
    devices = host?.devices() ?? []
  }

  private func startListener() {
    guard isEnabled, let listener else { return }
    do {
      try listener.start()
    } catch {
      lastErrorMessage = "モバイル接続を開始できませんでした: \(error.localizedDescription)"
    }
  }

  private func refreshCatalog() {
    guard let host else { return }
    var visibleSessionIDs = Set<UUID>()

    for project in workspace.projects {
      guard let surface = workspace.materializeSurface(for: project.id) else {
        continue
      }
      for workspaceTab in surface.workspaceTabs {
        let tab = workspaceTab.tab
        guard
          tab.kind == .terminal,
          let sessionID = tab.sessionID,
          let terminal = surface.terminalSession(tabID: tab.id)
        else {
          continue
        }

        visibleSessionIDs.insert(sessionID)
        if sessionEpochs[sessionID] == nil {
          sessionEpochs[sessionID] = 1
          sessionOffsets[sessionID] = 0
        }
        let descriptor = makeSessionDescriptor(
          project: project,
          tab: tab,
          terminal: terminal
        )

        do {
          if knownSessionIDs.contains(sessionID) {
            try host.updateSession(
              descriptor,
              isExited: !terminal.isRunning
            )
          } else {
            try host.registerSession(
              descriptor,
              epoch: sessionEpochs[sessionID] ?? 1,
              currentOffset: sessionOffsets[sessionID] ?? 0,
              isExited: !terminal.isRunning
            )
            knownSessionIDs.insert(sessionID)
          }
          if sessionObservers[sessionID] == nil {
            installObserver(for: terminal, sessionID: sessionID)
          }
        } catch {
          lastErrorMessage = "モバイルへセッションを公開できませんでした: \(error.localizedDescription)"
        }
      }
    }

    for sessionID in knownSessionIDs.subtracting(visibleSessionIDs) {
      host.removeSession(sessionID)
      if let observation = sessionObservers.removeValue(forKey: sessionID) {
        observation.session.removeEventObserver(observation.observerID)
      }
      sessionEpochs[sessionID] = nil
      sessionOffsets[sessionID] = nil
    }
    knownSessionIDs = visibleSessionIDs
    refreshAgentCatalog()
  }

  private func refreshAgentCatalog() {
    guard let host else { return }
    for snapshot in agentWorkflow.controlSnapshots() {
      host.registerAgent(makeAgentDescriptor(snapshot))
    }
  }

  private func makeSessionDescriptor(
    project: Project,
    tab: ProjectPaneTab,
    terminal: TerminalSession
  ) -> MobileSessionDescriptor {
    var capabilities: Set<MobileCapability> = [.rawTerminal]
    if terminal.isRunning {
      capabilities.formUnion([.terminalInput, .terminalInterrupt])
    }
    if tab.agentProfileID != nil {
      capabilities.formUnion([.agentCatalog, .agentStatus, .agentControl, .attentionNotifications])
    }
    return MobileSessionDescriptor(
      id: terminal.sessionID,
      projectID: project.id,
      worktreeID: tab.worktreeID,
      title: tab.title,
      cwd: terminal.projectRootURL.path,
      agentProfileID: tab.agentProfileID,
      lifecycle: makeSessionLifecycle(terminal.state),
      capabilities: capabilities
    )
  }

  private func makeAgentDescriptor(
    _ snapshot: AgentControlSnapshot
  ) -> MobileAgentDescriptor {
    var capabilities: Set<MobileCapability> = [.agentCatalog, .agentStatus]
    if snapshot.capabilities.contains(.terminalInput) {
      capabilities.insert(.terminalInput)
    }
    if snapshot.capabilities.contains(.interrupt) {
      capabilities.insert(.terminalInterrupt)
    }
    if snapshot.capabilities.contains(.terminate) {
      capabilities.insert(.agentControl)
    }
    return MobileAgentDescriptor(
      id: snapshot.id,
      projectID: snapshot.projectID,
      worktreeID: snapshot.worktreeID,
      profileID: snapshot.profileID,
      modelID: snapshot.modelID,
      title: snapshot.title,
      cwd: snapshot.projectRoot.path,
      lifecycle: makeSessionLifecycle(snapshot.lifecycle),
      state: MobileAgentState(rawValue: snapshot.state.rawValue) ?? .unavailable,
      attention: snapshot.state == .attention,
      lastActivityAt: snapshot.lastActivity?.occurredAt,
      capabilities: capabilities
    )
  }

  private func makeSessionLifecycle(
    _ state: TerminalSession.State
  ) -> MobileSessionLifecycle {
    switch state {
    case .idle, .starting, .stopping:
      .starting
    case .running:
      .running
    case .exited:
      .exited
    case .missing, .failed:
      .unavailable
    }
  }

  private func makeSessionLifecycle(
    _ lifecycle: AgentSessionLifecycle
  ) -> MobileSessionLifecycle {
    switch lifecycle {
    case .starting:
      .starting
    case .running:
      .running
    case .exited:
      .exited
    }
  }

  private func installObserver(for terminal: TerminalSession, sessionID: UUID) {
    let observerID = terminal.addEventObserver { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handle(event, sessionID: sessionID)
      }
    }
    sessionObservers[sessionID] = (terminal, observerID)
  }

  private func handle(_ event: TerminalSession.Event, sessionID: UUID) {
    guard let host, knownSessionIDs.contains(sessionID) else { return }
    switch event {
    case .attached:
      refreshCatalog()
    case .output(let data):
      guard !data.isEmpty, let epoch = sessionEpochs[sessionID] else { return }
      let offset = sessionOffsets[sessionID] ?? 0
      do {
        try host.publishOutput(
          sessionID: sessionID,
          epoch: epoch,
          data: data,
          startOffset: offset
        )
        sessionOffsets[sessionID] = offset &+ UInt64(data.count)
      } catch {
        lastErrorMessage = "モバイルへターミナル出力を送れませんでした: \(error.localizedDescription)"
      }
    case .screenReset:
      // The mobile client treats a later cursor gap as an explicit resync
      // boundary. Do not invent terminal bytes for a local renderer reset.
      refreshCatalog()
    case .bell:
      refreshAgentCatalog()
    case .exited(let status):
      try? host.publishExit(sessionID: sessionID, status: status)
      refreshCatalog()
    case .failed:
      try? host.publishExit(sessionID: sessionID, status: -1)
      refreshCatalog()
    }
  }

  private func terminal(for sessionID: UUID) -> TerminalSession? {
    for project in workspace.projects {
      guard let surface = workspace.surface(for: project.id) else { continue }
      for workspaceTab in surface.workspaceTabs {
        guard
          workspaceTab.tab.kind == .terminal,
          workspaceTab.tab.sessionID == sessionID,
          let terminal = surface.terminalSession(tabID: workspaceTab.tab.id)
        else {
          continue
        }
        return terminal
      }
    }
    return nil
  }

  private func applyTerminalInput(_ accepted: MobileAcceptedInput) {
    terminal(for: accepted.sessionID)?.sendInput(accepted.payload)
  }

  private func applyAgentInput(_ accepted: MobileAcceptedAgentInput) {
    _ = try? agentWorkflow.sendInput(
      sessionID: accepted.agentID,
      data: accepted.payload
    )
  }

  private func applyAgentControl(_ accepted: MobileAcceptedAgentControl) {
    switch accepted.action {
    case .interrupt:
      _ = try? agentWorkflow.interrupt(sessionID: accepted.agentID)
    case .stop:
      _ = try? agentWorkflow.stop(sessionID: accepted.agentID)
    }
    refreshCatalog()
  }

  private func applyAgentLaunch(_ accepted: MobileAcceptedAgentLaunch) {
    guard
      let project = workspace.projects.first(where: { $0.id == accepted.projectID }),
      let surface = workspace.materializeSurface(for: project.id),
      let profile = AgentLaunchProfile(rawValue: accepted.profileID)
    else {
      return
    }
    let worktree = accepted.worktreeID.flatMap {
      worktreeCoordinator.availableWorktree(project: project, id: $0)
    }
    _ = agentWorkflow.launch(
      profile: profile,
      modelID: accepted.modelID,
      projectID: project.id,
      projectRoot: project.rootURL,
      surface: surface,
      worktree: worktree
    )
    refreshCatalog()
  }
}

import ClairMobileKit
import Combine
import Foundation

enum MobileAppConnectionPhase: String, Equatable {
  case disconnected
  case pairing
  case connecting
  case connected
  case failed

  var title: String {
    switch self {
    case .disconnected:
      "未接続"
    case .pairing:
      "ペアリング待ち"
    case .connecting:
      "接続中"
    case .connected:
      "接続済み"
    case .failed:
      "接続エラー"
    }
  }
}

struct MobileProjectOption: Identifiable, Equatable {
  let id: UUID
  let title: String
}

@MainActor
final class MobileControlAppModel: ObservableObject {
  @Published private(set) var hosts: [MobileClientHostRecord] = []
  @Published var pendingPairingLink: MobilePairingLink?
  @Published var pairingDisplayName = "Clair Mobile"
  @Published var pairingConfirmedFingerprint = false
  @Published private(set) var connectionPhase: MobileAppConnectionPhase = .disconnected
  @Published private(set) var sessions: [MobileSessionDescriptor] = []
  @Published private(set) var agents: [MobileAgentDescriptor] = []
  @Published private(set) var profiles: [MobileAgentProfileDescriptor] = []
  @Published private(set) var selectedSessionID: UUID?
  @Published private(set) var selectedScrollback = Data()
  @Published private(set) var selectedCursor: UInt64 = 0
  @Published private(set) var selectedHasGap = false
  @Published private(set) var selectedExited = false
  @Published private(set) var lastErrorMessage: String?
  @Published private(set) var lastActivityMessage: String?
  @Published private(set) var localViewport: MobileClientViewport?

  private let secureStore: MobileClientSecureStore
  private let clientState = MobileControlClientModel()
  private var connection: MobileControlClientConnection?
  private var activeHost: MobileClientHostRecord?
  private var deviceKeyPair: MobileDeviceKeyPair?
  private var activeSubscriptionID: UUID?
  private var activeStreamID: UInt32?
  private var streamToSession: [UInt32: UUID] = [:]
  private var waitingEvents: [UInt32: [MobileHostStreamEvent]] = [:]

  init(secureStore: MobileClientSecureStore = .init()) {
    self.secureStore = secureStore
    localViewport = try? MobileClientViewport(rows: 38, columns: 110)
    clientState.setLocalViewport(localViewport)
    do {
      hosts = try secureStore.loadHosts()
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  var isConnected: Bool {
    connectionPhase == .connected
  }

  var selectedSession: MobileSessionDescriptor? {
    guard let selectedSessionID else { return nil }
    return sessions.first { $0.id == selectedSessionID }
  }

  var selectedTerminalText: String {
    String(decoding: selectedScrollback, as: UTF8.self)
  }

  var projectOptions: [MobileProjectOption] {
    let ids = Set(sessions.map(\.projectID))
    return ids.sorted { $0.uuidString < $1.uuidString }.map { id in
      MobileProjectOption(id: id, title: "Project \(id.uuidString.prefix(8))")
    }
  }

  var connectedHost: MobileClientHostRecord? {
    activeHost
  }

  var hostFingerprint: String? {
    activeHost?.hostIdentity.fingerprint
  }

  var endpointDescription: String? {
    activeHost?.endpoint.address
  }

  var grantedScopes: Set<MobileControlScope> {
    activeHost?.credential.scopes ?? []
  }

  var canWriteTerminal: Bool {
    isConnected && grantedScopes.contains(.writeTerminal)
  }

  var canSignal: Bool {
    isConnected && grantedScopes.contains(.signal)
  }

  var canSpawnSession: Bool {
    isConnected && grantedScopes.contains(.spawnSession)
  }

  var canSteerAgent: Bool {
    isConnected && grantedScopes.contains(.steerAgent)
  }

  func setLocalViewport(rows: UInt16, columns: UInt16) {
    guard let viewport = try? MobileClientViewport(rows: rows, columns: columns) else {
      return
    }
    localViewport = viewport
    clientState.setLocalViewport(viewport)
  }

  func receiveDeepLink(_ url: URL) {
    do {
      pendingPairingLink = try MobilePairingLink(deepLink: url)
      pairingConfirmedFingerprint = false
      pairingDisplayName = "Clair Mobile"
      connectionPhase = .pairing
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = "ペアリングリンクを読み込めませんでした: \(error.localizedDescription)"
    }
  }

  func cancelPairing() {
    pendingPairingLink = nil
    pairingConfirmedFingerprint = false
    if connectionPhase == .pairing {
      connectionPhase = .disconnected
    }
  }

  func pairPendingHost() {
    Task { @MainActor [weak self] in
      await self?.pairPendingHostAsync()
    }
  }

  func connect(to host: MobileClientHostRecord) {
    Task { @MainActor [weak self] in
      await self?.connectAsync(to: host)
    }
  }

  func disconnect() {
    connection?.close()
    connection = nil
    activeHost = nil
    deviceKeyPair = nil
    activeSubscriptionID = nil
    activeStreamID = nil
    streamToSession.removeAll()
    waitingEvents.removeAll()
    sessions = []
    agents = []
    profiles = []
    selectedSessionID = nil
    clearSelectedState()
    connectionPhase = .disconnected
    lastActivityMessage = nil
  }

  func disconnectSelectedSession() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let connection {
        await unsubscribeCurrent(connection: connection)
      }
      selectedSessionID = nil
      clearSelectedState()
      lastActivityMessage = "セッションの接続を解除しました。"
    }
  }

  func forget(_ host: MobileClientHostRecord) {
    if activeHost?.hostIdentity.hostID == host.hostIdentity.hostID {
      disconnect()
    }
    do {
      try secureStore.remove(hostID: host.hostIdentity.hostID)
      hosts.removeAll { $0.hostIdentity.hostID == host.hostIdentity.hostID }
    } catch {
      lastErrorMessage = "保存済みホストを削除できませんでした: \(error.localizedDescription)"
    }
  }

  func refresh() {
    Task { @MainActor [weak self] in
      await self?.refreshCatalogAsync()
    }
  }

  func selectSession(_ session: MobileSessionDescriptor) {
    Task { @MainActor [weak self] in
      await self?.selectSessionAsync(session)
    }
  }

  func sendInput(_ text: String) {
    Task { @MainActor [weak self] in
      await self?.sendInputAsync(text)
    }
  }

  func interruptSelectedSession() {
    Task { @MainActor [weak self] in
      await self?.interruptSelectedSessionAsync()
    }
  }

  func launch(
    profile: MobileAgentProfileDescriptor,
    modelID: String?,
    projectID: UUID
  ) {
    Task { @MainActor [weak self] in
      await self?.launchAsync(profile: profile, modelID: modelID, projectID: projectID)
    }
  }

  func sendAgentCommand(_ command: String, to agent: MobileAgentDescriptor) {
    Task { @MainActor [weak self] in
      await self?.sendAgentCommandAsync(command, to: agent)
    }
  }

  func controlAgent(_ agent: MobileAgentDescriptor, action: MobileAgentControlAction) {
    Task { @MainActor [weak self] in
      await self?.controlAgentAsync(agent, action: action)
    }
  }

  private func pairPendingHostAsync() async {
    guard let link = pendingPairingLink else { return }
    guard pairingConfirmedFingerprint else {
      lastErrorMessage = "fingerprintを確認してから接続してください。"
      return
    }
    guard !pairingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      lastErrorMessage = "端末名を入力してください。"
      return
    }

    connectionPhase = .connecting
    do {
      let endpoint = try MobileControlEndpoint(kind: link.transport, address: link.endpoint)
      let keyPair = MobileDeviceKeyPair()
      let client = try makeConnection(endpoint: endpoint, hostIdentity: link.hostIdentity)
      connection = client
      try await client.connect()
      let initialize = try await client.initialize(
        hello: MobileClientHello(
          clientName: "Clair Mobile",
          version: link.hostIdentity.protocolVersion
        )
      )
      guard initialize.isEnabled, initialize.hostIdentity == link.hostIdentity else {
        throw MobileHostError.invalidHostIdentity
      }

      let pairRequest = try MobileControlRequestFactory.pair(
        request: MobilePairRequest(
          link: link,
          displayName: pairingDisplayName,
          devicePublicKey: keyPair.publicKeyRepresentation,
          confirmedFingerprint: link.hostIdentity.fingerprint
        )
      )
      let pairResponse = try await client.request(pairRequest)
      let credential: MobileDeviceCredential = try MobileControlClientConnection.decodeResult(
        pairResponse
      )
      let host = try MobileClientHostRecord(
        endpoint: endpoint,
        hostIdentity: link.hostIdentity,
        credential: credential
      )
      try secureStore.save(host: host, keyPair: keyPair)
      hosts.removeAll { $0.hostIdentity.hostID == host.hostIdentity.hostID }
      hosts.append(host)
      hosts.sort { $0.hostIdentity.hostID.uuidString < $1.hostIdentity.hostID.uuidString }
      activeHost = host
      deviceKeyPair = keyPair
      pendingPairingLink = nil
      pairingConfirmedFingerprint = false
      try await authenticate(client: client, host: host, keyPair: keyPair)
      connectionPhase = .connected
      lastErrorMessage = nil
      await refreshCatalogAsync()
    } catch {
      failConnection(error)
    }
  }

  private func connectAsync(to host: MobileClientHostRecord) async {
    guard let keyPair = try? secureStore.keyPair(for: host.hostIdentity.hostID) else {
      lastErrorMessage = "このホストのdevice keyが見つかりません。QRで再ペアリングしてください。"
      connectionPhase = .failed
      return
    }

    connectionPhase = .connecting
    do {
      let client = try makeConnection(endpoint: host.endpoint, hostIdentity: host.hostIdentity)
      connection = client
      try await client.connect()
      let initialize = try await client.initialize(
        hello: MobileClientHello(
          clientName: "Clair Mobile",
          version: host.hostIdentity.protocolVersion
        )
      )
      guard initialize.isEnabled, initialize.hostIdentity == host.hostIdentity else {
        throw MobileHostError.invalidHostIdentity
      }
      activeHost = host
      deviceKeyPair = keyPair
      try await authenticate(client: client, host: host, keyPair: keyPair)
      connectionPhase = .connected
      lastErrorMessage = nil
      await refreshCatalogAsync()
    } catch {
      failConnection(error)
    }
  }

  private func authenticate(
    client: MobileControlClientConnection,
    host: MobileClientHostRecord,
    keyPair: MobileDeviceKeyPair
  ) async throws {
    let challengeRequest = try MobileControlRequestFactory.challenge(
      deviceID: host.credential.deviceID
    )
    let challengeResponse = try await client.request(challengeRequest)
    let challenge: MobileAuthenticationChallenge = try MobileControlClientConnection.decodeResult(
      challengeResponse
    )
    let signature = try keyPair.sign(challenge.bytes)
    let authenticationRequest = try MobileControlRequestFactory.authenticate(
      request: MobileAuthenticateRequest(
        deviceID: host.credential.deviceID,
        token: host.credential.token,
        challenge: challenge,
        signature: signature
      )
    )
    let authenticationResponse = try await client.request(authenticationRequest)
    let result: MobileJSONValue = try MobileControlClientConnection.decodeResult(
      authenticationResponse
    )
    guard case .object(let values) = result,
      case .bool(true)? = values["authenticated"]
    else {
      throw MobileHostError.authenticationFailed
    }
  }

  private func refreshCatalogAsync() async {
    guard let connection else { return }
    do {
      let sessionResponse = try await connection.request(MobileControlRequestFactory.sessionList())
      let sessionResult: MobileSessionListResult = try MobileControlClientConnection.decodeResult(
        sessionResponse
      )
      sessions = sessionResult.sessions.sorted {
        $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }

      let agentResponse = try await connection.request(MobileControlRequestFactory.agentList())
      let agentResult: MobileAgentCatalog = try MobileControlClientConnection.decodeResult(
        agentResponse
      )
      agents = agentResult.agents
      profiles = agentResult.profiles
      if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
        self.selectedSessionID = nil
        clearSelectedState()
      }
      lastActivityMessage = "カタログを更新しました。"
    } catch {
      failConnection(error)
    }
  }

  private func selectSessionAsync(_ session: MobileSessionDescriptor) async {
    guard let connection else { return }
    if selectedSessionID == session.id {
      return
    }
    await unsubscribeCurrent(connection: connection)
    let requestedCursor = clientState.state(for: session.id)?.cursor ?? 0
    do {
      let request = try MobileControlRequestFactory.subscribe(
        request: MobileSessionSubscribeRequest(
          sessionID: session.id,
          epoch: clientState.state(for: session.id)?.epoch,
          cursor: requestedCursor
        )
      )
      let response = try await connection.request(request)
      let metadata: MobileSessionSubscribeMetadata = try MobileControlClientConnection.decodeResult(
        response
      )
      let receipt = MobileSubscriptionReceipt(
        subscriptionID: metadata.subscriptionID,
        streamID: metadata.streamID,
        session: metadata.session,
        events: []
      )
      _ = try clientState.attach(
        descriptor: session,
        receipt: receipt,
        initialCursor: requestedCursor
      )
      activeSubscriptionID = metadata.subscriptionID
      activeStreamID = metadata.streamID
      streamToSession[metadata.streamID] = session.id
      selectedSessionID = session.id
      publishSelectedState()
      drainWaitingEvents(for: metadata.streamID)
      lastActivityMessage = "\(session.title) に接続しました。"
    } catch {
      lastErrorMessage = "セッションを開けませんでした: \(error.localizedDescription)"
    }
  }

  private func unsubscribeCurrent(connection: MobileControlClientConnection) async {
    guard let subscriptionID = activeSubscriptionID else { return }
    do {
      let request = try MobileControlRequest(
        method: .sessionUnsubscribe,
        parameters: MobileUnsubscribeRequest(subscriptionID: subscriptionID)
      )
      _ = try await connection.request(request)
    } catch {
      lastErrorMessage = "前のセッション購読を解除できませんでした: \(error.localizedDescription)"
    }
    if let activeStreamID {
      streamToSession[activeStreamID] = nil
      waitingEvents[activeStreamID] = nil
    }
    activeSubscriptionID = nil
    activeStreamID = nil
  }

  private func sendInputAsync(_ text: String) async {
    guard canWriteTerminal else {
      lastErrorMessage = "この端末には write_terminal 権限がありません。Mac側で付与してください。"
      return
    }
    guard let connection, let activeHost, let selectedSessionID else { return }
    let data = Data((text + "\r").utf8)
    guard !data.isEmpty else { return }
    do {
      let operation = MobileTerminalInputOperation(
        deviceID: activeHost.credential.deviceID,
        sessionID: selectedSessionID,
        payload: data
      )
      let request = try MobileControlRequestFactory.terminalInput(operation: operation)
      let response = try await connection.request(request)
      _ = try MobileControlClientConnection.decodeResult(response) as MobileAcceptedInput
      lastActivityMessage = "モバイル入力を送信しました。"
    } catch {
      lastErrorMessage = "入力を送信できませんでした: \(error.localizedDescription)"
    }
  }

  private func interruptSelectedSessionAsync() async {
    guard canSignal else {
      lastErrorMessage = "この端末には signal 権限がありません。"
      return
    }
    guard let connection, let activeHost, let selectedSessionID else { return }
    do {
      let request = try MobileControlRequest(
        method: .terminalInterrupt,
        parameters: MobileTerminalInterruptRequest(
          deviceID: activeHost.credential.deviceID,
          sessionID: selectedSessionID
        )
      )
      let response = try await connection.request(request)
      _ = try MobileControlClientConnection.decodeResult(response) as MobileAcceptedInput
      lastActivityMessage = "割り込みを送信しました。"
    } catch {
      lastErrorMessage = "割り込みを送信できませんでした: \(error.localizedDescription)"
    }
  }

  private func launchAsync(
    profile: MobileAgentProfileDescriptor,
    modelID: String?,
    projectID: UUID
  ) async {
    guard canSpawnSession else {
      lastErrorMessage = "この端末には spawn_session 権限がありません。"
      return
    }
    guard let connection, let activeHost else { return }
    do {
      let operation = MobileAgentLaunchOperation(
        deviceID: activeHost.credential.deviceID,
        projectID: projectID,
        profileID: profile.id,
        modelID: modelID
      )
      let request = try MobileControlRequestFactory.agentLaunch(operation: operation)
      let response = try await connection.request(request)
      _ = try MobileControlClientConnection.decodeResult(response) as MobileAcceptedAgentLaunch
      await refreshCatalogAsync()
      let modelLabel = modelID.map { " · \($0)" } ?? ""
      lastActivityMessage = "\(profile.title)\(modelLabel) の起動を要求しました。"
    } catch {
      lastErrorMessage = "agentを起動できませんでした: \(error.localizedDescription)"
    }
  }

  private func sendAgentCommandAsync(
    _ command: String,
    to agent: MobileAgentDescriptor
  ) async {
    guard canSteerAgent else {
      lastErrorMessage = "この端末には steer_agent 権限がありません。"
      return
    }
    let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, let connection, let activeHost else { return }
    do {
      let operation = MobileAgentInputOperation(
        deviceID: activeHost.credential.deviceID,
        agentID: agent.id,
        payload: Data((normalized + "\r").utf8)
      )
      let request = try MobileControlRequestFactory.agentInput(operation: operation)
      let response = try await connection.request(request)
      _ = try MobileControlClientConnection.decodeResult(response) as MobileAcceptedAgentInput
      lastActivityMessage = "\(agent.title) に \(normalized) を送信しました。"
    } catch {
      lastErrorMessage = "agentコマンドを送信できませんでした: \(error.localizedDescription)"
    }
  }

  private func controlAgentAsync(
    _ agent: MobileAgentDescriptor,
    action: MobileAgentControlAction
  ) async {
    let requiredScope: MobileControlScope = action == .interrupt ? .signal : .terminate
    guard grantedScopes.contains(requiredScope) else {
      lastErrorMessage = "この端末には \(requiredScope.rawValue) 権限がありません。"
      return
    }
    guard let connection, let activeHost else { return }
    do {
      let operation = MobileAgentControlOperation(
        deviceID: activeHost.credential.deviceID,
        agentID: agent.id,
        action: action
      )
      let request = try MobileControlRequest(
        method: action == .interrupt ? .agentInterrupt : .agentStop,
        parameters: operation
      )
      let response = try await connection.request(request)
      _ = try MobileControlClientConnection.decodeResult(response) as MobileAcceptedAgentControl
      await refreshCatalogAsync()
      lastActivityMessage = "\(agent.title) に \(action == .interrupt ? "割り込み" : "停止")を送信しました。"
    } catch {
      lastErrorMessage = "agent操作に失敗しました: \(error.localizedDescription)"
    }
  }

  private func makeConnection(
    endpoint: MobileControlEndpoint,
    hostIdentity: MobileHostIdentity
  ) throws -> MobileControlClientConnection {
    let client = try MobileControlClientConnection(
      endpoint: endpoint,
      expectedHostIdentity: hostIdentity
    )
    client.onStreamEvent = { [weak self] event in
      Task { @MainActor [weak self] in
        self?.receive(event)
      }
    }
    client.onError = { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self, self.connection != nil else { return }
        self.failConnection(error)
      }
    }
    return client
  }

  private func receive(_ event: MobileHostStreamEvent) {
    let streamID: UInt32
    switch event {
    case .output(let frame):
      streamID = frame.streamID
    case .gap(let gap):
      streamID = gap.streamID
    case .exit(let exit):
      streamID = exit.streamID
    }
    guard let sessionID = streamToSession[streamID] else {
      if waitingEvents[streamID, default: []].count < 256 {
        waitingEvents[streamID, default: []].append(event)
      }
      return
    }
    do {
      let result = try clientState.apply(event, sessionID: sessionID)
      switch result {
      case .gap:
        lastActivityMessage = "ストリームの保持範囲を超えました。再接続して再同期してください。"
      case .exit:
        lastActivityMessage = "セッションが終了しました。"
      case .output, .duplicateOutput, .duplicateExit:
        break
      }
      if sessionID == selectedSessionID {
        publishSelectedState()
      }
    } catch {
      lastErrorMessage = "ターミナルイベントを適用できませんでした: \(error.localizedDescription)"
    }
  }

  private func drainWaitingEvents(for streamID: UInt32) {
    let events = waitingEvents.removeValue(forKey: streamID) ?? []
    for event in events {
      receive(event)
    }
  }

  private func publishSelectedState() {
    guard let selectedSessionID,
      let state = clientState.state(for: selectedSessionID)
    else {
      clearSelectedState()
      return
    }
    selectedScrollback = state.scrollback
    selectedCursor = state.cursor
    selectedHasGap = state.isGap
    selectedExited = state.isExited
  }

  private func clearSelectedState() {
    selectedScrollback = Data()
    selectedCursor = 0
    selectedHasGap = false
    selectedExited = false
  }

  private func failConnection(_ error: Error) {
    connection?.close()
    connection = nil
    activeHost = nil
    deviceKeyPair = nil
    activeSubscriptionID = nil
    activeStreamID = nil
    streamToSession.removeAll()
    waitingEvents.removeAll()
    sessions = []
    agents = []
    profiles = []
    selectedSessionID = nil
    clearSelectedState()
    connectionPhase = .failed
    lastErrorMessage = error.localizedDescription
  }
}

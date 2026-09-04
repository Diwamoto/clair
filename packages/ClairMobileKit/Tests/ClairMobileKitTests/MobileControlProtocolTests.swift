import Foundation
import Testing

@testable import ClairMobileKit

@Test
func negotiatesTheIntersectionWithoutDowngradingTheMajor() throws {
  let client = MobileClientHello(
    clientName: "Clair iPhone",
    version: .init(major: 1, minor: 3),
    maxFramePayload: 8 * 1024,
    capabilities: [.rawTerminal, .terminalInput]
  )
  let server = MobileServerHello(
    version: .init(major: 1, minor: 1),
    maxFramePayload: 64 * 1024,
    capabilities: [.rawTerminal, .agentLaunch]
  )

  let negotiated = try MobileProtocolNegotiator.negotiate(client: client, server: server)

  #expect(negotiated.version == .init(major: 1, minor: 1))
  #expect(negotiated.maxFramePayload == 8 * 1024)
  #expect(negotiated.capabilities == [.rawTerminal])
}

@Test
func rejectsAProtocolMajorMismatch() {
  let client = MobileClientHello(
    clientName: "Clair iPad",
    version: .init(major: 2, minor: 0)
  )
  let server = MobileServerHello()

  #expect(throws: MobileProtocolError.unsupportedMajor(expected: 1, actual: 2)) {
    try MobileProtocolNegotiator.negotiate(client: client, server: server)
  }
}

@Test
func binaryTerminalFramesPreserveRawBytes() throws {
  let frame = try MobileTerminalFrame(
    kind: .output,
    version: .init(major: 1, minor: 2),
    streamID: 7,
    sessionEpoch: 42,
    startOffset: 99,
    payload: Data([0x00, 0xff, 0x1b, 0x9b, 0x41])
  )

  let decoded = try MobileTerminalFrame.decode(frame.encoded)

  #expect(decoded == frame)
  #expect(decoded.version == .init(major: 1, minor: 2))
  #expect(decoded.encoded.count == MobileTerminalFrame.headerLength + 5)
}

@Test
func binaryTerminalFramesRejectTrailingAndOversizedData() throws {
  let frame = try MobileTerminalFrame(
    kind: .snapshot,
    streamID: 1,
    sessionEpoch: 1,
    startOffset: 0,
    payload: Data([1, 2, 3])
  )

  var trailing = frame.encoded
  trailing.append(4)
  #expect(throws: MobileProtocolError.trailingFrameBytes(1)) {
    try MobileTerminalFrame.decode(trailing)
  }

  #expect(throws: MobileProtocolError.frameTooLarge(4)) {
    try MobileTerminalFrame(
      kind: .output,
      streamID: 1,
      sessionEpoch: 1,
      startOffset: 0,
      payload: Data([1, 2, 3, 4]),
      maximumPayloadLength: 3
    )
  }
}

@Test
func catalogUsesStableIDsAndWorktreeScope() {
  let firstWorktree = UUID()
  let secondWorktree = UUID()
  let first = session(worktreeID: firstWorktree, title: "Codex")
  let second = session(worktreeID: secondWorktree, title: "Claude")
  let unscoped = session(worktreeID: nil, title: "Shell")
  let catalog = MobileSessionCatalog(sessions: [first, second, unscoped])
  let grant = MobileDeviceGrant(
    deviceID: UUID(),
    scopes: [.view],
    allowedWorktreeIDs: [firstWorktree]
  )

  #expect(catalog.visibleSessions(for: grant).map(\.id) == [first.id])
}

@Test
func inputSequencerUsesArrivalOrderAndMakesDuplicatesIdempotent() throws {
  let deviceID = UUID()
  let sessionID = UUID()
  let grant = MobileDeviceGrant(deviceID: deviceID, scopes: [.view, .writeTerminal])
  let visible: Set<UUID> = [sessionID]
  let operationID = UUID()
  let first = MobileTerminalInputOperation(
    id: operationID,
    deviceID: deviceID,
    sessionID: sessionID,
    payload: Data("first".utf8)
  )
  let second = MobileTerminalInputOperation(
    deviceID: deviceID,
    sessionID: sessionID,
    payload: Data("second".utf8)
  )
  var sequencer = MobileInputSequencer(maximumRememberedOperations: 8)

  let acceptedFirst = try sequencer.accept(first, grant: grant, visibleSessionIDs: visible)
  let acceptedSecond = try sequencer.accept(second, grant: grant, visibleSessionIDs: visible)
  let duplicate = try sequencer.accept(first, grant: grant, visibleSessionIDs: visible)

  #expect(acceptedFirst.arrivalSequence == 1)
  #expect(acceptedSecond.arrivalSequence == 2)
  #expect(duplicate.arrivalSequence == 1)
  #expect(duplicate.isDuplicate)
  #expect(duplicate.payload == first.payload)
}

@Test
func inputSequencerRejectsRevokedOrMismatchedOperations() throws {
  let deviceID = UUID()
  let sessionID = UUID()
  let operation = MobileTerminalInputOperation(
    deviceID: deviceID,
    sessionID: sessionID,
    payload: Data("input".utf8)
  )
  var sequencer = MobileInputSequencer()
  let revoked = MobileDeviceGrant(
    deviceID: deviceID,
    scopes: [.writeTerminal],
    isRevoked: true
  )
  #expect(throws: MobileProtocolError.revokedDevice) {
    try sequencer.accept(operation, grant: revoked, visibleSessionIDs: [sessionID])
  }

  let readOnly = MobileDeviceGrant(deviceID: deviceID, scopes: [.view])
  #expect(throws: MobileProtocolError.invalidScope(.writeTerminal)) {
    try sequencer.accept(operation, grant: readOnly, visibleSessionIDs: [sessionID])
  }
}

@Test
func inputOperationIDCannotBeReusedForDifferentPayload() throws {
  let deviceID = UUID()
  let sessionID = UUID()
  let operationID = UUID()
  let grant = MobileDeviceGrant(deviceID: deviceID, scopes: [.writeTerminal])
  let first = MobileTerminalInputOperation(
    id: operationID,
    deviceID: deviceID,
    sessionID: sessionID,
    payload: Data("one".utf8)
  )
  let reused = MobileTerminalInputOperation(
    id: operationID,
    deviceID: deviceID,
    sessionID: sessionID,
    payload: Data("two".utf8)
  )
  var sequencer = MobileInputSequencer()
  _ = try sequencer.accept(first, grant: grant, visibleSessionIDs: [sessionID])

  #expect(throws: MobileProtocolError.operationIDReuse(operationID)) {
    try sequencer.accept(reused, grant: grant, visibleSessionIDs: [sessionID])
  }
}

@Test
func agentControlContractExposesFactualStateAndCapabilities() throws {
  let agent = MobileAgentDescriptor(
    id: UUID(),
    projectID: UUID(),
    profileID: "codex",
    title: "Codex",
    cwd: "/private/project",
    lifecycle: .running,
    state: .attention,
    attention: true,
    capabilities: [.agentCatalog, .agentStatus, .agentControl, .terminalInput]
  )
  let encoded = try JSONEncoder().encode(agent)
  let decoded = try JSONDecoder().decode(MobileAgentDescriptor.self, from: encoded)

  #expect(decoded == agent)
  #expect(decoded.state == .attention)
  #expect(decoded.capabilities.contains(.agentControl))
  #expect(MobileControlMethod.agentList.rawValue == "agent/list")
  #expect(MobileControlMethod.agentInterrupt.rawValue == "agent/interrupt")
}

@Test
func agentControlAuthorizerRequiresMatchingScopeAndIdentity() throws {
  let deviceID = UUID()
  let agent = MobileAgentDescriptor(
    id: UUID(),
    projectID: UUID(),
    profileID: "claude-code",
    title: "Claude Code",
    cwd: "/private/project",
    lifecycle: .running,
    state: .running,
    capabilities: [.agentControl, .terminalInterrupt]
  )
  let operation = MobileAgentControlOperation(
    deviceID: deviceID,
    agentID: agent.id,
    action: .interrupt
  )
  let grant = MobileDeviceGrant(
    deviceID: deviceID,
    scopes: [.view, .signal]
  )

  let accepted = try MobileAgentControlAuthorizer.authorize(
    operation,
    agent: agent,
    grant: grant
  )
  #expect(accepted.operationID == operation.id)
  #expect(accepted.action == .interrupt)

  let readOnly = MobileDeviceGrant(deviceID: deviceID, scopes: [.view])
  #expect(throws: MobileProtocolError.invalidScope(.signal)) {
    try MobileAgentControlAuthorizer.authorize(operation, agent: agent, grant: readOnly)
  }
}

@Test
func agentLaunchAuthorizerOnlyAcceptsRegisteredProfilesAndVisibleWorktrees() throws {
  let deviceID = UUID()
  let projectID = UUID()
  let worktreeID = UUID()
  let operation = MobileAgentLaunchOperation(
    deviceID: deviceID,
    projectID: projectID,
    profileID: "codex",
    worktreeID: worktreeID
  )
  let grant = MobileDeviceGrant(
    deviceID: deviceID,
    scopes: [.view, .spawnSession],
    allowedWorktreeIDs: [worktreeID]
  )

  let accepted = try MobileAgentLaunchAuthorizer.authorize(
    operation,
    registeredProfiles: ["codex", "claude-code"],
    grant: grant
  )
  #expect(accepted.operationID == operation.id)
  #expect(accepted.profileID == "codex")

  let unknownProfile = MobileAgentLaunchOperation(
    deviceID: deviceID,
    projectID: projectID,
    profileID: "arbitrary-shell",
    worktreeID: worktreeID
  )
  #expect(throws: MobileProtocolError.invalidAgentProfile) {
    try MobileAgentLaunchAuthorizer.authorize(
      unknownProfile,
      registeredProfiles: ["codex"],
      grant: grant
    )
  }

  let directProjectLaunch = MobileAgentLaunchOperation(
    deviceID: deviceID,
    projectID: projectID,
    profileID: "codex"
  )
  #expect(throws: MobileProtocolError.sessionNotVisible(projectID)) {
    try MobileAgentLaunchAuthorizer.authorize(
      directProjectLaunch,
      registeredProfiles: ["codex"],
      grant: grant
    )
  }
}

@Test
func agentInputAuthorizerRequiresSteerScopeAndPayload() throws {
  let deviceID = UUID()
  let agent = MobileAgentDescriptor(
    id: UUID(),
    projectID: UUID(),
    profileID: "opencode",
    title: "OpenCode",
    cwd: "/private/project",
    lifecycle: .running,
    state: .running,
    capabilities: [.agentControl, .terminalInput]
  )
  let operation = MobileAgentInputOperation(
    deviceID: deviceID,
    agentID: agent.id,
    payload: Data("continue\n".utf8)
  )
  let grant = MobileDeviceGrant(
    deviceID: deviceID,
    scopes: [.view, .steerAgent]
  )
  let accepted = try MobileAgentInputAuthorizer.authorize(
    operation,
    agent: agent,
    grant: grant
  )
  #expect(accepted.operationID == operation.id)
  #expect(accepted.payload == operation.payload)

  let empty = MobileAgentInputOperation(
    deviceID: deviceID,
    agentID: agent.id,
    payload: Data()
  )
  #expect(throws: MobileProtocolError.invalidOperationPayload) {
    try MobileAgentInputAuthorizer.authorize(empty, agent: agent, grant: grant)
  }
}

private func session(worktreeID: UUID?, title: String) -> MobileSessionDescriptor {
  MobileSessionDescriptor(
    id: UUID(),
    projectID: UUID(),
    worktreeID: worktreeID,
    title: title,
    cwd: "/private/project",
    lifecycle: .running,
    capabilities: [.rawTerminal]
  )
}

@Test
func mobileHostPairingIsOneTimeAndPersistsOnlyNonSecretMaterial() throws {
  let fileURL = temporaryHostStoreURL()
  defer { try? FileManager.default.removeItem(at: fileURL) }

  let identity = MobileHostIdentity(
    hostID: UUID(),
    fingerprint: "sha256:test-host-fingerprint"
  )
  let host = try MobileControlHost(
    store: MobileHostStore(fileURL: fileURL),
    identity: identity
  )
  _ = try host.setEnabled(true)
  let link = try host.createPairingLink(endpoint: "wss://clair.test/mobile")
  let keyPair = MobileDeviceKeyPair()
  let credential = try host.pair(
    link: link,
    displayName: "Daiki iPhone",
    devicePublicKey: keyPair.publicKeyRepresentation
  )

  let persisted = String(
    decoding: try Data(contentsOf: fileURL),
    as: UTF8.self
  )
  #expect(!persisted.contains(link.bootstrapSecret))
  #expect(!persisted.contains(credential.token))
  #expect(host.devices().map(\.id) == [credential.deviceID])
  #expect(throws: MobileHostError.invalidPairingLink) {
    try host.pair(
      link: link,
      displayName: "Reused iPhone",
      devicePublicKey: MobileDeviceKeyPair().publicKeyRepresentation
    )
  }

  let restored = try MobileControlHost(store: MobileHostStore(fileURL: fileURL))
  #expect(restored.identity == identity)
  #expect(restored.devices().first?.id == credential.deviceID)
}

@Test
func mobileHostAuthenticatesWithFreshChallengeAndRevokesConnections() throws {
  let host = try makeEnabledHost()
  let keyPair = MobileDeviceKeyPair()
  let link = try host.createPairingLink(endpoint: "tailscale://clair/mobile")
  let credential = try host.pair(
    link: link,
    displayName: "Daiki iPad",
    devicePublicKey: keyPair.publicKeyRepresentation
  )
  let challenge = try host.issueChallenge(for: credential.deviceID)
  let connectionID = UUID()
  let authenticated = try host.authenticate(
    deviceID: credential.deviceID,
    token: credential.token,
    challenge: challenge,
    signature: try keyPair.sign(challenge.bytes),
    connectionID: connectionID
  )
  #expect(authenticated == connectionID)

  let closed = try host.revokeDevice(credential.deviceID)
  #expect(closed == [connectionID])
  #expect(host.devices().first?.isRevoked == true)
  #expect(throws: MobileHostError.revokedDevice) {
    try host.issueChallenge(for: credential.deviceID)
  }
}

@Test
func mobileHostRejectsExpiredPairingAndFingerprintChanges() throws {
  let host = try makeEnabledHost()
  let now = Date(timeIntervalSince1970: 1_000)
  let link = try host.createPairingLink(
    endpoint: "cloudflare://clair/mobile",
    now: now,
    lifetime: 5
  )
  #expect(throws: MobileHostError.pairingExpired) {
    try host.pair(
      link: link,
      displayName: "Expired",
      devicePublicKey: MobileDeviceKeyPair().publicKeyRepresentation,
      now: now.addingTimeInterval(6)
    )
  }

  let replacement = try host.createPairingLink(
    endpoint: "cloudflare://clair/mobile",
    now: now
  )
  let changedIdentityLink = MobilePairingLink(
    id: replacement.id,
    endpoint: replacement.endpoint,
    hostIdentity: MobileHostIdentity(
      hostID: replacement.hostIdentity.hostID,
      fingerprint: "sha256:changed"
    ),
    bootstrapSecret: replacement.bootstrapSecret,
    expiresAt: replacement.expiresAt
  )
  #expect(throws: MobileHostError.invalidHostIdentity) {
    try host.pair(
      link: changedIdentityLink,
      displayName: "Wrong host",
      devicePublicKey: MobileDeviceKeyPair().publicKeyRepresentation,
      now: now
    )
  }
}

@Test
func mobileHostKeepsSubscriberCursorsIndependentAndReportsGaps() throws {
  let host = try makeEnabledHost()
  let keyPair = MobileDeviceKeyPair()
  let link = try host.createPairingLink(endpoint: "loopback://clair/mobile")
  let credential = try host.pair(
    link: link,
    displayName: "Viewer",
    devicePublicKey: keyPair.publicKeyRepresentation
  )
  let session = session(worktreeID: nil, title: "Codex")
  try host.registerSession(session, epoch: 7)

  let first = try host.subscribe(
    deviceID: credential.deviceID,
    sessionID: session.id,
    epoch: 7,
    cursor: 0
  )
  try host.publishOutput(sessionID: session.id, epoch: 7, data: Data("hello".utf8))
  let firstEvents = try host.poll(subscriptionID: first.subscriptionID)
  #expect(firstEvents.count == 1)
  if case .output(let frame) = firstEvents[0] {
    #expect(frame.payload == Data("hello".utf8))
    #expect(frame.startOffset == 0)
  } else {
    Issue.record("The first subscriber did not receive output.")
  }

  let replay = try host.subscribe(
    deviceID: credential.deviceID,
    sessionID: session.id,
    epoch: 7,
    cursor: 0
  )
  #expect(replay.events.count == 1)

  let slow = try host.subscribe(
    deviceID: credential.deviceID,
    sessionID: session.id,
    epoch: 7,
    cursor: 5,
    maximumQueueBytes: 4
  )
  try host.publishOutput(
    sessionID: session.id,
    epoch: 7,
    data: Data(repeating: 0x61, count: 8)
  )
  let slowEvents = try host.poll(subscriptionID: slow.subscriptionID)
  #expect(slowEvents.count == 1)
  if case .gap(let gap) = slowEvents[0] {
    #expect(gap.startOffset == 5)
    #expect(gap.endOffset == 13)
  } else {
    Issue.record("The slow subscriber did not receive a typed gap.")
  }

  let boundedHost = try makeEnabledHost()
  let boundedKey = MobileDeviceKeyPair()
  let boundedLink = try boundedHost.createPairingLink(endpoint: "loopback://bounded")
  let boundedCredential = try boundedHost.pair(
    link: boundedLink,
    displayName: "Bounded viewer",
    devicePublicKey: boundedKey.publicKeyRepresentation
  )
  let boundedSession = MobileSessionDescriptor(
    id: UUID(),
    projectID: UUID(),
    title: "Shell",
    cwd: "/private/project",
    lifecycle: .running,
    capabilities: [.rawTerminal]
  )
  try boundedHost.registerSession(boundedSession, epoch: 1)
  try boundedHost.publishOutput(
    sessionID: boundedSession.id,
    epoch: 1,
    data: Data(repeating: 0x62, count: 128),
    maximumJournalBytes: 64
  )
  let gap = try boundedHost.subscribe(
    deviceID: boundedCredential.deviceID,
    sessionID: boundedSession.id,
    epoch: 1,
    cursor: 0
  )
  #expect(gap.events.count == 1)
  if case .gap(let event) = gap.events[0] {
    #expect(event.startOffset == 0)
    #expect(event.endOffset == 128)
  } else {
    Issue.record("The journal did not report a cursor gap.")
  }
}

@Test
func mobileHostAppliesInputInArrivalOrderAndDoesNotResizeFromViewport() throws {
  let host = try makeEnabledHost()
  let keyPair = MobileDeviceKeyPair()
  let link = try host.createPairingLink(endpoint: "loopback://clair/input")
  let credential = try host.pair(
    link: link,
    displayName: "Input viewer",
    devicePublicKey: keyPair.publicKeyRepresentation
  )
  try host.setScopes([.view, .writeTerminal, .signal], for: credential.deviceID)
  let session = session(worktreeID: nil, title: "Unknown CLI")
  try host.registerSession(session, epoch: 1)

  let first = MobileTerminalInputOperation(
    deviceID: credential.deviceID,
    sessionID: session.id,
    payload: Data("first".utf8)
  )
  let second = MobileTerminalInputOperation(
    deviceID: credential.deviceID,
    sessionID: session.id,
    payload: Data("second".utf8)
  )
  let acceptedFirst = try host.acceptTerminalInput(first)
  let acceptedSecond = try host.acceptTerminalInput(second)
  let duplicate = try host.acceptTerminalInput(first)
  #expect(acceptedFirst.arrivalSequence == 1)
  #expect(acceptedSecond.arrivalSequence == 2)
  #expect(duplicate.isDuplicate)
  #expect(duplicate.arrivalSequence == 1)

  let interrupt = try host.acceptTerminalInterrupt(
    deviceID: credential.deviceID,
    sessionID: session.id
  )
  #expect(interrupt.payload == Data([0x03]))
  var readOnlySequencer = MobileInputSequencer()
  #expect(throws: MobileProtocolError.invalidScope(.writeTerminal)) {
    try readOnlySequencer.accept(
      first,
      grant: MobileDeviceGrant(deviceID: credential.deviceID, scopes: [.view]),
      visibleSessionIDs: [session.id]
    )
  }
}

@Test
func mobileTransportDecoderHandlesPartialFramesAndRejectsOversizedFrames() throws {
  let terminal = try MobileTerminalFrame(
    kind: .output,
    streamID: 1,
    sessionEpoch: 2,
    startOffset: 0,
    payload: Data([0, 0xff, 0x1b])
  )
  let encoded = try MobileTransportFrame.terminal(terminal).encoded
  var decoder = MobileTransportFrameDecoder()
  var decoded: [MobileTransportFrame] = []
  for byte in encoded {
    decoded.append(contentsOf: try decoder.append(Data([byte])))
  }
  #expect(decoded == [try MobileTransportFrame.terminal(terminal)])
  try decoder.finish()

  var oversized = Data([MobileTransportFrameKind.control.rawValue, 0xff, 0xff, 0xff, 0xff])
  oversized.append(0)
  var oversizedDecoder = MobileTransportFrameDecoder()
  #expect(throws: MobileTransportError.frameTooLarge(4_294_967_295)) {
    try oversizedDecoder.append(oversized)
  }
}

@Test
func mobileRPCConnectionRequiresAuthenticationBeforeProjectAccess() throws {
  let host = try makeEnabledHost()
  let connection = host.makeConnection()
  let initialize = try MobileControlRequest(
    id: "initialize",
    method: .initialize,
    parameters: MobileClientHello(clientName: "Clair iPhone")
  )
  let initializeResponse = connection.handle(initialize)
  #expect(initializeResponse.error == nil)

  let sessionList = connection.handle(
    MobileControlRequest(id: "list", method: .sessionList)
  )
  #expect(sessionList.error?.code == "request_failed")

  let keyPair = MobileDeviceKeyPair()
  let link = try host.createPairingLink(endpoint: "loopback://clair/rpc")
  let pair = try MobileControlRequest(
    id: "pair",
    method: .pair,
    parameters: MobilePairRequest(
      link: link,
      displayName: "RPC viewer",
      devicePublicKey: keyPair.publicKeyRepresentation,
      confirmedFingerprint: host.identity.fingerprint
    )
  )
  let pairResponse = connection.handle(pair)
  #expect(pairResponse.error == nil)
  let credential =
    try pairResponse.result?.decode(MobileDeviceCredential.self)
    ?? { throw MobileHostError.invalidOperation }()
  let challenge = try host.issueChallenge(for: credential.deviceID)
  let auth = try MobileControlRequest(
    id: "auth",
    method: .authenticate,
    parameters: MobileAuthenticateRequest(
      deviceID: credential.deviceID,
      token: credential.token,
      challenge: challenge,
      signature: try keyPair.sign(challenge.bytes)
    )
  )
  let authResponse = connection.handle(auth)
  #expect(authResponse.error == nil)
}

@Test
func mobileClientKeepsViewportLocalAndRecoversFromStreamGaps() throws {
  let descriptor = session(worktreeID: nil, title: "Mobile shell")
  let streamID: UInt32 = 11
  let firstFrame = try MobileTerminalFrame(
    kind: .output,
    streamID: streamID,
    sessionEpoch: 3,
    startOffset: 0,
    payload: Data("abc".utf8)
  )
  let receipt = MobileSubscriptionReceipt(
    subscriptionID: UUID(),
    streamID: streamID,
    session: MobileSessionStreamSnapshot(
      sessionID: descriptor.id,
      epoch: 3,
      currentOffset: 3,
      oldestOffset: 0,
      isExited: false
    ),
    events: [.output(firstFrame)]
  )
  let model = MobileControlClientModel(maximumScrollbackBytes: 4)
  let viewport = try MobileClientViewport(rows: 40, columns: 120)
  model.setLocalViewport(viewport)
  let attached = try model.attach(descriptor: descriptor, receipt: receipt)
  #expect(attached.cursor == 3)
  #expect(attached.scrollback == Data("abc".utf8))
  #expect(model.localViewport == viewport)

  let secondFrame = try MobileTerminalFrame(
    kind: .output,
    streamID: streamID,
    sessionEpoch: 3,
    startOffset: 3,
    payload: Data("def".utf8)
  )
  let applied = try model.apply(.output(secondFrame), sessionID: descriptor.id)
  #expect(applied == .output(sessionID: descriptor.id, data: Data("def".utf8), cursor: 6))
  #expect(model.state(for: descriptor.id)?.scrollback == Data("cdef".utf8))

  let duplicate = try model.apply(.output(secondFrame), sessionID: descriptor.id)
  #expect(duplicate == .duplicateOutput(sessionID: descriptor.id, cursor: 6))

  let gap = MobileTerminalGap(
    streamID: streamID,
    sessionEpoch: 3,
    startOffset: 6,
    endOffset: 18
  )
  let recovered = try model.apply(.gap(gap), sessionID: descriptor.id)
  #expect(recovered == .gap(sessionID: descriptor.id, startOffset: 6, endOffset: 18))
  #expect(model.state(for: descriptor.id)?.cursor == 18)
  #expect(model.state(for: descriptor.id)?.scrollback.isEmpty == true)
}

@Test
func mobileAttentionPayloadContainsOnlyOpaqueWakeMetadata() throws {
  let hostID = UUID()
  let sessionID = UUID()
  let notification = try MobileAttentionNotification(
    wakeID: "wake-opaque-123",
    hostID: hostID,
    sessionID: sessionID,
    kind: .agentNotification
  )
  let encoded = try JSONEncoder().encode(notification)
  let json = String(decoding: encoded, as: UTF8.self)

  #expect(notification.apnsUserInfo["clair_wake_id"] == "wake-opaque-123")
  #expect(notification.apnsUserInfo["clair_host_id"] == hostID.uuidString)
  #expect(notification.apnsUserInfo["clair_session_id"] == sessionID.uuidString)
  #expect(!json.contains("prompt"))
  #expect(!json.contains("cwd"))
  #expect(!json.contains("terminal"))
  #expect(!json.contains("secret"))
}

@Test
func mobileRequestFactoryProjectsSharedControlMethods() throws {
  let hello = MobileClientHello(clientName: "Clair iPad")
  let initialize = try MobileControlRequestFactory.initialize(id: "hello", hello: hello)
  #expect(initialize.method == .initialize)
  #expect(try initialize.decodeParameters(MobileClientHello.self) == hello)

  let sessionID = UUID()
  let operation = MobileTerminalInputOperation(
    deviceID: UUID(),
    sessionID: sessionID,
    payload: Data("raw input".utf8)
  )
  let input = try MobileControlRequestFactory.terminalInput(
    id: "input",
    operation: operation
  )
  #expect(input.method == .terminalInput)
  #expect(try input.decodeParameters(MobileTerminalInputOperation.self) == operation)
}

@Test
func mobileHostDeliversFreshAcceptedOperationsToTheApplicationBridge() throws {
  let host = try makeEnabledHost()
  let keyPair = MobileDeviceKeyPair()
  let link = try host.createPairingLink(endpoint: "loopback://clair/handlers")
  let credential = try host.pair(
    link: link,
    displayName: "Bridge viewer",
    devicePublicKey: keyPair.publicKeyRepresentation
  )
  try host.setScopes(
    [.view, .writeTerminal, .signal, .steerAgent, .terminate, .spawnSession],
    for: credential.deviceID
  )
  let terminal = session(worktreeID: nil, title: "Agent terminal")
  try host.registerSession(terminal, epoch: 1)
  let agent = MobileAgentDescriptor(
    id: terminal.id,
    projectID: terminal.projectID,
    profileID: "codex",
    title: "Codex",
    cwd: terminal.cwd,
    lifecycle: .running,
    state: .running,
    capabilities: [.agentCatalog, .agentStatus, .agentControl, .terminalInput, .terminalInterrupt]
  )
  host.registerAgent(agent)
  try host.registerAgentProfile("codex")

  let recorder = MobileOperationRecorder()
  host.setOperationHandlers(
    MobileControlHostHandlers(
      terminalInput: { recorder.recordTerminal($0) },
      agentInput: { recorder.recordAgentInput($0) },
      agentControl: { recorder.recordAgentControl($0) },
      agentLaunch: { recorder.recordLaunch($0) }
    )
  )

  let terminalOperation = MobileTerminalInputOperation(
    id: UUID(),
    deviceID: credential.deviceID,
    sessionID: terminal.id,
    payload: Data("hello".utf8)
  )
  _ = try host.acceptTerminalInput(terminalOperation)
  _ = try host.acceptTerminalInput(terminalOperation)
  #expect(recorder.terminalInputs.count == 1)
  #expect(recorder.terminalInputs[0].sessionID == terminal.id)

  let agentInput = MobileAgentInputOperation(
    id: UUID(),
    deviceID: credential.deviceID,
    agentID: agent.id,
    payload: Data("steer".utf8)
  )
  _ = try host.acceptAgentInput(agentInput)
  _ = try host.acceptAgentInput(agentInput)
  #expect(recorder.agentInputs.count == 1)

  let control = MobileAgentControlOperation(
    id: UUID(),
    deviceID: credential.deviceID,
    agentID: agent.id,
    action: .interrupt
  )
  _ = try host.acceptAgentControl(control)
  _ = try host.acceptAgentControl(control)
  #expect(recorder.agentControls.count == 1)

  let launch = MobileAgentLaunchOperation(
    id: UUID(),
    deviceID: credential.deviceID,
    projectID: terminal.projectID,
    profileID: "codex"
  )
  _ = try host.acceptAgentLaunch(launch)
  _ = try host.acceptAgentLaunch(launch)
  #expect(recorder.launches.count == 1)
}

#if canImport(Network)
  @Test
  func mobileListenerAndClientCompleteLoopbackAuthentication() async throws {
    let host = try makeEnabledHost()
    let listener = MobileControlListener(
      host: host,
      configuration: MobileControlListenerConfiguration(port: 0)
    )
    let port = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<UInt16, Error>) in
      listener.onReady = { continuation.resume(returning: $0) }
      listener.onError = { continuation.resume(throwing: $0) }
      do {
        try listener.start()
      } catch {
        continuation.resume(throwing: error)
      }
    }
    defer { listener.stop() }

    let endpoint = try MobileControlEndpoint(
      kind: .loopback,
      address: "loopback://127.0.0.1:\(port)"
    )
    let link = try host.createPairingLink(endpoint: endpoint.address)
    let keyPair = MobileDeviceKeyPair()
    let client = try MobileControlClientConnection(endpoint: endpoint)
    defer { client.close() }
    try await client.connect()

    let initialized = try await client.initialize(
      hello: MobileClientHello(clientName: "Clair iPhone loopback")
    )
    #expect(initialized.hostIdentity == host.identity)

    let pairResponse = try await client.request(
      try MobileControlRequestFactory.pair(
        request: MobilePairRequest(
          link: link,
          displayName: "Loopback viewer",
          devicePublicKey: keyPair.publicKeyRepresentation,
          confirmedFingerprint: host.identity.fingerprint
        )
      )
    )
    let credential: MobileDeviceCredential = try MobileControlClientConnection.decodeResult(
      pairResponse)
    let challengeResponse = try await client.request(
      try MobileControlRequestFactory.challenge(deviceID: credential.deviceID)
    )
    let challenge: MobileAuthenticationChallenge = try MobileControlClientConnection.decodeResult(
      challengeResponse
    )
    let authenticationResponse = try await client.request(
      try MobileControlRequestFactory.authenticate(
        request: MobileAuthenticateRequest(
          deviceID: credential.deviceID,
          token: credential.token,
          challenge: challenge,
          signature: try keyPair.sign(challenge.bytes)
        )
      )
    )
    #expect(authenticationResponse.error == nil)

    let descriptor = session(worktreeID: nil, title: "Loopback shell")
    try host.registerSession(descriptor, epoch: 1)
    let sessionsResponse = try await client.request(MobileControlRequestFactory.sessionList())
    let sessions: MobileSessionListResult = try MobileControlClientConnection.decodeResult(
      sessionsResponse
    )
    #expect(sessions.sessions == [descriptor])
  }
#endif

@Test
func mobileDisableClosesRemoteAccessWithoutDeletingLocalSessions() throws {
  let host = try makeEnabledHost()
  let keyPair = MobileDeviceKeyPair()
  let link = try host.createPairingLink(endpoint: "loopback://clair/disable")
  let credential = try host.pair(
    link: link,
    displayName: "Disable viewer",
    devicePublicKey: keyPair.publicKeyRepresentation
  )
  let descriptor = session(worktreeID: nil, title: "Local fallback")
  try host.registerSession(descriptor, epoch: 1)
  let connectionID = UUID()
  let challenge = try host.issueChallenge(for: credential.deviceID)
  _ = try host.authenticate(
    deviceID: credential.deviceID,
    token: credential.token,
    challenge: challenge,
    signature: try keyPair.sign(challenge.bytes),
    connectionID: connectionID
  )

  let closed = try host.setEnabled(false)
  #expect(closed == [connectionID])
  #expect(host.isEnabled == false)
  #expect(try host.streamSnapshot(sessionID: descriptor.id).epoch == 1)
  #expect(throws: MobileHostError.disabled) {
    try host.visibleSessions(for: credential.deviceID)
  }

  _ = try host.setEnabled(true)
  #expect(try host.issueChallenge(for: credential.deviceID).bytes.count == 32)
}

@Test
func mobileDisconnectOnlyRemovesSubscriptionsFromThatConnection() throws {
  let host = try makeEnabledHost()
  let keyPair = MobileDeviceKeyPair()
  let link = try host.createPairingLink(endpoint: "loopback://clair/subscriptions")
  let credential = try host.pair(
    link: link,
    displayName: "Multi-connection viewer",
    devicePublicKey: keyPair.publicKeyRepresentation
  )
  let descriptor = session(worktreeID: nil, title: "Shared shell")
  try host.registerSession(descriptor, epoch: 1)

  let firstConnectionID = UUID()
  let firstChallenge = try host.issueChallenge(for: credential.deviceID)
  _ = try host.authenticate(
    deviceID: credential.deviceID,
    token: credential.token,
    challenge: firstChallenge,
    signature: try keyPair.sign(firstChallenge.bytes),
    connectionID: firstConnectionID
  )
  let secondConnectionID = UUID()
  let secondChallenge = try host.issueChallenge(for: credential.deviceID)
  _ = try host.authenticate(
    deviceID: credential.deviceID,
    token: credential.token,
    challenge: secondChallenge,
    signature: try keyPair.sign(secondChallenge.bytes),
    connectionID: secondConnectionID
  )

  let first = try host.subscribe(
    deviceID: credential.deviceID,
    sessionID: descriptor.id,
    epoch: 1,
    cursor: 0,
    connectionID: firstConnectionID
  )
  let second = try host.subscribe(
    deviceID: credential.deviceID,
    sessionID: descriptor.id,
    epoch: 1,
    cursor: 0,
    connectionID: secondConnectionID
  )
  host.closeConnection(firstConnectionID)
  try host.publishOutput(sessionID: descriptor.id, epoch: 1, data: Data("still-live".utf8))

  #expect(throws: MobileHostError.invalidOperation) {
    try host.poll(subscriptionID: first.subscriptionID)
  }
  #expect(try host.poll(subscriptionID: second.subscriptionID).count == 1)
}

private func makeEnabledHost() throws -> MobileControlHost {
  let host = try MobileControlHost(
    identity: MobileHostIdentity(
      hostID: UUID(),
      fingerprint: "sha256:test-\(UUID().uuidString)"
    )
  )
  _ = try host.setEnabled(true)
  return host
}

private func temporaryHostStoreURL() -> URL {
  URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("clair-mobile-host-\(UUID().uuidString).json")
}

private final class MobileOperationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var terminalInputs: [MobileAcceptedInput] = []
  private(set) var agentInputs: [MobileAcceptedAgentInput] = []
  private(set) var agentControls: [MobileAcceptedAgentControl] = []
  private(set) var launches: [MobileAcceptedAgentLaunch] = []

  func recordTerminal(_ operation: MobileAcceptedInput) {
    lock.withLock {
      terminalInputs.append(operation)
    }
  }

  func recordAgentInput(_ operation: MobileAcceptedAgentInput) {
    lock.withLock {
      agentInputs.append(operation)
    }
  }

  func recordAgentControl(_ operation: MobileAcceptedAgentControl) {
    lock.withLock {
      agentControls.append(operation)
    }
  }

  func recordLaunch(_ operation: MobileAcceptedAgentLaunch) {
    lock.withLock {
      launches.append(operation)
    }
  }
}

extension NSLock {
  fileprivate func withLock(_ body: () -> Void) {
    lock()
    defer { unlock() }
    body()
  }
}

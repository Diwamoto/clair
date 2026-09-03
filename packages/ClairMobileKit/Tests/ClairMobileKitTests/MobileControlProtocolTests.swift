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

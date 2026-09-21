import Foundation
import Testing

@testable import ClairShared
@testable import ClairTransport

private final class H03TestClock: ClairTransportClock, @unchecked Sendable {
  private let lock = NSLock()
  private var instant: Date

  init(_ instant: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
    self.instant = instant
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return instant
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    instant = instant.addingTimeInterval(interval)
    lock.unlock()
  }
}

private struct H03Payload: Codable, Sendable, Equatable {
  let value: String
}

private struct H03Fixture {
  let project: ProjectID
  let otherProject: ProjectID
  let worktree: WorktreeID
  let otherWorktree: WorktreeID
  let session: SessionID
  let otherSession: SessionID
  let projectScope: ResourceScope
  let worktreeScope: ResourceScope
  let sessionScope: ResourceScope
  let projectSessionScope: ResourceScope
  let authority: ClairPairingAuthority
  let clock: H03TestClock

  static func make(
    defaultVisibleScopes: [ResourceScope]? = nil,
    tokenLifetime: TimeInterval = 30 * 24 * 60 * 60
  ) throws -> Self {
    let project = try ProjectID("project-a")
    let otherProject = try ProjectID("project-b")
    let worktree = try WorktreeID("worktree-a")
    let otherWorktree = try WorktreeID("worktree-b")
    let session = try SessionID("session-a")
    let otherSession = try SessionID("session-b")
    let projectScope = try ResourceScope(projectID: project)
    let worktreeScope = try ResourceScope(projectID: project, worktreeID: worktree)
    let sessionScope = try ResourceScope(
      projectID: project,
      worktreeID: worktree,
      sessionID: session
    )
    let projectSessionScope = try ResourceScope(
      projectID: project,
      sessionID: session
    )
    let clock = H03TestClock()
    let authority = try ClairPairingAuthority(
      hostID: try ClairHostID("host-a"),
      endpoint: try ClairTransportEndpoint("wss://mac.example.test/mobile"),
      defaultVisibleScopes: defaultVisibleScopes ?? [projectScope],
      challengeLifetime: 10,
      tokenLifetime: tokenLifetime,
      clock: clock
    )
    return Self(
      project: project,
      otherProject: otherProject,
      worktree: worktree,
      otherWorktree: otherWorktree,
      session: session,
      otherSession: otherSession,
      projectScope: projectScope,
      worktreeScope: worktreeScope,
      sessionScope: sessionScope,
      projectSessionScope: projectSessionScope,
      authority: authority,
      clock: clock
    )
  }
}

private func pairClient(
  _ fixture: H03Fixture,
  deviceKey: ClairDeviceKey = ClairDeviceKey()
) async throws -> (
  client: ClairNativeClientTransport,
  link: ClairPairingLink,
  result: ClairPairingResult,
  connection: ClairAuthenticatedConnection
) {
  let client = ClairNativeClientTransport(deviceKey: deviceKey)
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  let result = try await client.pair(
    using: link,
    with: fixture.authority,
    displayName: "Test iPhone",
    confirmHostFingerprint: true
  )
  let presentation = await fixture.authority.presentation()
  let connection = try await client.reconnect(
    to: presentation,
    using: fixture.authority
  )
  return (client, link, result, connection)
}

private func operation(
  id: String,
  scope: ResourceScope,
  kind: OperationKind = .terminalInput,
  capability: Capability = .writeTerminal,
  value: String = "safe-test-payload"
) throws -> OperationRequest<H03Payload> {
  OperationRequest(
    operationID: try OperationID(id),
    scope: scope,
    kind: kind,
    capability: capability,
    payload: H03Payload(value: value)
  )
}

private func expectTransportError(
  _ expected: ClairTransportError,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected transport error \(expected), but the operation succeeded.")
  } catch let error as ClairTransportError {
    #expect(error == expected)
  } catch {
    Issue.record("Expected \(expected), received \(error.localizedDescription).")
  }
}

private func expectProtocolError(
  _ expected: ProtocolError,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected protocol error \(expected), but the operation succeeded.")
  } catch let error as ProtocolError {
    #expect(error == expected)
  } catch {
    Issue.record("Expected \(expected), received \(error.localizedDescription).")
  }
}

@Test
func h03PairingReturnsAViewOnlyGrantAndRedactsSecretDescriptions() async throws {
  let fixture = try H03Fixture.make()
  let key = ClairDeviceKey()
  let paired = try await pairClient(fixture, deviceKey: key)

  #expect(paired.result.credential.grant.capabilities.contains(.view))
  #expect(paired.result.credential.grant.capabilities.values.count == 1)
  #expect(paired.result.credential.grant.devicePublicKey == key.publicKey)
  #expect(paired.result.credential.grant.visibleScopes == [fixture.projectScope])
  #expect(paired.result.credential.grant.generation == 1)
  #expect(!paired.result.credential.grant.isRevoked)
  #expect(
    paired.result.credential.grant.tokenExpiresAt
      > paired.result.credential.grant.createdAt
  )
  #expect(paired.result.credential.token.rawRepresentation.count == 32)

  let linkDescription = String(describing: paired.link)
  let credentialDescription = String(describing: paired.result.credential)
  #expect(
    !linkDescription.contains(paired.link.bootstrapSecret.rawRepresentation.base64EncodedString())
  )
  #expect(
    !credentialDescription.contains(
      paired.result.credential.token.rawRepresentation.base64EncodedString())
  )
  #expect(!linkDescription.contains(key.rawRepresentation.base64EncodedString()))
  #expect(paired.result.host.fingerprint == paired.link.hostFingerprint)
  let connectionIsActive = await fixture.authority.isConnectionActive(paired.connection)
  #expect(connectionIsActive)
}

@Test
func h03DefaultDenyRejectsUnpairedEmptyScopeAndEmptyCapability() async throws {
  let emptyScopeFixture = try H03Fixture.make(defaultVisibleScopes: [])
  let emptyScopePaired = try await pairClient(emptyScopeFixture)
  await expectProtocolError(.scopeDenied) {
    try await emptyScopeFixture.authority.authorizeRead(
      scope: emptyScopeFixture.projectScope,
      on: emptyScopePaired.connection
    )
  }

  let fixture = try H03Fixture.make()
  let paired = try await pairClient(fixture)
  let emptyCapabilities = try CapabilitySet([])
  _ = try await fixture.authority.updateGrant(
    deviceID: paired.result.credential.grant.deviceID,
    capabilities: emptyCapabilities,
    visibleScopes: [fixture.projectScope]
  )
  let reconnectPresentation = await fixture.authority.presentation()
  let reconnected = try await paired.client.reconnect(
    to: reconnectPresentation,
    using: fixture.authority
  )
  await expectProtocolError(.capabilityDenied(.view)) {
    try await fixture.authority.authorizeRead(
      scope: fixture.projectScope,
      on: reconnected
    )
  }
}

@Test
func h03PairingAndChallengeExpireAtTheExactBoundary() async throws {
  let fixture = try H03Fixture.make()
  let link = try await fixture.authority.issuePairingLink(lifetime: 5)
  fixture.clock.advance(by: 4.999)
  let key = ClairDeviceKey()
  let request = ClairPairingRequest(
    link: link,
    devicePublicKey: key.publicKey,
    displayName: "Boundary device",
    confirmedHostFingerprint: true
  )
  let result = try await fixture.authority.pair(request)

  let reconnectRequest = ClairReconnectRequest(
    hostID: result.host.hostID,
    hostFingerprint: result.host.fingerprint,
    deviceID: result.credential.grant.deviceID,
    token: result.credential.token
  )
  let challenge = try await fixture.authority.beginAuthentication(reconnectRequest)
  let proof = try challenge.makeProof(using: key)
  fixture.clock.advance(by: 10)
  await expectTransportError(.challengeExpired) {
    _ = try await fixture.authority.authenticate(proof)
  }
}

@Test
func h03ExpiredPairingNeverCreatesAGrant() async throws {
  let fixture = try H03Fixture.make()
  let link = try await fixture.authority.issuePairingLink(lifetime: 5)
  fixture.clock.advance(by: 5)
  let request = ClairPairingRequest(
    link: link,
    devicePublicKey: ClairDeviceKey().publicKey,
    displayName: "Expired device",
    confirmedHostFingerprint: true
  )
  await expectTransportError(.pairingExpired) {
    _ = try await fixture.authority.pair(request)
  }
  let grants = await fixture.authority.allGrants()
  #expect(grants.isEmpty)
}

@Test
func h03PairingLinksAreOneTimeAndRegenerationPreservesExistingGrants() async throws {
  let fixture = try H03Fixture.make()
  let firstLink = try await fixture.authority.issuePairingLink(lifetime: 60)
  let secondLink = try await fixture.authority.issuePairingLink(lifetime: 60)
  let key = ClairDeviceKey()
  let firstRequest = ClairPairingRequest(
    link: firstLink,
    devicePublicKey: key.publicKey,
    displayName: "First device",
    confirmedHostFingerprint: true
  )
  await expectTransportError(.pairingUnavailable) {
    _ = try await fixture.authority.pair(firstRequest)
  }

  let secondRequest = ClairPairingRequest(
    link: secondLink,
    devicePublicKey: key.publicKey,
    displayName: "First device",
    confirmedHostFingerprint: true
  )
  let result = try await fixture.authority.pair(secondRequest)
  await expectTransportError(.pairingConsumed) {
    _ = try await fixture.authority.pair(secondRequest)
  }

  _ = try await fixture.authority.issuePairingLink(lifetime: 60)
  let reconnectRequest = ClairReconnectRequest(
    hostID: result.host.hostID,
    hostFingerprint: result.host.fingerprint,
    deviceID: result.credential.grant.deviceID,
    token: result.credential.token
  )
  let challenge = try await fixture.authority.beginAuthentication(reconnectRequest)
  let proof = try challenge.makeProof(using: key)
  _ = try await fixture.authority.authenticate(proof)
  let grantIsRevoked = await fixture.authority.grant(
    for: result.credential.grant.deviceID
  )?.isRevoked
  #expect(grantIsRevoked == false)
}

@Test
func h03ChallengeProofsAreBoundToTheDeviceAndCannotBeReplayed() async throws {
  let fixture = try H03Fixture.make()
  let deviceKey = ClairDeviceKey()
  let attackerKey = ClairDeviceKey()
  let paired = try await pairClient(fixture, deviceKey: deviceKey)
  let reconnectRequest = ClairReconnectRequest(
    hostID: paired.link.hostID,
    hostFingerprint: paired.link.hostFingerprint,
    deviceID: paired.result.credential.grant.deviceID,
    token: paired.result.credential.token
  )
  let challenge = try await fixture.authority.beginAuthentication(reconnectRequest)
  let stolenTokenProof = try challenge.makeProof(using: attackerKey)
  await expectTransportError(.authenticationFailed) {
    _ = try await fixture.authority.authenticate(stolenTokenProof)
  }
  let validAfterFailedProof = try challenge.makeProof(using: deviceKey)
  await expectTransportError(.challengeConsumed) {
    _ = try await fixture.authority.authenticate(validAfterFailedProof)
  }

  let secondChallenge = try await fixture.authority.beginAuthentication(reconnectRequest)
  let validProof = try secondChallenge.makeProof(using: deviceKey)
  _ = try await fixture.authority.authenticate(validProof)
  await expectTransportError(.challengeConsumed) {
    _ = try await fixture.authority.authenticate(validProof)
  }
  let wrongTokenRequest = ClairReconnectRequest(
    hostID: paired.link.hostID,
    hostFingerprint: paired.link.hostFingerprint,
    deviceID: paired.result.credential.grant.deviceID,
    token: .random()
  )
  await expectTransportError(.authenticationFailed) {
    _ = try await fixture.authority.beginAuthentication(wrongTokenRequest)
  }
}

@Test
func h03ClientPinsHostIdentityButAllowsEndpointChange() async throws {
  let fixture = try H03Fixture.make()
  let paired = try await pairClient(fixture)
  await paired.client.disconnect(from: fixture.authority)

  let newEndpoint = try ClairTransportEndpoint("wss://tailnet.example.test/mobile")
  let sameHostPresentation = await fixture.authority.presentation(endpoint: newEndpoint)
  let reconnected = try await paired.client.reconnect(
    to: sameHostPresentation,
    using: fixture.authority
  )
  let connectionIsActive = await fixture.authority.isConnectionActive(reconnected)
  #expect(connectionIsActive)
  let currentEndpoint = await paired.client.currentEndpoint
  #expect(currentEndpoint == newEndpoint)

  let otherAuthority = try ClairPairingAuthority(
    hostID: try ClairHostID("host-a"),
    endpoint: try ClairTransportEndpoint("wss://impostor.example.test/mobile"),
    defaultVisibleScopes: [fixture.projectScope],
    clock: H03TestClock()
  )
  let impostorPresentation = await otherAuthority.presentation()
  await expectTransportError(.hostIdentityMismatch) {
    _ = try await paired.client.reconnect(
      to: impostorPresentation,
      using: otherAuthority
    )
  }

  let differentHost = try ClairPairingAuthority(
    hostID: try ClairHostID("host-b"),
    endpoint: try ClairTransportEndpoint("wss://other.example.test/mobile"),
    defaultVisibleScopes: [fixture.projectScope],
    clock: H03TestClock()
  )
  let differentHostPresentation = await differentHost.presentation()
  await expectTransportError(.hostIdentityMismatch) {
    _ = try await paired.client.reconnect(
      to: differentHostPresentation,
      using: differentHost
    )
  }
}

@Test
func h03ScopeAndCapabilityAuthorizationRejectConfusedDeputies() async throws {
  let fixture = try H03Fixture.make()
  let paired = try await pairClient(fixture)

  try await fixture.authority.authorizeRead(
    scope: fixture.sessionScope,
    on: paired.connection
  )
  let wrongProjectScope = try ResourceScope(projectID: fixture.otherProject)
  await expectProtocolError(.scopeDenied) {
    try await fixture.authority.authorizeRead(
      scope: wrongProjectScope,
      on: paired.connection
    )
  }

  let viewOperation = try operation(
    id: "view-cannot-write",
    scope: fixture.sessionScope,
    capability: .writeTerminal
  )
  await expectProtocolError(.capabilityDenied(.writeTerminal)) {
    _ = try await fixture.authority.authorize(viewOperation, on: paired.connection)
  }
  let mismatchedOperation = try operation(
    id: "declared-view",
    scope: fixture.sessionScope,
    capability: .view
  )
  await expectProtocolError(.capabilityMismatch(expected: .writeTerminal, actual: .view)) {
    _ = try await fixture.authority.authorize(mismatchedOperation, on: paired.connection)
  }
  let unknownKind = try OperationKind("future.operation")
  let unknownOperation = try operation(
    id: "unknown-kind",
    scope: fixture.sessionScope,
    kind: unknownKind,
    capability: .view
  )
  await expectProtocolError(.unknownOperationKind(unknownKind)) {
    _ = try await fixture.authority.authorize(unknownOperation, on: paired.connection)
  }

  _ = try await fixture.authority.updateGrant(
    deviceID: paired.result.credential.grant.deviceID,
    capabilities: try CapabilitySet([.view, .writeTerminal]),
    visibleScopes: [fixture.sessionScope]
  )
  let presentation = await fixture.authority.presentation()
  let reconnected = try await paired.client.reconnect(
    to: presentation,
    using: fixture.authority
  )
  let exactOperation = try operation(id: "allowed-input", scope: fixture.sessionScope)
  let receipt = try await fixture.authority.authorize(exactOperation, on: reconnected)
  #expect(receipt.disposition == .accepted)
  let duplicate = try await fixture.authority.authorize(exactOperation, on: reconnected)
  #expect(duplicate.disposition == .duplicate)
  let conflicting = try operation(
    id: "allowed-input",
    scope: fixture.sessionScope,
    value: "different"
  )
  await expectProtocolError(.operationIDReuse(try OperationID("allowed-input"))) {
    _ = try await fixture.authority.authorize(conflicting, on: reconnected)
  }
}

@Test
func h03SessionScopeContainmentRemainsExactForOptionalWorktrees() async throws {
  let fixture = try H03Fixture.make(defaultVisibleScopes: [
    try ResourceScope(
      projectID: ProjectID("project-a"),
      worktreeID: WorktreeID("worktree-a"),
      sessionID: SessionID("session-a")
    )
  ])
  let paired = try await pairClient(fixture)
  try await fixture.authority.authorizeRead(
    scope: fixture.sessionScope,
    on: paired.connection
  )

  await expectProtocolError(.scopeDenied) {
    try await fixture.authority.authorizeRead(
      scope: fixture.projectSessionScope,
      on: paired.connection
    )
  }
  let otherWorktreeScope = try ResourceScope(
    projectID: fixture.project,
    worktreeID: fixture.otherWorktree,
    sessionID: fixture.session
  )
  await expectProtocolError(.scopeDenied) {
    try await fixture.authority.authorizeRead(
      scope: otherWorktreeScope,
      on: paired.connection
    )
  }
  let otherSessionScope = try ResourceScope(
    projectID: fixture.project,
    worktreeID: fixture.worktree,
    sessionID: fixture.otherSession
  )
  await expectProtocolError(.scopeDenied) {
    try await fixture.authority.authorizeRead(
      scope: otherSessionScope,
      on: paired.connection
    )
  }
}

@Test
func h03RevokeClosesActiveConnectionsAndInvalidatesChallengesAndTokens() async throws {
  let fixture = try H03Fixture.make()
  let key = ClairDeviceKey()
  let paired = try await pairClient(fixture, deviceKey: key)
  let reconnectRequest = ClairReconnectRequest(
    hostID: paired.link.hostID,
    hostFingerprint: paired.link.hostFingerprint,
    deviceID: paired.result.credential.grant.deviceID,
    token: paired.result.credential.token
  )
  let pendingChallenge = try await fixture.authority.beginAuthentication(reconnectRequest)
  let pendingProof = try pendingChallenge.makeProof(using: key)

  let revocation = try await fixture.authority.revoke(
    deviceID: paired.result.credential.grant.deviceID
  )
  #expect(revocation.previousGeneration == 1)
  #expect(revocation.newGeneration == 2)
  #expect(revocation.closedConnectionIDs == [paired.connection.connectionID])
  let connectionIsActive = await fixture.authority.isConnectionActive(paired.connection)
  #expect(!connectionIsActive)
  let grantIsRevoked = await fixture.authority.grant(
    for: paired.result.credential.grant.deviceID
  )?.isRevoked
  #expect(grantIsRevoked == true)

  await expectTransportError(.connectionClosed) {
    try await paired.client.authorizeRead(
      scope: fixture.projectScope,
      using: fixture.authority
    )
  }
  await expectTransportError(.challengeConsumed) {
    _ = try await fixture.authority.authenticate(pendingProof)
  }
  await expectTransportError(.deviceRevoked) {
    _ = try await fixture.authority.beginAuthentication(reconnectRequest)
  }
  await expectTransportError(.deviceRevoked) {
    let presentation = await fixture.authority.presentation()
    _ = try await paired.client.reconnect(
      to: presentation,
      using: fixture.authority
    )
  }
}

@Test
func h03ConcurrentAuthorizeAndRevokeHasNoPostRevokeAuthorization() async throws {
  let fixture = try H03Fixture.make()
  let paired = try await pairClient(fixture)
  let candidate = try operation(
    id: "race-operation",
    scope: fixture.projectScope
  )
  let authorizationTask = Task { () -> Bool in
    do {
      _ = try await fixture.authority.authorize(candidate, on: paired.connection)
      return true
    } catch {
      return false
    }
  }
  let revokeTask = Task { () -> Bool in
    do {
      _ = try await fixture.authority.revoke(
        deviceID: paired.result.credential.grant.deviceID
      )
      return true
    } catch {
      return false
    }
  }
  let revokeSucceeded = await revokeTask.value
  #expect(revokeSucceeded)
  _ = await authorizationTask.value

  let afterRevoke = try operation(
    id: "after-revoke",
    scope: fixture.projectScope
  )
  await expectTransportError(.connectionClosed) {
    _ = try await fixture.authority.authorize(afterRevoke, on: paired.connection)
  }
}

@Test
func h03MalformedCredentialsAndTransportFramesFailClosedWithoutSecretEcho() throws {
  #expect(throws: ClairTransportError.invalidIdentifier) {
    _ = try ClairHostID("")
  }
  #expect(throws: ClairTransportError.invalidEndpoint) {
    _ = try ClairTransportEndpoint("wss://host.example.test/?bootstrap=secret")
  }
  #expect(throws: ClairTransportError.invalidFingerprint) {
    _ = try ClairHostFingerprint(String(repeating: "A", count: 64))
  }
  #expect(throws: ClairTransportError.invalidSecret) {
    _ = try ClairBootstrapSecret(rawRepresentation: Data(repeating: 1, count: 31))
  }
  #expect(throws: ClairTransportError.invalidToken) {
    _ = try ClairDeviceToken(rawRepresentation: Data(repeating: 1, count: 31))
  }
  #expect(throws: ClairTransportError.invalidDeviceKey) {
    _ = try ClairDeviceKey(rawRepresentation: Data(repeating: 1, count: 31))
  }
  #expect(throws: ClairTransportError.invalidSignature) {
    _ = try ClairChallengeProof(
      challengeID: try ClairChallengeID("challenge"),
      connectionID: try ClairConnectionID("connection"),
      hostID: try ClairHostID("host"),
      deviceID: try ClairDeviceID("device"),
      generation: 1,
      signature: Data(repeating: 0, count: 63)
    )
  }

  let oversizedPayload = H03Payload(value: String(repeating: "x", count: 65 * 1024))
  do {
    _ = try ClairNativeTransportCodec.encodeFrame(oversizedPayload)
    Issue.record("The native codec unexpectedly accepted an oversized frame.")
  } catch let error as ClairTransportError {
    guard case .protocolFailure(.frameTooLarge) = error else {
      Issue.record("The native codec returned the wrong error: \(error.localizedDescription).")
      return
    }
  }
  let error = ClairTransportError.authenticationFailed
  #expect(!error.localizedDescription.contains("0x78"))
  #expect(!error.localizedDescription.contains("safe-test-payload"))
}

@Test
func h03TransportDecodingRevalidatesUntrustedSecurityFields() async throws {
  let invalidSecretJSON = Data(
    "{\"bytes\":\"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\"}".utf8
  )
  #expect(throws: ClairTransportError.invalidSecret) {
    _ = try JSONDecoder().decode(ClairBootstrapSecret.self, from: invalidSecretJSON)
  }
  let oversizedSecretJSON = Data(
    "{\"bytes\":\"\(Data(repeating: 0, count: 33).base64EncodedString())\"}".utf8
  )
  #expect(throws: ClairTransportError.invalidSecret) {
    _ = try JSONDecoder().decode(ClairBootstrapSecret.self, from: oversizedSecretJSON)
  }

  let invalidKeyJSON = Data(
    "{\"rawRepresentation\":\"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\"}".utf8
  )
  #expect(throws: ClairTransportError.invalidDeviceKey) {
    _ = try JSONDecoder().decode(ClairDevicePublicKey.self, from: invalidKeyJSON)
  }

  let fixture = try H03Fixture.make()
  let presentation = await fixture.authority.presentation()
  var presentationObject = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(presentation)
    ) as? [String: Any]
  )
  presentationObject["fingerprint"] = String(repeating: "f", count: 64)
  let mismatchedPresentation = try JSONSerialization.data(
    withJSONObject: presentationObject
  )
  #expect(throws: ClairTransportError.hostIdentityMismatch) {
    _ = try JSONDecoder().decode(
      ClairHostPresentation.self,
      from: mismatchedPresentation
    )
  }

  let key = ClairDeviceKey()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  let result = try await fixture.authority.pair(
    ClairPairingRequest(
      link: link,
      devicePublicKey: key.publicKey,
      displayName: "Decode test device",
      confirmedHostFingerprint: true
    )
  )
  var grantObject = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(result.credential.grant)
    ) as? [String: Any]
  )
  grantObject["generation"] = 0
  let invalidGrant = try JSONSerialization.data(withJSONObject: grantObject)
  #expect(throws: ClairTransportError.invalidGrant) {
    _ = try JSONDecoder().decode(ClairDeviceGrant.self, from: invalidGrant)
  }

  let reconnectRequest = ClairReconnectRequest(
    hostID: result.host.hostID,
    hostFingerprint: result.host.fingerprint,
    deviceID: result.credential.grant.deviceID,
    token: result.credential.token
  )
  let challenge = try await fixture.authority.beginAuthentication(reconnectRequest)
  var challengeObject = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(challenge)
    ) as? [String: Any]
  )
  challengeObject["nonce"] = Data(repeating: 0, count: 31).base64EncodedString()
  let invalidChallenge = try JSONSerialization.data(withJSONObject: challengeObject)
  #expect(throws: ClairTransportError.invalidChallenge) {
    _ = try JSONDecoder().decode(ClairChallenge.self, from: invalidChallenge)
  }
  let proof = try challenge.makeProof(using: key)
  #expect(String(describing: proof).contains("signature: <redacted>"))
  #expect(!String(describing: proof).contains(proof.signature.base64EncodedString()))
}

@Test
func h03PendingAuthenticationStateIsBoundedAndExpiredEntriesAreReclaimed() async throws {
  let fixture = try H03Fixture.make()
  let paired = try await pairClient(fixture)
  let request = ClairReconnectRequest(
    hostID: paired.link.hostID,
    hostFingerprint: paired.link.hostFingerprint,
    deviceID: paired.result.credential.grant.deviceID,
    token: paired.result.credential.token
  )

  for _ in 0..<ClairTransportValidation.maximumPendingChallengesPerDevice {
    _ = try await fixture.authority.beginAuthentication(request)
  }
  await expectTransportError(.challengeLimitReached) {
    _ = try await fixture.authority.beginAuthentication(request)
  }

  fixture.clock.advance(by: 10)
  _ = try await fixture.authority.beginAuthentication(request)
}

@Test
func h03NativeCodecUsesBoundedB03Frames() throws {
  let request = ClairReconnectRequest(
    hostID: try ClairHostID("host"),
    hostFingerprint: try ClairHostFingerprint(String(repeating: "a", count: 64)),
    deviceID: try ClairDeviceID("device"),
    token: .random()
  )
  let frame = try ClairNativeTransportCodec.encodeFrame(request)
  let decoded = try ClairNativeTransportCodec.decodeFrame(
    ClairReconnectRequest.self,
    from: frame
  )
  #expect(decoded == request)
}

@Test
func h03TimestampConversionRejectsExtremeFiniteDatesWithoutProcessFatal() throws {
  let extreme = Date(timeIntervalSince1970: Double.greatestFiniteMagnitude)
  #expect(throws: ClairTransportError.invalidTimestamp) {
    _ = try ClairTransportValidation.timestampMilliseconds(extreme)
  }
  #expect(throws: ClairTransportError.invalidTimestamp) {
    _ = try ClairTransportValidation.timestampMilliseconds(
      Date(timeIntervalSince1970: Double.infinity)
    )
  }
  #expect(throws: ClairTransportError.invalidTimestamp) {
    _ = try ClairTransportValidation.timestampMilliseconds(
      Date(timeIntervalSince1970: Double.nan)
    )
  }
  #expect(throws: ClairTransportError.invalidTimestamp) {
    _ = try ClairTransportValidation.timestampMilliseconds(
      Date(timeIntervalSince1970: -1)
    )
  }
  #expect(throws: ClairTransportError.invalidTimestamp) {
    _ = try ClairTransportValidation.timestampMilliseconds(
      Date(timeIntervalSince1970: Double(Int64.max) / 1_000)
    )
  }

  let negotiated = try NegotiatedProtocol(
    version: .current,
    maximumFramePayloadBytes: FrameLimits.defaultMaximumPayloadBytes,
    capabilities: .empty
  )
  #expect(throws: ClairTransportError.invalidTimestamp) {
    _ = try ClairChallenge(
      challengeID: try ClairChallengeID("extreme-challenge"),
      connectionID: try ClairConnectionID("extreme-connection"),
      hostID: try ClairHostID("host"),
      hostFingerprint: try ClairHostFingerprint(String(repeating: "a", count: 64)),
      deviceID: try ClairDeviceID("device"),
      generation: 1,
      nonce: Data(repeating: 0, count: ClairTransportValidation.secretBytes),
      expiresAt: extreme,
      negotiatedProtocol: negotiated
    )
  }
}

@Test
func h03PendingChallengesAreQuotaBoundPerDeviceAndInvalidProofConsumesSlot() async throws {
  let fixture = try H03Fixture.make()
  let deviceKey = ClairDeviceKey()
  let attackerKey = ClairDeviceKey()
  let paired = try await pairClient(fixture, deviceKey: deviceKey)
  let request = ClairReconnectRequest(
    hostID: paired.link.hostID,
    hostFingerprint: paired.link.hostFingerprint,
    deviceID: paired.result.credential.grant.deviceID,
    token: paired.result.credential.token
  )

  var firstChallengeValue: ClairChallenge?
  for index in 0..<ClairTransportValidation.maximumPendingChallengesPerDevice {
    let challenge = try await fixture.authority.beginAuthentication(request)
    if index == 0 {
      firstChallengeValue = challenge
    }
  }
  await expectTransportError(.challengeLimitReached) {
    _ = try await fixture.authority.beginAuthentication(request)
  }

  let firstChallenge = try #require(firstChallengeValue)
  let invalidProof = try firstChallenge.makeProof(using: attackerKey)
  await expectTransportError(.authenticationFailed) {
    _ = try await fixture.authority.authenticate(invalidProof)
  }
  _ = try await fixture.authority.beginAuthentication(request)

  let secondKey = ClairDeviceKey()
  let secondClient = ClairNativeClientTransport(deviceKey: secondKey)
  let secondLink = try await fixture.authority.issuePairingLink(lifetime: 60)
  let secondResult = try await secondClient.pair(
    using: secondLink,
    with: fixture.authority,
    displayName: "Second device",
    confirmHostFingerprint: true
  )
  let secondRequest = ClairReconnectRequest(
    hostID: secondResult.host.hostID,
    hostFingerprint: secondResult.host.fingerprint,
    deviceID: secondResult.credential.grant.deviceID,
    token: secondResult.credential.token
  )
  let secondChallenge = try await fixture.authority.beginAuthentication(secondRequest)
  let secondConnection = try await fixture.authority.authenticate(
    try secondChallenge.makeProof(using: secondKey)
  )
  let secondConnectionIsActive = await fixture.authority.isConnectionActive(secondConnection)
  #expect(secondConnectionIsActive)
}

@Test
func h03CredentialExpiryIsEnforcedAtAuthorizeBeginAndReconnectBoundaries() async throws {
  let fixture = try H03Fixture.make(tokenLifetime: 5)
  let paired = try await pairClient(fixture)
  fixture.clock.advance(by: 5)

  let connectedBeforeExpiryObservation = await paired.client.isConnected
  #expect(connectedBeforeExpiryObservation)
  await expectTransportError(.credentialExpired) {
    try await paired.client.authorizeRead(
      scope: fixture.projectScope,
      using: fixture.authority
    )
  }
  let connectionIsActiveAfterExpiry = await fixture.authority.isConnectionActive(paired.connection)
  #expect(!connectionIsActiveAfterExpiry)
  let clientIsConnectedAfterExpiry = await paired.client.isConnected
  #expect(!clientIsConnectedAfterExpiry)

  let request = ClairReconnectRequest(
    hostID: paired.link.hostID,
    hostFingerprint: paired.link.hostFingerprint,
    deviceID: paired.result.credential.grant.deviceID,
    token: paired.result.credential.token
  )
  await expectTransportError(.credentialExpired) {
    _ = try await fixture.authority.beginAuthentication(request)
  }
  let presentation = await fixture.authority.presentation()
  await expectTransportError(.credentialExpired) {
    _ = try await paired.client.reconnect(
      to: presentation,
      using: fixture.authority
    )
  }
  let refreshed = await paired.client.refreshConnectionState(using: fixture.authority)
  #expect(!refreshed)
}

@Test
func h03CredentialExpiryIsEnforcedWhenAChallengeCrossesTheBoundary() async throws {
  let fixture = try H03Fixture.make(tokenLifetime: 5)
  let deviceKey = ClairDeviceKey()
  let paired = try await pairClient(fixture, deviceKey: deviceKey)
  await paired.client.disconnect(from: fixture.authority)
  let request = ClairReconnectRequest(
    hostID: paired.link.hostID,
    hostFingerprint: paired.link.hostFingerprint,
    deviceID: paired.result.credential.grant.deviceID,
    token: paired.result.credential.token
  )
  let challenge = try await fixture.authority.beginAuthentication(request)
  fixture.clock.advance(by: 5)
  await expectTransportError(.credentialExpired) {
    _ = try await fixture.authority.authenticate(try challenge.makeProof(using: deviceKey))
  }
}

@Test
func h03SelectedScopeIsBoundToChallengeProofAndConnectionAuthorization() async throws {
  let fixture = try H03Fixture.make()
  let deviceKey = ClairDeviceKey()
  let paired = try await pairClient(fixture, deviceKey: deviceKey)
  await paired.client.disconnect(from: fixture.authority)
  let presentation = await fixture.authority.presentation()
  let scopedConnection = try await paired.client.reconnect(
    to: presentation,
    using: fixture.authority,
    resourceScope: fixture.sessionScope
  )
  try await fixture.authority.authorizeRead(
    scope: fixture.sessionScope,
    on: scopedConnection
  )
  await expectTransportError(.protocolFailure(.scopeDenied)) {
    try await fixture.authority.authorizeRead(
      scope: fixture.projectScope,
      on: scopedConnection
    )
  }
  await expectTransportError(.protocolFailure(.scopeDenied)) {
    try await fixture.authority.authorizeRead(
      scope: fixture.worktreeScope,
      on: scopedConnection
    )
  }

  await paired.client.disconnect(from: fixture.authority)
  let request = ClairReconnectRequest(
    hostID: paired.link.hostID,
    hostFingerprint: paired.link.hostFingerprint,
    deviceID: paired.result.credential.grant.deviceID,
    token: paired.result.credential.token,
    resourceScope: fixture.sessionScope
  )
  let challenge = try await fixture.authority.beginAuthentication(request)
  let proof = try challenge.makeProof(using: deviceKey)
  let tamperedProof = try ClairChallengeProof(
    challengeID: proof.challengeID,
    connectionID: proof.connectionID,
    hostID: proof.hostID,
    deviceID: proof.deviceID,
    generation: proof.generation,
    signature: proof.signature,
    resourceScope: nil
  )
  await expectTransportError(.challengeMismatch) {
    _ = try await fixture.authority.authenticate(tamperedProof)
  }
}

@Test
func h03ReconnectReplacesThePreviousConnectionWithoutLeakingAvailability() async throws {
  let fixture = try H03Fixture.make()
  let paired = try await pairClient(fixture)
  let presentation = await fixture.authority.presentation()
  var previous = paired.connection
  for _ in 0..<8 {
    let current = try await paired.client.reconnect(
      to: presentation,
      using: fixture.authority
    )
    let previousIsActive = await fixture.authority.isConnectionActive(previous)
    let currentIsActive = await fixture.authority.isConnectionActive(current)
    #expect(!previousIsActive)
    #expect(currentIsActive)
    previous = current
  }
}

@Test
func h03ConnectionWireDTOCannotForgeAClosableLiveHandle() async throws {
  let fixture = try H03Fixture.make()
  let paired = try await pairClient(fixture)
  let wireInfo = try JSONEncoder().encode(paired.connection.info)
  let decodedInfo = try JSONDecoder().decode(ClairConnectionInfo.self, from: wireInfo)
  #expect(decodedInfo == paired.connection.info)

  let forged = ClairAuthenticatedConnection(info: decodedInfo)
  #expect(forged != paired.connection)
  await fixture.authority.close(forged)
  let originalIsActive = await fixture.authority.isConnectionActive(paired.connection)
  #expect(originalIsActive)
  await expectTransportError(.connectionClosed) {
    try await fixture.authority.authorizeRead(
      scope: fixture.projectScope,
      on: forged
    )
  }
}

@Test
func h03AuthorizationTicketProvidesGenerationCheckedH06DispatchBoundary() async throws {
  let fixture = try H03Fixture.make()
  let paired = try await pairClient(fixture)
  _ = try await fixture.authority.updateGrant(
    deviceID: paired.result.credential.grant.deviceID,
    capabilities: try CapabilitySet([.view, .writeTerminal]),
    visibleScopes: [fixture.projectScope]
  )
  let presentation = await fixture.authority.presentation()
  let connection = try await paired.client.reconnect(
    to: presentation,
    using: fixture.authority
  )
  let candidate = try operation(id: "dispatch-ticket", scope: fixture.projectScope)
  let ticket = try await fixture.authority.authorizeForDispatch(candidate, on: connection)
  #expect(ticket.receipt.operationID == candidate.operationID)
  let validated = try await fixture.authority.validateDispatch(ticket, on: connection)
  #expect(validated == ticket.receipt)

  _ = try await fixture.authority.revoke(
    deviceID: paired.result.credential.grant.deviceID
  )
  await expectTransportError(.connectionClosed) {
    _ = try await fixture.authority.validateDispatch(ticket, on: connection)
  }
}

@Test
func h03WireDTOsBoundNestedProtocolAndCapabilityArrays() async throws {
  let fixture = try H03Fixture.make()
  let presentation = await fixture.authority.presentation()
  var presentationObject = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(presentation)
    ) as? [String: Any]
  )
  var offerObject = try #require(presentationObject["protocolOffer"] as? [String: Any])
  let validRange: [String: Any] = [
    "major": 1,
    "minimum_minor": 0,
    "maximum_minor": 0,
  ]
  offerObject["version_ranges"] = Array(
    repeating: validRange,
    count: ClairTransportValidation.maximumProtocolVersionRanges + 1
  )
  presentationObject["protocolOffer"] = offerObject
  let oversizedRanges = try JSONSerialization.data(withJSONObject: presentationObject)
  #expect(throws: ClairTransportError.invalidProtocolOffer) {
    _ = try JSONDecoder().decode(ClairHostPresentation.self, from: oversizedRanges)
  }

  offerObject["version_ranges"] = [validRange]
  offerObject["capabilities"] = Array(
    repeating: "view",
    count: ClairTransportValidation.maximumCapabilities + 1
  )
  presentationObject["protocolOffer"] = offerObject
  let oversizedCapabilities = try JSONSerialization.data(withJSONObject: presentationObject)
  #expect(throws: ClairTransportError.invalidProtocolOffer) {
    _ = try JSONDecoder().decode(ClairHostPresentation.self, from: oversizedCapabilities)
  }

  let deviceKey = ClairDeviceKey()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  let result = try await fixture.authority.pair(
    ClairPairingRequest(
      link: link,
      devicePublicKey: deviceKey.publicKey,
      displayName: "Bound decode device",
      confirmedHostFingerprint: true
    )
  )
  var grantObject = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(result.credential.grant)
    ) as? [String: Any]
  )
  let scopeObject = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(fixture.projectScope)
    ) as? [String: Any]
  )
  grantObject["visibleScopes"] = Array(
    repeating: scopeObject,
    count: ClairTransportValidation.maximumVisibleScopes + 1
  )
  let oversizedScopes = try JSONSerialization.data(withJSONObject: grantObject)
  #expect(throws: ClairTransportError.invalidGrant) {
    _ = try JSONDecoder().decode(ClairDeviceGrant.self, from: oversizedScopes)
  }
}

@Test
func h03ClientRefreshesStaleStateAfterExternalRevocation() async throws {
  let fixture = try H03Fixture.make()
  let paired = try await pairClient(fixture)
  _ = try await fixture.authority.revoke(
    deviceID: paired.result.credential.grant.deviceID
  )
  let clientStillReportsConnected = await paired.client.isConnected
  #expect(clientStillReportsConnected)
  let refreshed = await paired.client.refreshConnectionState(using: fixture.authority)
  #expect(!refreshed)
  let clientIsConnectedAfterRefresh = await paired.client.isConnected
  #expect(!clientIsConnectedAfterRefresh)
}

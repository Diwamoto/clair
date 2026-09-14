import ClairV2MobileKit
import ClairV2Shared
import ClairV2Transport
import Foundation
import Testing

private struct N02Fixture {
  let authority: ClairPairingAuthority
  let transport: ClairInProcessMobileTransport
  let store: ClairInMemoryDeviceIdentityStore
  let projectScope: ResourceScope
  let deviceKey: ClairDeviceKey

  static func make(
    protocolOffer: ProtocolOffer = .current,
    deviceKey: ClairDeviceKey? = nil
  ) throws -> Self {
    let projectID = try ProjectID("n02-project")
    let projectScope = try ResourceScope(projectID: projectID)
    let authority = try ClairPairingAuthority(
      hostID: try ClairHostID("n02-host"),
      endpoint: try ClairTransportEndpoint("wss://n02.example.test/mobile"),
      protocolOffer: protocolOffer,
      defaultVisibleScopes: [projectScope]
    )
    let deviceKey = try deviceKey ?? Self.deterministicKey()
    let store = ClairInMemoryDeviceIdentityStore(deviceKey: deviceKey)
    let transport = ClairInProcessMobileTransport(authority: authority)
    return Self(
      authority: authority,
      transport: transport,
      store: store,
      projectScope: projectScope,
      deviceKey: deviceKey
    )
  }

  static func deterministicKey() throws -> ClairDeviceKey {
    var raw = Data(repeating: 0, count: 31)
    raw.append(1)
    return try ClairDeviceKey(rawRepresentation: raw)
  }

  func makeClient(
    clientOffer: ProtocolOffer = .current,
    requiredCapabilities: CapabilitySet? = nil
  ) throws -> ClairV2MobileClient {
    try ClairV2MobileClient(
      store: store,
      transport: transport,
      clientOffer: clientOffer,
      requiredCapabilities: requiredCapabilities
    )
  }
}

private func expectClientError(
  _ expected: ClairMobileClientError,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected client error \(expected), but the operation succeeded.")
  } catch let error as ClairMobileClientError {
    #expect(error == expected)
  } catch {
    Issue.record("Expected \(expected), received \(error.localizedDescription).")
  }
}

private actor AuthenticationGate {
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    released = true
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func isWaiting() -> Bool {
    !waiters.isEmpty
  }
}

private actor GatedMobileTransport: ClairV2MobileTransport {
  private let base: ClairInProcessMobileTransport
  private let gate: AuthenticationGate?
  private var authenticationCount = 0

  init(base: ClairInProcessMobileTransport, gate: AuthenticationGate? = nil) {
    self.base = base
    self.gate = gate
  }

  func presentation() async throws -> ClairHostPresentation {
    try await base.presentation()
  }

  func pair(_ request: ClairPairingRequest) async throws -> ClairPairingResult {
    try await base.pair(request)
  }

  func beginAuthentication(_ request: ClairReconnectRequest) async throws -> ClairChallenge {
    try await base.beginAuthentication(request)
  }

  func authenticate(_ proof: ClairChallengeProof) async throws -> ClairAuthenticatedConnection {
    authenticationCount += 1
    await gate?.wait()
    return try await base.authenticate(proof)
  }

  func authorizeRead(
    scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    try await base.authorizeRead(scope: scope, on: connection)
  }

  func isConnectionActive(_ connection: ClairAuthenticatedConnection) async -> Bool {
    await base.isConnectionActive(connection)
  }

  func close(_ connection: ClairAuthenticatedConnection) async {
    await base.close(connection)
  }

  func authenticationCalls() -> Int {
    authenticationCount
  }
}

@Test
func n02PairingPersistsOpaqueIdentityAndReconnectsAfterClientRestart() async throws {
  let fixture = try N02Fixture.make()
  let client = try fixture.makeClient()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)

  let paired = try await client.pair(
    using: link,
    displayName: "N02 test device",
    confirmHostFingerprint: true
  )
  #expect(await client.state == .disconnected)
  #expect(paired.hostID == link.hostID)
  #expect(paired.hostFingerprint == link.hostFingerprint)

  let persisted = try #require(await fixture.store.load())
  #expect(persisted.credential.grant.deviceID == paired.deviceID)
  #expect(persisted.hostIdentity.fingerprint == paired.hostFingerprint)

  let restartedClient = try fixture.makeClient()
  let reconnected = try await restartedClient.reconnect()
  #expect(reconnected == paired)
  #expect(await restartedClient.state == .authenticated(reconnected))

  let tokenText = persisted.credential.token.rawRepresentation.base64EncodedString()
  let keyText = fixture.deviceKey.rawRepresentation.base64EncodedString()
  let stateText = String(reflecting: await restartedClient.state)
  #expect(!String(describing: persisted).contains(tokenText))
  #expect(!String(describing: persisted).contains(keyText))
  #expect(!stateText.contains(tokenText))
  #expect(!stateText.contains(keyText))
  #expect(String(describing: persisted).contains("<redacted>"))
}

@Test
func n03PairingPresentationDistinguishesExpiredLinksAndFingerprintChanges() async throws {
  let fixture = try N02Fixture.make()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  let ready = ClairMobilePairingPresentation(
    link: link,
    now: Date(timeIntervalSince1970: 0)
  )
  #expect(ready.state == .ready)

  let expired = ClairMobilePairingPresentation(
    link: link,
    now: link.expiresAt.addingTimeInterval(1)
  )
  #expect(expired.state == .expired)

  let changedHost = try ClairPairingAuthority(
    hostID: try ClairHostID("n03-other-host"),
    endpoint: try ClairTransportEndpoint("wss://other.example.test/mobile")
  )
  let changed = ready.validating(presentation: await changedHost.presentation())
  #expect(changed.state == .fingerprintChanged)
}

@Test
func n03HostManagementKeepsScopeAndMarksRevokedWithoutCredentialMaterial() async throws {
  let fixture = try N02Fixture.make()
  let client = try fixture.makeClient()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  _ = try await client.pair(using: link, displayName: "N03 device", confirmHostFingerprint: true)
  let identity = try #require(await fixture.store.load())

  var management = ClairMobileHostManagementState()
  management.update(identity: identity, clientState: .disconnected)
  let host = try #require(management.hosts.first)
  #expect(host.scopes == identity.credential.grant.visibleScopes)
  #expect(
    !String(reflecting: management).contains(
      identity.credential.token.rawRepresentation.base64EncodedString()))

  management.markRevoked(hostID: host.id)
  #expect(management.hosts.first?.connection == .revoked)
}

@Test
func n02StoredIdentityRoundTripsAndRequiresExplicitKeyRotation() async throws {
  let fixture = try N02Fixture.make()
  let client = try fixture.makeClient()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  _ = try await client.pair(
    using: link,
    displayName: "Persistence test device",
    confirmHostFingerprint: true
  )
  let persisted = try #require(await fixture.store.load())
  let encoded = try JSONEncoder().encode(persisted)
  let decoded = try JSONDecoder().decode(ClairStoredDeviceIdentity.self, from: encoded)
  #expect(decoded == persisted)

  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(persisted)) as? [String: Any]
  )
  object["deviceKeyRepresentation"] = Data(repeating: 0, count: 32).base64EncodedString()
  let rotatedRecord = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: ClairDeviceIdentityStoreError.keyRotationRequired) {
    _ = try JSONDecoder().decode(ClairStoredDeviceIdentity.self, from: rotatedRecord)
  }
}

@Test
func n02HostPinSurvivesEndpointChangeButRejectsChangedIdentity() async throws {
  let fixture = try N02Fixture.make()
  let client = try fixture.makeClient()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  _ = try await client.pair(
    using: link,
    displayName: "Endpoint test device",
    confirmHostFingerprint: true
  )

  let changedEndpoint = try ClairTransportEndpoint("wss://tailnet.example.test/mobile")
  await fixture.transport.setPresentation(
    await fixture.authority.presentation(endpoint: changedEndpoint)
  )
  let reconnected = try await client.reconnect()
  #expect(reconnected.endpoint == changedEndpoint)
  let persistedAfterEndpointChange = try #require(await fixture.store.load())
  #expect(persistedAfterEndpointChange.endpoint == changedEndpoint)

  await client.disconnect()
  let impostor = try ClairPairingAuthority(
    hostID: try ClairHostID("n02-host"),
    endpoint: try ClairTransportEndpoint("wss://impostor.example.test/mobile"),
    defaultVisibleScopes: [fixture.projectScope]
  )
  await fixture.transport.setPresentation(await impostor.presentation())
  await expectClientError(.hostIdentityMismatch) {
    _ = try await client.reconnect()
  }
  let persistedAfterMismatch = try #require(await fixture.store.load())
  #expect(persistedAfterMismatch.endpoint == changedEndpoint)
}

@Test
func n02CertificatePinSurvivesRestartAndRejectsChangedCertificate() async throws {
  let fixture = try N02Fixture.make()
  let certificate = try ClairCertificateFingerprint(String(repeating: "a", count: 64))
  let wrongCertificate = try ClairCertificateFingerprint(String(repeating: "b", count: 64))
  await fixture.transport.setCertificateFingerprint(certificate)
  let client = try fixture.makeClient()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)

  await expectClientError(.hostIdentityMismatch) {
    _ = try await client.pair(
      using: link,
      displayName: "Certificate pin device",
      confirmHostFingerprint: true,
      certificateFingerprint: wrongCertificate
    )
  }
  #expect(await fixture.authority.allGrants().isEmpty)

  let paired = try await client.pair(
    using: link,
    displayName: "Certificate pin device",
    confirmHostFingerprint: true,
    certificateFingerprint: certificate
  )
  #expect(paired.certificateFingerprint == certificate)
  let persisted = try #require(await fixture.store.load())
  #expect(persisted.certificateFingerprint == certificate)

  _ = try await client.reconnect()
  await client.disconnect()
  await fixture.transport.setCertificateFingerprint(wrongCertificate)
  await expectClientError(.hostIdentityMismatch) {
    _ = try await client.reconnect()
  }
  #expect(await client.state == .failed(.hostIdentityMismatch))
  #expect(try #require(await fixture.store.load()).certificateFingerprint == certificate)
}

@Test
func n02NegotiationAndFingerprintConfirmationFailClosedBeforeGrantCreation() async throws {
  let viewOnlyOffer = try ProtocolOffer(
    versionRanges: [try ProtocolVersionRange(major: 1, minor: 0)],
    capabilities: try CapabilitySet([.view])
  )
  let fixture = try N02Fixture.make(protocolOffer: viewOnlyOffer)
  let client = try fixture.makeClient(
    requiredCapabilities: try CapabilitySet([.writeTerminal])
  )
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)

  await expectClientError(.capabilityNegotiationFailed) {
    _ = try await client.pair(
      using: link,
      displayName: "Capability test device",
      confirmHostFingerprint: true
    )
  }
  #expect(await fixture.authority.allGrants().isEmpty)

  let confirmationFixture = try N02Fixture.make()
  let confirmationClient = try confirmationFixture.makeClient()
  let confirmationLink = try await confirmationFixture.authority.issuePairingLink(lifetime: 60)
  await expectClientError(.userConfirmationRequired) {
    _ = try await confirmationClient.pair(
      using: confirmationLink,
      displayName: "Unconfirmed device",
      confirmHostFingerprint: false
    )
  }
  #expect(await confirmationFixture.authority.allGrants().isEmpty)
}

@Test
func n02OneTimePairingReplayIsTypedAndRedacted() async throws {
  let fixture = try N02Fixture.make()
  let client = try fixture.makeClient()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  _ = try await client.pair(
    using: link,
    displayName: "Replay test device",
    confirmHostFingerprint: true
  )

  await expectClientError(.pairingReplayRejected) {
    _ = try await client.pair(
      using: link,
      displayName: "Replay test device",
      confirmHostFingerprint: true
    )
  }
  #expect(await fixture.authority.allGrants().count == 1)
  #expect(String(describing: await client.state).contains("pairingReplayRejected"))
}

@Test
func n02ConcurrentDisconnectCancelsHandshakeAndClosesLateConnection() async throws {
  let fixture = try N02Fixture.make()
  let gate = AuthenticationGate()
  let transport = GatedMobileTransport(base: fixture.transport, gate: gate)
  let client = try ClairV2MobileClient(
    store: fixture.store,
    transport: transport
  )
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  _ = try await client.pair(
    using: link,
    displayName: "Race test device",
    confirmHostFingerprint: true
  )

  let reconnectTask = Task {
    try await client.reconnect()
  }
  var authenticationCalls = 0
  for _ in 0..<100 {
    authenticationCalls = await transport.authenticationCalls()
    if authenticationCalls > 0 { break }
    try? await Task.sleep(for: .milliseconds(1))
  }
  #expect(authenticationCalls == 1)

  await client.disconnect()
  await expectClientError(.operationInProgress) {
    _ = try await client.reconnect()
  }
  await gate.release()
  await expectClientError(.cancelled) {
    _ = try await reconnectTask.value
  }
  #expect(await client.state == .disconnected)
  #expect(await fixture.authority.allGrants().count == 1)

  _ = try await client.reconnect()
  #expect(await client.state != .disconnected)
  await client.disconnect()
}

@Test
func n02ReconnectIsIdempotentWhenTheAuthenticatedHandleIsStillLive() async throws {
  let fixture = try N02Fixture.make()
  let gate = AuthenticationGate()
  await gate.release()
  let transport = GatedMobileTransport(base: fixture.transport, gate: gate)
  let client = try ClairV2MobileClient(store: fixture.store, transport: transport)
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  let paired = try await client.pair(
    using: link,
    displayName: "Idempotency test device",
    confirmHostFingerprint: true
  )

  let first = try await client.reconnect()
  let second = try await client.reconnect()
  #expect(first == paired)
  #expect(second == first)
  #expect(await transport.authenticationCalls() == 1)
}

@Test
func n02ProtectedStoreErrorsAndSecureEnclaveBoundaryAreExplicit() async throws {
  let fixture = try N02Fixture.make()
  await fixture.store.setInjectedError(.locked)
  let client = try fixture.makeClient()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)

  await expectClientError(.credentialStore(.locked)) {
    _ = try await client.pair(
      using: link,
      displayName: "Locked-store device",
      confirmHostFingerprint: true
    )
  }
  #expect(await client.state == .failed(.credentialStore(.locked)))

  await fixture.store.setInjectedError(nil)
  _ = try await client.pair(
    using: link,
    displayName: "Locked-store device",
    confirmHostFingerprint: true
  )
  #expect(await client.state == .disconnected)

  let secureEnclaveStore = ClairSecureEnclaveDeviceIdentityStore()
  do {
    _ = try await secureEnclaveStore.createDeviceKey()
    Issue.record("Expected the explicit Secure Enclave boundary to reject the current signer seam.")
  } catch let error as ClairDeviceIdentityStoreError {
    #expect(error == .unsupportedProtection)
  }
}

@Test
func n02UnknownExpiredAndRevokedCredentialsFailClosed() async throws {
  let fixture = try N02Fixture.make()
  let pairingClient = try fixture.makeClient()
  let link = try await fixture.authority.issuePairingLink(lifetime: 60)
  _ = try await pairingClient.pair(
    using: link,
    displayName: "Credential boundary device",
    confirmHostFingerprint: true
  )
  let persisted = try #require(await fixture.store.load())

  let unknownGrant = try ClairDeviceGrant(
    hostID: persisted.credential.grant.hostID,
    deviceID: try ClairDeviceID("unknown-device"),
    devicePublicKey: persisted.credential.grant.devicePublicKey,
    displayName: persisted.credential.grant.displayName,
    generation: persisted.credential.grant.generation,
    capabilities: persisted.credential.grant.capabilities,
    visibleScopes: persisted.credential.grant.visibleScopes,
    createdAt: persisted.credential.grant.createdAt,
    tokenExpiresAt: persisted.credential.grant.tokenExpiresAt
  )
  try await fixture.store.save(
    ClairStoredDeviceIdentity(
      deviceKey: try persisted.makeDeviceKey(),
      credential: ClairDeviceCredential(grant: unknownGrant, token: persisted.credential.token),
      hostIdentity: persisted.hostIdentity,
      endpoint: persisted.endpoint,
      negotiatedProtocol: persisted.negotiatedProtocol,
      certificateFingerprint: persisted.certificateFingerprint
    )
  )
  let unknownClient = try fixture.makeClient()
  await expectClientError(.authenticationFailed) {
    _ = try await unknownClient.reconnect()
  }

  let expiredFixture = try N02Fixture.make()
  let expiredClient = try expiredFixture.makeClient()
  let expiredLink = try await expiredFixture.authority.issuePairingLink(lifetime: 60)
  _ = try await expiredClient.pair(
    using: expiredLink,
    displayName: "Expired credential device",
    confirmHostFingerprint: true
  )
  let expired = try #require(await expiredFixture.store.load())
  let expiredGrant = try ClairDeviceGrant(
    hostID: expired.credential.grant.hostID,
    deviceID: expired.credential.grant.deviceID,
    devicePublicKey: expired.credential.grant.devicePublicKey,
    displayName: expired.credential.grant.displayName,
    generation: expired.credential.grant.generation,
    capabilities: expired.credential.grant.capabilities,
    visibleScopes: expired.credential.grant.visibleScopes,
    createdAt: Date(timeIntervalSince1970: 1),
    tokenExpiresAt: Date(timeIntervalSince1970: 2)
  )
  try await expiredFixture.store.save(
    ClairStoredDeviceIdentity(
      deviceKey: try expired.makeDeviceKey(),
      credential: ClairDeviceCredential(grant: expiredGrant, token: expired.credential.token),
      hostIdentity: expired.hostIdentity,
      endpoint: expired.endpoint,
      negotiatedProtocol: expired.negotiatedProtocol,
      certificateFingerprint: expired.certificateFingerprint
    )
  )
  let expiredRestart = try expiredFixture.makeClient()
  await expectClientError(.credentialExpired) {
    _ = try await expiredRestart.reconnect()
  }

  let revokedFixture = try N02Fixture.make()
  let revokedClient = try revokedFixture.makeClient()
  let revokedLink = try await revokedFixture.authority.issuePairingLink(lifetime: 60)
  _ = try await revokedClient.pair(
    using: revokedLink,
    displayName: "Revoked credential device",
    confirmHostFingerprint: true
  )
  let revoked = try #require(await revokedFixture.store.load())
  let revokedGrant = try ClairDeviceGrant(
    hostID: revoked.credential.grant.hostID,
    deviceID: revoked.credential.grant.deviceID,
    devicePublicKey: revoked.credential.grant.devicePublicKey,
    displayName: revoked.credential.grant.displayName,
    generation: revoked.credential.grant.generation,
    capabilities: revoked.credential.grant.capabilities,
    visibleScopes: revoked.credential.grant.visibleScopes,
    createdAt: revoked.credential.grant.createdAt,
    tokenExpiresAt: revoked.credential.grant.tokenExpiresAt,
    revokedAt: Date()
  )
  try await revokedFixture.store.save(
    ClairStoredDeviceIdentity(
      deviceKey: try revoked.makeDeviceKey(),
      credential: ClairDeviceCredential(grant: revokedGrant, token: revoked.credential.token),
      hostIdentity: revoked.hostIdentity,
      endpoint: revoked.endpoint,
      negotiatedProtocol: revoked.negotiatedProtocol,
      certificateFingerprint: revoked.certificateFingerprint
    )
  )
  let revokedRestart = try revokedFixture.makeClient()
  await expectClientError(.deviceRevoked) {
    _ = try await revokedRestart.reconnect()
  }
}

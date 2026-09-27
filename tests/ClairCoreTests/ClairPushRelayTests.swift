import Foundation
import Testing

@testable import ClairPushRelay
@testable import ClairAgent
@testable import ClairDaemonKit
@testable import ClairPush
@testable import ClairShared
@testable import ClairTransport

private enum H09TestError: Error {
  case missingPushEvent
  case providerFailure
}

private final class H09TestClock: ClairPushClock, ClairTransportClock, @unchecked Sendable {
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

private final class H09RelaySpy: ClairPushSending, @unchecked Sendable {
  private let lock = NSLock()
  private var storedDeliveries: [ClairPushDelivery] = []
  var result: ClairPushProviderStatus = .accepted
  var error: Error?

  func send(_ delivery: ClairPushDelivery) throws -> ClairPushDeliveryResult {
    lock.lock()
    defer { lock.unlock() }
    storedDeliveries.append(delivery)
    if let error { throw error }
    return ClairPushDeliveryResult(status: result)
  }

  var deliveries: [ClairPushDelivery] {
    lock.lock()
    defer { lock.unlock() }
    return storedDeliveries
  }
}

private final class H09ProviderSpy: ClairPushProvider, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var submissionCount = 0
  var result: ClairPushProviderStatus = .accepted
  var error: Error?

  func submit(
    _ delivery: ClairPushDelivery, at _: UInt64
  ) throws -> ClairPushProviderStatus {
    lock.lock()
    defer { lock.unlock() }
    submissionCount += 1
    if let error { throw error }
    return result
  }
}

private final class H09APNsTransportSpy: ClairAPNsTransport, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requestCount = 0
  private(set) var credentialGenerations: [UInt64] = []
  var result: ClairPushProviderStatus = .accepted
  var error: Error?

  func submit(
    _: ClairAPNsRequest, credential: ClairAPNsCredential
  ) throws -> ClairPushProviderStatus {
    lock.lock()
    defer { lock.unlock() }
    requestCount += 1
    credentialGenerations.append(credential.generation)
    if let error { throw error }
    return result
  }
}

private struct H09Fixture {
  let project: ProjectID
  let otherProject: ProjectID
  let session: SessionID
  let otherSession: SessionID
  let projectScope: ResourceScope
  let sessionScope: ResourceScope
  let otherSessionScope: ResourceScope
  let authority: ClairPairingAuthority
  let connection: ClairAuthenticatedConnection
  let host: ClairHostIdentity
  let clock: H09TestClock
  let token: ClairPushDeviceToken
  let deviceID: ClairDeviceID

  static func make() async throws -> Self {
    let project = try ProjectID("project-h09")
    let otherProject = try ProjectID("other-project-h09")
    let session = try SessionID("session-h09")
    let otherSession = try SessionID("other-session-h09")
    let projectScope = try ResourceScope(projectID: project)
    let sessionScope = try ResourceScope(projectID: project, sessionID: session)
    let otherSessionScope = try ResourceScope(
      projectID: otherProject, sessionID: otherSession
    )
    let clock = H09TestClock()
    let authority = try ClairPairingAuthority(
      hostID: try ClairHostID("host-h09"),
      endpoint: try ClairTransportEndpoint("wss://h09.example.test/mobile"),
      defaultVisibleScopes: [projectScope],
      challengeLifetime: 10,
      tokenLifetime: 3_600,
      clock: clock
    )
    let client = ClairNativeClientTransport()
    let link = try await authority.issuePairingLink(lifetime: 60)
    let result = try await client.pair(
      using: link,
      with: authority,
      displayName: "H09 Test iPhone",
      confirmHostFingerprint: true
    )
    let presentation = await authority.presentation()
    let connection = try await client.reconnect(to: presentation, using: authority)
    let host = await authority.hostIdentity
    let token = try ClairPushDeviceToken(Data([1, 2, 3, 4]))
    return Self(
      project: project,
      otherProject: otherProject,
      session: session,
      otherSession: otherSession,
      projectScope: projectScope,
      sessionScope: sessionScope,
      otherSessionScope: otherSessionScope,
      authority: authority,
      connection: connection,
      host: host,
      clock: clock,
      token: token,
      deviceID: result.credential.grant.deviceID
    )
  }

  func normalizedEvent(
    id: String = "event-h09",
    scope: ResourceScope? = nil,
    payload: ClairAgentEventPayload = .attention(
      ClairAgentAttentionEvent(kind: .approval, requestID: "opaque-request")
    )
  ) throws -> ClairAgentNormalizedEvent {
    try ClairAgentNormalizedEvent(
      eventID: try EventID(id),
      kind: try EventKind("agent.\(payload.kind.rawValue)"),
      scope: scope ?? sessionScope,
      epoch: try SessionEpoch(1),
      revision: Revision(1),
      payload: payload
    )
  }

  func pushEvent(
    id: String = "event-h09",
    scope: ResourceScope? = nil,
    payload: ClairAgentEventPayload = .attention(
      ClairAgentAttentionEvent(kind: .approval, requestID: "opaque-request")
    ),
    ttl: UInt64 = 60
  ) throws -> ClairDaemonPushEvent {
    guard
      let event = try ClairDaemonPushEvent(
        normalized: normalizedEvent(id: id, scope: scope, payload: payload),
        host: host,
        issuedAt: try ClairPushBounds.timestamp(clock.now()),
        ttl: ttl
      )
    else {
      throw H09TestError.missingPushEvent
    }
    return event
  }
}

private func h09Delivery(
  clock: H09TestClock,
  wake: UUID = UUID(),
  kind: ClairPushEventKind = .attention,
  ttl: UInt64 = 60
) throws -> ClairPushDelivery {
  let now = try ClairPushBounds.timestamp(clock.now())
  let event = try ClairPushEvent(
    host: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
    resource: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
    wake: wake,
    kind: kind,
    epoch: 1,
    revision: 1,
    issuedAt: now,
    ttl: ttl
  )
  return try ClairPushDelivery(
    device: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
    environment: .sandbox,
    generation: 1,
    token: try ClairPushDeviceToken(Data([9, 8, 7])),
    event: event
  )
}

private func h09Credential(
  environment: ClairPushEnvironment,
  generation: UInt64,
  expiresAt: UInt64
) throws -> ClairAPNsCredential {
  try ClairAPNsCredential(
    environment: environment,
    generation: generation,
    expiresAt: expiresAt,
    keyID: "ABC1234567",
    teamID: "TEAM123456",
    privateKey: Data(repeating: 0x42, count: 32)
  )
}

private func h09ExpectPushError(
  _ expected: ClairPushError,
  operation: () async throws -> Void
) async {
  do {
    try await operation()
    Issue.record("Expected push error \(expected), but the operation succeeded.")
  } catch let error as ClairPushError {
    #expect(error == expected)
  } catch {
    Issue.record("Expected \(expected), received \(error.localizedDescription).")
  }
}

@Test
func h09PushEventProjectionDropsConversationAndPreservesOnlyOpaqueReferences() async throws {
  let fixture = try await H09Fixture.make()
  let conversation = try fixture.normalizedEvent(
    payload: .conversation(ClairAgentConversationEvent(role: .assistant, text: "private text"))
  )
  #expect(
    try ClairDaemonPushEvent(
      normalized: conversation, host: fixture.host, issuedAt: 1_800_000_000
    ) == nil
  )

  let push = try fixture.pushEvent()
  #expect(push.scope == fixture.sessionScope)
  #expect(push.event.kind == .attention)
  #expect(push.event.epoch == 1)
  #expect(push.event.revision == 1)
  let encoded = try push.event.encoded()
  #expect(!String(decoding: encoded, as: UTF8.self).contains("opaque-request"))
}

@Test
func h09PushEventDecoderIsStrictAndBounded() throws {
  let clock = H09TestClock()
  let delivery = try h09Delivery(clock: clock)
  let encoded = try delivery.event.encoded()
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object["extra"] = "reject"
  let unknownField = try JSONSerialization.data(withJSONObject: object)
  #expect(throws: ClairPushError.invalidInput) {
    try ClairPushEvent.decode(unknownField)
  }
  #expect(throws: ClairPushError.payloadTooLarge) {
    try ClairPushEvent.decode(Data(repeating: 0, count: ClairPushBounds.maximumPayloadBytes + 1))
  }
  #expect(try ClairPushEvent.decode(encoded) == delivery.event)
}

@Test
func h09RelayDeduplicatesAmbiguousFailuresAndRejectsConflictingWake() throws {
  let clock = H09TestClock()
  let provider = H09ProviderSpy()
  provider.error = H09TestError.providerFailure
  let relay = try ClairPushRelay(provider: provider, clock: clock)
  let wake = UUID()
  let delivery = try h09Delivery(clock: clock, wake: wake)
  let first = try relay.send(delivery)
  let duplicate = try relay.send(delivery)
  #expect(first.status == .unavailable)
  #expect(!first.isDuplicate)
  #expect(duplicate.status == .unavailable)
  #expect(duplicate.isDuplicate)
  #expect(provider.submissionCount == 1)

  let conflictingEvent = try ClairPushEvent(
    host: delivery.event.host,
    resource: delivery.event.resource,
    wake: wake,
    kind: .completion,
    epoch: delivery.event.epoch,
    revision: delivery.event.revision + 1,
    issuedAt: delivery.event.issuedAt,
    ttl: 60
  )
  let conflicting = try ClairPushDelivery(
    device: delivery.device,
    environment: delivery.environment,
    generation: delivery.generation,
    token: delivery.token,
    event: conflictingEvent
  )
  #expect(throws: ClairPushError.conflictingDuplicate) {
    try relay.send(conflicting)
  }
}

@Test
func h09RelayHonorsExpiryAndCapacityWithoutEvictingLiveEntries() throws {
  let clock = H09TestClock()
  let provider = H09ProviderSpy()
  let relay = try ClairPushRelay(provider: provider, clock: clock, capacity: 1)
  let first = try h09Delivery(clock: clock, ttl: 10)
  _ = try relay.send(first)
  clock.advance(by: 1)
  let second = try h09Delivery(clock: clock, wake: UUID())
  #expect(throws: ClairPushError.capacityExceeded) {
    try relay.send(second)
  }
  clock.advance(by: 9)
  #expect(throws: ClairPushError.expired) {
    try relay.send(first)
  }
  let third = try h09Delivery(clock: clock, wake: UUID())
  _ = try relay.send(third)
  #expect(provider.submissionCount == 2)
}

@Test
func h09APNsBoundarySeparatesCredentialsByEnvironmentAndGeneration() throws {
  let clock = H09TestClock()
  let now = try ClairPushBounds.timestamp(clock.now())
  let store = ClairInMemoryAPNsCredentialStore()
  let transport = H09APNsTransportSpy()
  let provider = ClairAPNsProvider(store: store, transport: transport)
  try store.rotate(to: h09Credential(environment: .sandbox, generation: 1, expiresAt: now + 100))
  try store.rotate(to: h09Credential(environment: .production, generation: 1, expiresAt: now + 100))

  let sandbox = try h09Delivery(clock: clock)
  _ = try provider.submit(sandbox, at: now)
  let productionEvent = try ClairPushEvent(
    host: sandbox.event.host,
    resource: sandbox.event.resource,
    wake: UUID(),
    kind: .completion,
    epoch: 1,
    revision: 2,
    issuedAt: now,
    ttl: 60
  )
  let production = try ClairPushDelivery(
    device: sandbox.device,
    environment: .production,
    generation: 1,
    token: sandbox.token,
    event: productionEvent
  )
  _ = try provider.submit(production, at: now)
  #expect(transport.requestCount == 2)
  #expect(transport.credentialGenerations == [1, 1])

  try store.rotate(to: h09Credential(environment: .sandbox, generation: 2, expiresAt: now + 100))
  _ = try provider.submit(sandbox, at: now + 1)
  #expect(transport.credentialGenerations == [1, 1, 2])
  try store.revoke(environment: .sandbox, generation: 2)
  #expect(try provider.submit(sandbox, at: now + 2) == .unavailable)
}

@Test
func h09CredentialAndRequestDescriptionsDoNotEchoSecrets() throws {
  let clock = H09TestClock()
  let delivery = try h09Delivery(clock: clock)
  let secret = Data("secret-token".utf8)
  let token = try ClairPushDeviceToken(secret)
  let secretDelivery = try ClairPushDelivery(
    device: delivery.device,
    environment: delivery.environment,
    generation: 1,
    token: token,
    event: delivery.event
  )
  let request = try ClairAPNsRequest(secretDelivery)
  let credential = try h09Credential(
    environment: .sandbox,
    generation: 1,
    expiresAt: 1_800_000_100
  )
  #expect(!String(describing: credential).contains("ABC1234567"))
  #expect(!String(describing: credential).contains("TEAM123456"))
  #expect(!String(describing: request).contains(secret.base64EncodedString()))
  #expect(!String(decoding: request.payload, as: UTF8.self).contains("secret-token"))
}

@Test
func h09RegistryKeepsEqualRetriesIdempotentAndReplacesOnlyWithNewerTokenGeneration() async throws {
  let fixture = try await H09Fixture.make()
  let relay = H09RelaySpy()
  let registry = try ClairDaemonPushRegistry(
    authority: fixture.authority, relay: relay, clock: fixture.clock
  )
  let first = try await registry.register(
    token: fixture.token,
    generation: 1,
    environment: .sandbox,
    scope: fixture.sessionScope,
    ttl: 30,
    on: fixture.connection
  )
  fixture.clock.advance(by: 5)
  let equalRetry = try await registry.register(
    token: fixture.token,
    generation: 1,
    environment: .sandbox,
    scope: fixture.sessionScope,
    ttl: 30,
    on: fixture.connection
  )
  #expect(equalRetry == first)

  let replacementToken = try ClairPushDeviceToken(Data([5, 6, 7, 8]))
  let replacement = try await registry.register(
    token: replacementToken,
    generation: 2,
    environment: .sandbox,
    scope: fixture.sessionScope,
    ttl: 30,
    on: fixture.connection
  )
  #expect(replacement.generation == 2)
  #expect(replacement.expiresAt > first.expiresAt)
  await h09ExpectPushError(.staleGeneration) {
    _ = try await registry.register(
      token: fixture.token,
      generation: 1,
      environment: .sandbox,
      scope: fixture.sessionScope,
      ttl: 30,
      on: fixture.connection
    )
  }
}

@Test
func h09RegistryForwardsOnlyAttentionAndCompletionAndRechecksScope() async throws {
  let fixture = try await H09Fixture.make()
  let relay = H09RelaySpy()
  let registry = try ClairDaemonPushRegistry(
    authority: fixture.authority, relay: relay, clock: fixture.clock
  )
  _ = try await registry.register(
    token: fixture.token,
    generation: 1,
    environment: .sandbox,
    scope: fixture.sessionScope,
    ttl: 30,
    on: fixture.connection
  )
  _ = try await registry.send(
    fixture.pushEvent(id: "attention-h09"),
    to: fixture.deviceID,
    environment: .sandbox
  )
  _ = try await registry.send(
    fixture.pushEvent(
      id: "completion-h09",
      payload: .completion(ClairAgentCompletionEvent(status: .succeeded))
    ),
    to: fixture.deviceID,
    environment: .sandbox
  )
  #expect(relay.deliveries.map(\.event.kind) == [.attention, .completion])

  await h09ExpectPushError(.unauthorized) {
    _ = try await registry.send(
      fixture.pushEvent(id: "other-scope-h09", scope: fixture.otherSessionScope),
      to: fixture.deviceID,
      environment: .sandbox
    )
  }
  let snapshot = try #require(
    await registry.snapshot(device: fixture.deviceID, environment: .sandbox)
  )
  #expect(!snapshot.requiresRegistration)
}

@Test
func h09RegistrySeparatesEnvironmentsAndInvalidProviderResponsesRequireRegistration() async throws {
  let fixture = try await H09Fixture.make()
  let relay = H09RelaySpy()
  let registry = try ClairDaemonPushRegistry(
    authority: fixture.authority, relay: relay, clock: fixture.clock
  )
  for environment in ClairPushEnvironment.allCases {
    _ = try await registry.register(
      token: fixture.token,
      generation: 1,
      environment: environment,
      scope: fixture.sessionScope,
      ttl: 30,
      on: fixture.connection
    )
  }
  relay.result = .invalidToken
  _ = try await registry.send(
    fixture.pushEvent(id: "sandbox-invalid-h09"),
    to: fixture.deviceID,
    environment: .sandbox
  )
  let sandbox = try #require(
    await registry.snapshot(device: fixture.deviceID, environment: .sandbox)
  )
  let production = try #require(
    await registry.snapshot(device: fixture.deviceID, environment: .production)
  )
  #expect(sandbox.requiresRegistration)
  #expect(!production.requiresRegistration)
  _ = try await registry.send(
    fixture.pushEvent(id: "production-ok-h09"),
    to: fixture.deviceID,
    environment: .production
  )
  #expect(relay.deliveries.count == 2)
}

@Test
func h09RegistryRevocationAndExactExpiryFailClosedWhileRetainingTombstone() async throws {
  let fixture = try await H09Fixture.make()
  let relay = H09RelaySpy()
  let registry = try ClairDaemonPushRegistry(
    authority: fixture.authority, relay: relay, clock: fixture.clock
  )
  _ = try await registry.register(
    token: fixture.token,
    generation: 1,
    environment: .sandbox,
    scope: fixture.sessionScope,
    ttl: 10,
    on: fixture.connection
  )
  fixture.clock.advance(by: 10)
  let expired = try #require(
    await registry.snapshot(device: fixture.deviceID, environment: .sandbox)
  )
  #expect(expired.requiresRegistration)
  await h09ExpectPushError(.registrationRequired) {
    _ = try await registry.send(
      fixture.pushEvent(id: "expired-h09"),
      to: fixture.deviceID,
      environment: .sandbox
    )
  }

  let replacementToken = try ClairPushDeviceToken(Data([10, 11, 12]))
  _ = try await registry.register(
    token: replacementToken,
    generation: 2,
    environment: .sandbox,
    scope: fixture.sessionScope,
    ttl: 30,
    on: fixture.connection
  )
  _ = try await registry.revoke(device: fixture.deviceID)
  let revoked = try #require(
    await registry.snapshot(device: fixture.deviceID, environment: .sandbox)
  )
  #expect(revoked.requiresRegistration)
  await h09ExpectPushError(.registrationRequired) {
    _ = try await registry.send(
      fixture.pushEvent(id: "revoked-h09"),
      to: fixture.deviceID,
      environment: .sandbox
    )
  }
}

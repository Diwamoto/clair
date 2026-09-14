import ClairV2Push
import ClairV2Shared
import Foundation
import Testing

@testable import ClairV2MobileKit
@testable import ClairV2Transport

// MARK: - Shared fixtures

/// Builds a `ClairAuthenticatedConnection` directly from H03's internal
/// initializer (available via `@testable import ClairV2Transport`), mirroring
/// N06's `n06Connection()`, so these controller-focused tests do not need a
/// full pairing/reconnect handshake just to have a connection value to pass
/// around.
private func n07Connection(hostID: String = "n07-host") throws -> ClairAuthenticatedConnection {
  ClairAuthenticatedConnection(
    connectionID: try ClairConnectionID("n07-connection"),
    hostID: try ClairHostID(hostID),
    deviceID: try ClairDeviceID("n07-device"),
    generation: 1,
    negotiatedProtocol: try NegotiatedProtocol(
      version: .current,
      maximumFramePayloadBytes: FrameLimits.defaultMaximumPayloadBytes,
      capabilities: .empty
    )
  )
}

private func n07Scope(
  project: String = "n07-project", worktree: String? = nil, session: String = "n07-session"
) throws -> ResourceScope {
  try ResourceScope(
    projectID: ProjectID(project),
    worktreeID: worktree.map { try! WorktreeID($0) },
    sessionID: SessionID(session)
  )
}

private func n07Cursor(
  scope: ResourceScope, epoch: UInt64 = 1, revision: UInt64 = 0
) throws -> ReplayCursor {
  try ReplayCursor(scope: scope, epoch: SessionEpoch(epoch), revision: Revision(revision))
}

private func n07PushEvent(
  epoch: UInt64 = 1, revision: UInt64 = 5, issuedAt: UInt64? = nil, ttl: UInt64 = 60
) throws -> ClairPushEvent {
  let issuedAt = try issuedAt ?? ClairPushBounds.timestamp(Date())
  return try ClairPushEvent(
    host: UUID(), resource: UUID(), wake: UUID(), kind: .attention,
    epoch: epoch, revision: revision, issuedAt: issuedAt, ttl: ttl
  )
}

/// A minimal `ClairV2MobileSessionVerifying` double. It never touches real
/// H08 journal/H03 authorization; it only records what it was asked and
/// returns (or throws) whatever the test configured, isolating the
/// controller's own state-machine logic from any real transport behavior.
private actor N07MockVerifier: ClairV2MobileSessionVerifying {
  private(set) var callCount = 0
  private(set) var lastRequestedScope: ResourceScope?
  private(set) var lastCachedCursor: ReplayCursor??
  var cursorToReturn: ReplayCursor?
  var errorToThrow: Error?

  init(cursorToReturn: ReplayCursor? = nil) {
    self.cursorToReturn = cursorToReturn
  }

  func setCursor(_ cursor: ReplayCursor?) {
    cursorToReturn = cursor
  }

  func setError(_ error: Error?) {
    errorToThrow = error
  }

  func verify(
    scope: ResourceScope,
    cachedCursor: ReplayCursor?,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ReplayCursor {
    callCount += 1
    lastRequestedScope = scope
    lastCachedCursor = cachedCursor
    if let errorToThrow { throw errorToThrow }
    guard let cursorToReturn else {
      throw ClairV2MobileReconnectError.unknownDestination(scope)
    }
    return cursorToReturn
  }
}

private struct N07OpaqueVerifierError: Error, Equatable {}

/// A minimal `ClairV2MobilePushRegistering` double.
private actor N07MockPushRegistry: ClairV2MobilePushRegistering {
  private(set) var registerCallCount = 0
  private(set) var unregisterCallCount = 0
  var snapshotToReturn: ClairV2MobilePushRegistrationSnapshot?
  var errorToThrow: Error?

  func setSnapshot(_ snapshot: ClairV2MobilePushRegistrationSnapshot?) {
    snapshotToReturn = snapshot
  }

  func setError(_ error: Error?) {
    errorToThrow = error
  }

  func register(
    token: ClairPushDeviceToken,
    environment: ClairPushEnvironment,
    scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2MobilePushRegistrationSnapshot {
    registerCallCount += 1
    if let errorToThrow { throw errorToThrow }
    guard let snapshotToReturn else {
      throw ClairMobileTransportBoundaryError.unavailable
    }
    return snapshotToReturn
  }

  func unregister(
    environment: ClairPushEnvironment,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    unregisterCallCount += 1
    if let errorToThrow { throw errorToThrow }
  }
}

// MARK: - Deep link parsing

@Test
func deepLinkParsesAFullyQualifiedSessionURL() throws {
  let url = try #require(
    URL(
      string:
        "clair://open?project=n07-project&worktree=n07-worktree&session=n07-session&host=n07-host")
  )
  let link = try ClairV2MobileDeepLink(url: url)
  #expect(link.scope.projectID.rawValue == "n07-project")
  #expect(link.scope.worktreeID?.rawValue == "n07-worktree")
  #expect(link.scope.sessionID?.rawValue == "n07-session")
  #expect(link.host?.rawValue == "n07-host")
}

@Test
func deepLinkRejectsAWrongScheme() {
  let url = URL(string: "https://open?project=p&session=s")!
  #expect(throws: ClairV2MobileReconnectError.invalidDeepLink) {
    try ClairV2MobileDeepLink(url: url)
  }
}

@Test
func deepLinkRejectsAMissingSession() {
  let url = URL(string: "clair://open?project=p")!
  #expect(throws: ClairV2MobileReconnectError.invalidDeepLink) {
    try ClairV2MobileDeepLink(url: url)
  }
}

@Test
func deepLinkRejectsAProjectOnlyTarget() {
  // N04 already models Project/Worktree browsing without a deep link; a
  // link naming only a Project has no defined destination here.
  let url = URL(string: "clair://open?project=p&worktree=w")!
  #expect(throws: ClairV2MobileReconnectError.invalidDeepLink) {
    try ClairV2MobileDeepLink(url: url)
  }
}

@Test
func deepLinkRejectsAMalformedIdentifier() {
  // A control character is rejected by ProjectID's own validation.
  let url = URL(string: "clair://open?project=p&session=s")!
  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
  components.queryItems = [
    URLQueryItem(name: "project", value: "bad\u{0007}project"),
    URLQueryItem(name: "session", value: "s"),
  ]
  #expect(throws: ClairV2MobileReconnectError.invalidDeepLink) {
    try ClairV2MobileDeepLink(url: components.url!)
  }
}

// MARK: - Required scenario 1: foreground -> background -> foreground, no new events

@Test
func foregroundBackgroundForegroundWithNoNewEventsRestoresExactlyTheSameState() async throws {
  let scope = try n07Scope()
  let cursor = try n07Cursor(scope: scope, epoch: 1, revision: 3)
  let verifier = N07MockVerifier(cursorToReturn: cursor)
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  await controller.attach(connection: try n07Connection())
  await controller.seedCache(cursor)

  let first = await controller.handle(.foregrounded)
  #expect(first == .verified(cursor))

  let afterBackground = await controller.handle(.backgrounded)
  #expect(afterBackground == first)

  let second = await controller.handle(.foregrounded)
  #expect(second == .verified(cursor))
  #expect(second == first)

  // Every foreground independently re-verified with the host rather than
  // trusting the cache silently, even though nothing changed.
  #expect(await verifier.callCount == 2)
}

// MARK: - Required scenario 2: push wake while backgrounded, then foreground

@Test
func pushWakeWhileBackgroundedForcesResyncBeforeForegroundReturns() async throws {
  let scope = try n07Scope()
  let staleCursor = try n07Cursor(scope: scope, epoch: 1, revision: 3)
  let freshCursor = try n07Cursor(scope: scope, epoch: 1, revision: 9)
  let verifier = N07MockVerifier(cursorToReturn: staleCursor)
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  await controller.attach(connection: try n07Connection())
  await controller.seedCache(staleCursor)

  // Establish the stale baseline as "already verified" (e.g. from an earlier
  // foreground session before the app was backgrounded).
  let baseline = await controller.handle(.foregrounded)
  #expect(baseline == .verified(staleCursor))
  _ = await controller.handle(.backgrounded)

  // The host now has newer data than the cache; a push wake arrives while
  // the app is still backgrounded.
  await verifier.setCursor(freshCursor)
  let pushEvent = try n07PushEvent(revision: 9)
  let afterWake = await controller.handle(.pushWake(pushEvent))

  // The resync already happened in the background -- the app never silently
  // trusted the stale cached revision while backgrounded.
  #expect(afterWake == .verified(freshCursor))

  let afterForeground = await controller.handle(.foregrounded)
  #expect(afterForeground == .verified(freshCursor))
  #expect(await verifier.callCount == 3)
}

@Test
func expiredPushEventIsIgnoredWithoutDisturbingCurrentState() async throws {
  let scope = try n07Scope()
  let cursor = try n07Cursor(scope: scope, epoch: 1, revision: 3)
  let verifier = N07MockVerifier(cursorToReturn: cursor)
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  await controller.attach(connection: try n07Connection())
  await controller.seedCache(cursor)
  let verified = await controller.handle(.foregrounded)
  #expect(verified == .verified(cursor))

  // issuedAt far in the past with a short TTL: already expired at "now".
  let stalePush = try n07PushEvent(issuedAt: 1, ttl: 1)
  let afterExpiredWake = await controller.handle(.pushWake(stalePush))

  #expect(afterExpiredWake == verified)
  // No additional verification call was made for the malformed/expired wake.
  #expect(await verifier.callCount == 1)
}

// MARK: - Required scenario 3: relaunch from terminated via a deep link

@Test
func relaunchFromTerminatedViaDeepLinkIndependentlyVerifiesBeforeActing() async throws {
  let scope = try n07Scope()
  let hostConnection = try n07Connection(hostID: "n07-host")
  let hostConfirmedCursor = try n07Cursor(scope: scope, epoch: 2, revision: 7)
  let verifier = N07MockVerifier(cursorToReturn: hostConfirmedCursor)
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  // The reconnect handshake (N02) has already completed by the time the
  // deep link is processed, mirroring how a real launch sequence attaches
  // the connection before routing the launch URL.
  await controller.attach(connection: hostConnection)

  let deepLink = try ClairV2MobileDeepLink(host: try ClairHostID("n07-host"), scope: scope)
  let result = await controller.handle(.launched(deepLink: deepLink))

  // The deep link's own scope was never adopted directly -- the epoch and
  // revision the app ends up trusting come only from the host's answer.
  #expect(result == .verified(hostConfirmedCursor))
  #expect(await verifier.lastRequestedScope == scope)
  // The deep link carries no revision of its own to leak into the request.
  #expect(await verifier.lastCachedCursor == Optional<ReplayCursor?>.some(nil))
}

// MARK: - Required scenario 4: stale/invalid deep link rejected with a typed error

@Test
func deepLinkForAnUnknownOrRevokedSessionIsRejectedWithATypedError() async throws {
  let scope = try n07Scope()
  let verifier = N07MockVerifier(cursorToReturn: nil)
  await verifier.setError(N07OpaqueVerifierError())
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  await controller.attach(connection: try n07Connection())

  let deepLink = try ClairV2MobileDeepLink(scope: scope)
  let result = await controller.handle(.launched(deepLink: deepLink))

  #expect(result == .mustReconnect(scope, .unknownDestination(scope)))
}

@Test
func deepLinkForADifferentHostIsRejectedWithoutContactingTheVerifier() async throws {
  let scope = try n07Scope()
  let verifier = N07MockVerifier(cursorToReturn: try n07Cursor(scope: scope))
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  await controller.attach(connection: try n07Connection(hostID: "n07-host"))

  let deepLink = try ClairV2MobileDeepLink(host: try ClairHostID("some-other-host"), scope: scope)
  let result = await controller.handle(.launched(deepLink: deepLink))

  #expect(result == .mustReconnect(scope, .hostMismatch))
  #expect(await verifier.callCount == 0)
}

@Test
func launchWithoutAConnectionFailsClosedRatherThanTrustingTheDeepLink() async throws {
  let scope = try n07Scope()
  let verifier = N07MockVerifier(cursorToReturn: try n07Cursor(scope: scope))
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  // No `attach(connection:)` call: the reconnect handshake has not
  // completed yet.

  let deepLink = try ClairV2MobileDeepLink(scope: scope)
  let result = await controller.handle(.launched(deepLink: deepLink))

  #expect(result == .mustReconnect(scope, .notPaired))
  #expect(await verifier.callCount == 0)
}

@Test
func launchWithoutADeepLinkOrCacheFailsClosedAsNotPaired() async throws {
  let controller = ClairV2MobileReconnectController()
  let result = await controller.handle(.launched(deepLink: nil))
  #expect(result == .mustReconnect(nil, .notPaired))
}

@Test
func verifierScopeMismatchIsTreatedAsUntrustworthy() async throws {
  let scope = try n07Scope()
  let otherScope = try n07Scope(session: "n07-other-session")
  let verifier = N07MockVerifier(cursorToReturn: try n07Cursor(scope: otherScope))
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  await controller.attach(connection: try n07Connection())
  await controller.seedCache(try n07Cursor(scope: scope))

  let result = await controller.handle(.foregrounded)

  #expect(result == .mustReconnect(scope, .unknownDestination(scope)))
}

// MARK: - Remote notification payload decoding

@Test
func remoteNotificationPayloadDecodesIntoAPushWake() async throws {
  let scope = try n07Scope()
  let cursor = try n07Cursor(scope: scope, epoch: 1, revision: 4)
  let freshCursor = try n07Cursor(scope: scope, epoch: 1, revision: 8)
  let verifier = N07MockVerifier(cursorToReturn: cursor)
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  await controller.attach(connection: try n07Connection())
  await controller.seedCache(cursor)
  _ = await controller.handle(.foregrounded)

  await verifier.setCursor(freshCursor)
  let event = try n07PushEvent()
  let payload = try event.encoded()
  let result = await controller.handleRemoteNotificationPayload(payload)

  #expect(result == .verified(freshCursor))
}

@Test
func malformedRemoteNotificationPayloadIsIgnored() async throws {
  let scope = try n07Scope()
  let cursor = try n07Cursor(scope: scope)
  let verifier = N07MockVerifier(cursorToReturn: cursor)
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  await controller.attach(connection: try n07Connection())
  await controller.seedCache(cursor)
  let verified = await controller.handle(.foregrounded)

  let result = await controller.handleRemoteNotificationPayload(Data("not json".utf8))

  #expect(result == verified)
  #expect(await verifier.callCount == 1)
}

// MARK: - Push registration

@Test
func pushRegistrationSucceedsThroughTheInjectedTransport() async throws {
  let scope = try n07Scope()
  let registry = N07MockPushRegistry()
  let snapshot = ClairV2MobilePushRegistrationSnapshot(
    scope: scope, environment: .sandbox, expiresAt: Date(timeIntervalSince1970: 10_000),
    requiresRegistration: false
  )
  await registry.setSnapshot(snapshot)
  let controller = ClairV2MobileReconnectController(pushRegistry: registry)
  await controller.attach(connection: try n07Connection())

  let result = await controller.registerForPush(
    tokenBytes: Data([0x01, 0x02, 0x03]), environment: .sandbox, scope: scope
  )

  #expect(result == .registered(snapshot))
  #expect(await registry.registerCallCount == 1)
}

@Test
func pushRegistrationFailsClosedWithoutAConnection() async throws {
  let controller = ClairV2MobileReconnectController()
  let result = await controller.registerForPush(
    tokenBytes: Data([0x01]), environment: .sandbox, scope: try n07Scope()
  )
  #expect(result == .failed(.notPaired))
}

@Test
func pushRegistrationReportsTheUnavailableBoundaryExplicitly() async throws {
  let controller = ClairV2MobileReconnectController()
  await controller.attach(connection: try n07Connection())
  let result = await controller.registerForPush(
    tokenBytes: Data([0x01]), environment: .sandbox, scope: try n07Scope()
  )
  #expect(result == .failed(.transportFailed))
}

// MARK: - Pending device token

@Test
func pendingDeviceTokenIsRegisteredOnceAScopeIsKnown() async throws {
  let scope = try n07Scope()
  let registry = N07MockPushRegistry()
  let snapshot = ClairV2MobilePushRegistrationSnapshot(
    scope: scope, environment: .production, expiresAt: Date(timeIntervalSince1970: 20_000),
    requiresRegistration: false
  )
  await registry.setSnapshot(snapshot)
  let controller = ClairV2MobileReconnectController(pushRegistry: registry)
  await controller.attach(connection: try n07Connection())

  // The OS callback can fire before any destination is selected.
  await controller.recordDeviceToken(Data([0xAA, 0xBB]))
  #expect(await registry.registerCallCount == 0)

  let result = await controller.registerPendingPushTokenIfNeeded(
    environment: .production, scope: scope
  )

  #expect(result == .registered(snapshot))
  #expect(await registry.registerCallCount == 1)
}

@Test
func registeringPendingTokenWithoutOneYetIsASafeNoOp() async throws {
  let controller = ClairV2MobileReconnectController()
  let result = await controller.registerPendingPushTokenIfNeeded(
    environment: .sandbox, scope: try n07Scope()
  )
  #expect(result == .notRegistered)
}

@Test
func pushEnvironmentMatchesTheBuildDistribution() {
  #expect(ClairV2MobileEnvironment.development.pushEnvironment == .sandbox)
  #expect(ClairV2MobileEnvironment.testFlight.pushEnvironment == .production)
}

// MARK: - Notification category mapping

@Test
func notificationCategoryMirrorsEveryPushEventKind() {
  for kind in [ClairPushEventKind.attention, .completion] {
    let category = ClairV2MobileNotificationCategory(kind: kind)
    switch kind {
    case .attention:
      #expect(category == .attention)
    case .completion:
      #expect(category == .completion)
    }
  }
}

// MARK: - detach()

@Test
func detachClearsConnectionCacheAndState() async throws {
  let scope = try n07Scope()
  let cursor = try n07Cursor(scope: scope)
  let verifier = N07MockVerifier(cursorToReturn: cursor)
  let controller = ClairV2MobileReconnectController(verifier: verifier)
  await controller.attach(connection: try n07Connection())
  await controller.seedCache(cursor)
  _ = await controller.handle(.foregrounded)

  await controller.detach()

  #expect(await controller.state == .idle)
  #expect(await controller.currentCachedCursor == nil)
  #expect(await controller.isConnected == false)

  let afterDetach = await controller.handle(.foregrounded)
  #expect(afterDetach == .mustReconnect(nil, .notPaired))
}

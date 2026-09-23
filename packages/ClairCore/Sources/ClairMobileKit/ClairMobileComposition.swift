import ClairPush
import ClairShared
import ClairTransport
import Foundation

/// Connection state suitable for the native app's view layer. It contains
/// only the client state machine result, a monotonic session generation, and
/// public host metadata; the authenticated handle remains inside this
/// composition actor and the feature controllers it creates.
public struct ClairMobileCompositionSnapshot: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case disconnected
    case connecting
    case pairing
    case connected
    case reconnecting
    case staleGeneration
    case endpointPinFailure
    case failed(ClairMobileClientError)
  }

  public enum Notice: Equatable, Sendable {
    case none
    case staleGeneration
    case endpointPinFailure
  }

  public let clientState: ClairMobileClientState
  public let sessionGeneration: UInt64?
  public let connectionSummary: ClairMobileConnectionSummary?
  public let notice: Notice

  public var status: Status {
    if notice == .staleGeneration { return .staleGeneration }
    if notice == .endpointPinFailure { return .endpointPinFailure }
    switch clientState {
    case .disconnected:
      return .disconnected
    case .connecting:
      return .connecting
    case .pairing:
      return .pairing
    case .authenticated:
      return .connected
    case .reconnecting:
      return .reconnecting
    case .failed(let error) where error == .hostIdentityMismatch:
      return .endpointPinFailure
    case .failed(let error):
      return .failed(error)
    }
  }

  public init(
    clientState: ClairMobileClientState,
    sessionGeneration: UInt64?,
    connectionSummary: ClairMobileConnectionSummary?,
    notice: Notice = .none
  ) {
    self.clientState = clientState
    self.sessionGeneration = sessionGeneration
    self.connectionSummary = connectionSummary
    self.notice = notice
  }
}

/// The transport-backed mobile feature controllers created for one configured
/// remote host. A single adapter is shared so auth, conversation, diff,
/// session verification, push and terminal use the same pinned TLS channel.
public struct ClairMobileComposedSurfaces: Sendable {
  public let conversation: ClairMobileConversationController
  public let diffReview: ClairMobileDiffReviewController
  public let reconnect: ClairMobileReconnectController
  public let terminalTransport: any ClairMobileTerminalTransport

  public init(
    conversation: ClairMobileConversationController,
    diffReview: ClairMobileDiffReviewController,
    reconnect: ClairMobileReconnectController,
    terminalTransport: any ClairMobileTerminalTransport
  ) {
    self.conversation = conversation
    self.diffReview = diffReview
    self.reconnect = reconnect
    self.terminalTransport = terminalTransport
  }
}

/// Native mobile composition boundary. It restores the protected identity,
/// selects an endpoint from the pairing link or saved identity, creates one
/// TLS-pinned adapter, and shares its authenticated session across feature
/// controllers. Credentials and live connection handles never enter the
/// snapshot returned to SwiftUI.
public actor ClairMobileConnectionComposition {
  private let identityStore: any ClairDeviceIdentityStore
  private var client: ClairMobileClient?
  private var surfaces: ClairMobileComposedSurfaces?
  private var reconnectController: ClairMobileReconnectController?
  private var pendingPushToken: Data?
  private var notice: ClairMobileCompositionSnapshot.Notice = .none
  private var snapshotValue = ClairMobileCompositionSnapshot(
    clientState: .disconnected,
    sessionGeneration: nil,
    connectionSummary: nil
  )

  public init(identityStore: any ClairDeviceIdentityStore = ClairKeychainDeviceIdentityStore()) {
    self.identityStore = identityStore
  }

  public var snapshot: ClairMobileCompositionSnapshot { snapshotValue }

  /// Loads an existing protected identity and authenticates with a fresh
  /// challenge. An empty store remains a normal disconnected state.
  @discardableResult
  public func restoreAndReconnect() async -> ClairMobileCompositionSnapshot {
    do {
      guard let identity = try await identityStore.load() else {
        await resetRuntime()
        return await updateSnapshot(.disconnected)
      }
      try await configure(
        endpoint: identity.endpoint,
        hostPin: ClairHostPin(
          identity: identity.hostIdentity,
          certificateFingerprint: identity.certificateFingerprint
        )
      )
      return await reconnect()
    } catch {
      return await updateSnapshot(.failed(Self.mapClientError(error)))
    }
  }

  /// Completes pairing only after the caller has explicitly confirmed the
  /// displayed host fingerprint, then immediately authenticates a fresh
  /// connection through the same pinned adapter.
  @discardableResult
  public func pair(
    using link: ClairPairingLink,
    displayName: String,
    confirmHostFingerprint: Bool
  ) async -> ClairMobileCompositionSnapshot {
    do {
      try await configure(
        endpoint: link.endpoint,
        hostPin: ClairHostPin(hostID: link.hostID, fingerprint: link.hostFingerprint)
      )
      guard let client else { throw ClairMobileClientError.transportUnavailable }
      _ = await updateSnapshot(.pairing)
      _ = try await client.pair(
        using: link,
        displayName: displayName,
        confirmHostFingerprint: confirmHostFingerprint
      )
      return await reconnect()
    } catch {
      return await updateSnapshot(.failed(Self.mapClientError(error)))
    }
  }

  /// Decodes and rechecks the exact pairing code against the fingerprint the
  /// user reviewed in the UI before entering the client trust flow.
  @discardableResult
  public func pair(
    usingCode code: String,
    expectedHostID: ClairHostID,
    expectedFingerprint: ClairHostFingerprint,
    displayName: String,
    confirmHostFingerprint: Bool
  ) async -> ClairMobileCompositionSnapshot {
    do {
      let link = try ClairPairingLinkCodec.decode(code)
      guard link.hostID == expectedHostID,
        link.hostFingerprint == expectedFingerprint
      else {
        throw ClairMobileClientError.hostIdentityMismatch
      }
      return await pair(
        using: link,
        displayName: displayName,
        confirmHostFingerprint: confirmHostFingerprint
      )
    } catch {
      return await updateSnapshot(.failed(Self.mapClientError(error)))
    }
  }

  @discardableResult
  public func reconnect() async -> ClairMobileCompositionSnapshot {
    do {
      if client == nil {
        guard let identity = try await identityStore.load() else {
          return await updateSnapshot(.failed(.notPaired))
        }
        try await configure(
          endpoint: identity.endpoint,
          hostPin: ClairHostPin(
            identity: identity.hostIdentity,
            certificateFingerprint: identity.certificateFingerprint
          )
        )
      }
      guard let client else { throw ClairMobileClientError.transportUnavailable }
      _ = await updateSnapshot(.connecting)
      _ = try await client.reconnect()
      let session = await client.authenticatedSession
      await reconnectController?.attach(connection: session?.connection)
      await surfaces?.conversation.bindAuthenticatedSession(session)
      await surfaces?.diffReview.bindAuthenticatedSession(session)
      notice = .none
      return await refreshSnapshot()
    } catch {
      await reconnectController?.attach(connection: nil)
      return await updateSnapshot(.failed(Self.mapClientError(error)))
    }
  }

  public func disconnect() async -> ClairMobileCompositionSnapshot {
    await client?.disconnect()
    await reconnectController?.detach()
    if let surfaces {
      await surfaces.conversation.bindAuthenticatedSession(nil)
      await surfaces.diffReview.bindAuthenticatedSession(nil)
      await surfaces.conversation.detach()
      await surfaces.diffReview.detach()
    }
    notice = .none
    return await updateSnapshot(.disconnected)
  }

  @discardableResult
  public func markStaleGeneration() async -> ClairMobileCompositionSnapshot {
    notice = .staleGeneration
    return await refreshSnapshot()
  }

  /// Returns a live handle only when the caller's generation still matches.
  /// A delayed feature callback therefore cannot silently reuse a connection
  /// from before reconnect or disconnect.
  public func authenticatedSession(
    expectedGeneration: UInt64? = nil
  ) async -> ClairMobileAuthenticatedSession? {
    guard let client, let session = await client.authenticatedSession else { return nil }
    if let expectedGeneration, expectedGeneration != session.generation {
      notice = .staleGeneration
      _ = await refreshSnapshot()
      return nil
    }
    notice = .none
    _ = await refreshSnapshot()
    return session
  }

  public func composedSurfaces() -> ClairMobileComposedSurfaces? { surfaces }

  public var reconnectState: ClairMobileReconnectState {
    get async { await reconnectController?.state ?? .idle }
  }

  /// Produces only the redacted host list used by the UI; the stored identity
  /// and credential never leave this actor.
  public func hostManagementState() async -> ClairMobileHostManagementState {
    var state = ClairMobileHostManagementState()
    let identity = try? await identityStore.load()
    let clientState = await client?.state ?? .disconnected
    state.update(identity: identity, clientState: clientState)
    return state
  }

  /// Attaches project/diff and session-verification surfaces to the current
  /// authenticated handle. Agent and terminal session identities are supplied
  /// later by their own host-confirmed session attach flows; their transport
  /// boundary is already the same adapter returned here.
  public func attachReadSurfaces(to scope: ResourceScope, generation: UInt64) async -> Bool {
    guard let session = await authenticatedSession(expectedGeneration: generation),
      let surfaces
    else { return false }
    do {
      let projectScope = try ResourceScope(
        projectID: scope.projectID,
        worktreeID: scope.worktreeID
      )
      await surfaces.diffReview.attach(
        try ClairMobileDiffReviewController.Attachment(
          scope: projectScope,
          connection: session.connection
        )
      )
      await surfaces.reconnect.attach(connection: session.connection)
      return true
    } catch {
      return false
    }
  }

  @discardableResult
  public func handle(_ event: ClairMobileSceneEvent) async -> ClairMobileReconnectState {
    if client == nil {
      guard (await restoreAndReconnect()).sessionGeneration != nil else {
        return .mustReconnect(nil, .notPaired)
      }
    }
    if await client?.authenticatedSession == nil {
      guard (await reconnect()).sessionGeneration != nil else {
        return .mustReconnect(nil, .transportFailed)
      }
    }
    guard let reconnectController else {
      return .mustReconnect(nil, .notPaired)
    }
    if let session = await client?.authenticatedSession {
      await reconnectController.attach(connection: session.connection)
    }
    return await reconnectController.handle(event)
  }

  public func handleRemoteNotificationPayload(_ data: Data) async -> ClairMobileReconnectState {
    if client == nil, (await restoreAndReconnect()).sessionGeneration == nil {
      return .idle
    }
    guard let reconnectController else { return .idle }
    return await reconnectController.handleRemoteNotificationPayload(data)
  }

  public func recordDeviceToken(_ bytes: Data) async {
    pendingPushToken = bytes
    await reconnectController?.recordDeviceToken(bytes)
  }

  @discardableResult
  public func registerPendingPushTokenIfNeeded(
    environment: ClairPushEnvironment,
    scope: ResourceScope
  ) async -> ClairMobilePushRegistrationState {
    guard let reconnectController else { return .notRegistered }
    return await reconnectController.registerPendingPushTokenIfNeeded(
      environment: environment,
      scope: scope
    )
  }

  private func configure(endpoint: ClairTransportEndpoint, hostPin: ClairHostPin) async throws {
    await client?.disconnect()
    await reconnectController?.detach()
    if let surfaces {
      await surfaces.conversation.bindAuthenticatedSession(nil)
      await surfaces.conversation.detach()
      await surfaces.diffReview.bindAuthenticatedSession(nil)
      await surfaces.diffReview.detach()
    }
    let adapter = ClairRemoteMobileAdapter(endpoint: endpoint, pinnedTo: hostPin)
    let client = try ClairMobileClient(store: identityStore, transport: adapter)
    let conversation = ClairMobileConversationController(transport: adapter)
    let diffReview = ClairMobileDiffReviewController(reader: adapter)
    let reconnect = ClairMobileReconnectController(verifier: adapter, pushRegistry: adapter)
    if let pendingPushToken {
      await reconnect.recordDeviceToken(pendingPushToken)
    }
    self.client = client
    self.reconnectController = reconnect
    self.surfaces = ClairMobileComposedSurfaces(
      conversation: conversation,
      diffReview: diffReview,
      reconnect: reconnect,
      terminalTransport: adapter
    )
    notice = .none
    _ = await updateSnapshot(.disconnected)
  }

  private func resetRuntime() async {
    await client?.disconnect()
    await reconnectController?.detach()
    await surfaces?.conversation.bindAuthenticatedSession(nil)
    await surfaces?.diffReview.bindAuthenticatedSession(nil)
    client = nil
    reconnectController = nil
    surfaces = nil
    notice = .none
  }

  @discardableResult
  private func refreshSnapshot() async -> ClairMobileCompositionSnapshot {
    guard let client else { return await updateSnapshot(.disconnected) }
    return await updateSnapshot(await client.state)
  }

  @discardableResult
  private func updateSnapshot(
    _ state: ClairMobileClientState
  ) async -> ClairMobileCompositionSnapshot {
    let session = await client?.authenticatedSession
    let displaySession: ClairMobileAuthenticatedSession?
    if case .authenticated = state {
      displaySession = session
    } else {
      displaySession = nil
    }
    if case .failed(.hostIdentityMismatch) = state {
      notice = .endpointPinFailure
    } else if notice == .endpointPinFailure {
      notice = .none
    }
    snapshotValue = ClairMobileCompositionSnapshot(
      clientState: state,
      sessionGeneration: displaySession?.generation,
      connectionSummary: displaySession?.summary,
      notice: notice
    )
    return snapshotValue
  }

  private static func mapClientError(_ error: Error) -> ClairMobileClientError {
    if let clientError = error as? ClairMobileClientError { return clientError }
    if let storeError = error as? ClairDeviceIdentityStoreError {
      return .credentialStore(storeError)
    }
    if let transportError = error as? ClairTransportError {
      switch transportError {
      case .invalidPairingLink:
        return .invalidHandshake
      case .pairingExpired:
        return .pairingExpired
      case .pairingUnavailable:
        return .pairingUnavailable
      case .pairingConsumed:
        return .pairingReplayRejected
      case .userConfirmationRequired:
        return .userConfirmationRequired
      case .hostIdentityMismatch:
        return .hostIdentityMismatch
      case .notPaired:
        return .notPaired
      case .credentialExpired:
        return .credentialExpired
      case .deviceRevoked:
        return .deviceRevoked
      case .connectionClosed:
        return .connectionClosed
      default:
        return .invalidHandshake
      }
    }
    return .transportUnavailable
  }
}

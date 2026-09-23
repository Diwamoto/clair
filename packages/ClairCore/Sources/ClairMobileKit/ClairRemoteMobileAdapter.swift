import ClairAgent
import ClairPush
import ClairShared
import ClairTerminal
import ClairTransport
import ClairWorkspace
import Foundation

/// One pinned TLS channel shared by the mobile client's authentication and
/// the agent, workspace, session-verification, push, and terminal boundaries.
/// The local connection value is only a lookup key; the host binds authority
/// to its own authenticated channel and never accepts this value over the wire.
public actor ClairRemoteMobileAdapter: ClairMobileTransport,
  ClairMobileAgentTransport, ClairMobileWorkspaceReading, ClairMobileSessionVerifying,
  ClairMobilePushRegistering, ClairMobileTerminalTransport
{
  private struct ConnectionEntry: Sendable {
    let connection: ClairAuthenticatedConnection
    let client: ClairRemoteClient
  }

  private let endpoint: ClairTransportEndpoint
  private let hostPin: ClairHostPin
  private let boundary: ClairNetworkTLSMobileTransportBoundary
  private var handshakeClient: ClairRemoteClient?
  private var certificatePin: ClairCertificateFingerprint?
  private var connections: [ClairConnectionID: ConnectionEntry] = [:]

  public init(
    endpoint: ClairTransportEndpoint,
    pinnedTo hostPin: ClairHostPin,
    boundary: ClairNetworkTLSMobileTransportBoundary = .init()
  ) {
    self.endpoint = endpoint
    self.hostPin = hostPin
    self.boundary = boundary
  }

  // MARK: ClairMobileTransport

  public func presentation() async throws -> ClairHostPresentation {
    let (reply, _) = try await clientForHandshake().call(.presentation)
    guard case .presentation(let presentation) = reply else {
      throw ClairRemoteError.protocolViolation
    }
    return presentation
  }

  public func certificateFingerprint() async throws -> ClairCertificateFingerprint? {
    _ = try await clientForHandshake()
    return certificatePin
  }

  public func pair(_ request: ClairPairingRequest) async throws -> ClairPairingResult {
    let (reply, _) = try await clientForHandshake().call(.pair(request))
    guard case .paired(let result) = reply else { throw ClairRemoteError.protocolViolation }
    return result
  }

  public func beginAuthentication(_ request: ClairReconnectRequest) async throws -> ClairChallenge {
    let (reply, _) = try await clientForHandshake().call(.beginAuthentication(request))
    guard case .challenge(let challenge) = reply else {
      throw ClairRemoteError.protocolViolation
    }
    return challenge
  }

  public func authenticate(_ proof: ClairChallengeProof) async throws
    -> ClairAuthenticatedConnection
  {
    let client = try await clientForHandshake()
    let (reply, _) = try await client.call(.authenticate(proof))
    guard case .authenticated(let info) = reply else {
      throw ClairRemoteError.protocolViolation
    }
    let connection = ClairAuthenticatedConnection(clientInfo: info)
    connections[info.connectionID] = ConnectionEntry(connection: connection, client: client)
    return connection
  }

  public func authorizeRead(
    scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    guard case .ok = try await call(.authorizeRead(scope), on: connection) else {
      throw ClairRemoteError.protocolViolation
    }
  }

  public func isConnectionActive(_ connection: ClairAuthenticatedConnection) async -> Bool {
    guard let entry = connections[connection.connectionID], entry.connection == connection else {
      return false
    }
    return await entry.client.isOpen
  }

  public func close(_ connection: ClairAuthenticatedConnection) async {
    guard let entry = connections[connection.connectionID], entry.connection == connection else {
      return
    }
    connections.removeValue(forKey: connection.connectionID)
    await entry.client.close()
    if handshakeClient === entry.client {
      handshakeClient = nil
      certificatePin = nil
    }
  }

  // MARK: ClairMobileAgentTransport

  public func dispatch(
    _ command: ClairAgentCommand,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairAgentCommandOutcome {
    guard
      case .agentDispatched(let outcome, _) = try await call(
        .agentDispatch(command), on: connection)
    else { throw ClairRemoteError.protocolViolation }
    return outcome
  }

  // MARK: ClairMobileWorkspaceReading

  public func changedFileSummary(
    for scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairChangedFileSummary {
    guard scope.sessionID == nil else { throw ClairRemoteError.protocolViolation }
    guard
      case .changedFileSummary(let summary) = try await call(
        .workspaceChangedFiles(scope), on: connection)
    else { throw ClairRemoteError.protocolViolation }
    return summary
  }

  public func diff(
    for scope: ResourceScope,
    path: ClairWorkspacePath,
    basis: ClairGitDiffBasis,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairGitDiff {
    guard scope.sessionID == nil else { throw ClairRemoteError.protocolViolation }
    guard
      case .gitDiff(let diff) = try await call(
        .workspaceDiff(scope: scope, path: path, basis: basis), on: connection)
    else { throw ClairRemoteError.protocolViolation }
    return diff
  }

  // MARK: ClairMobileSessionVerifying

  public func verify(
    scope: ResourceScope,
    cachedCursor: ReplayCursor?,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ReplayCursor {
    guard scope.sessionID != nil else { throw ClairRemoteError.protocolViolation }
    guard
      case .sessionVerified(let cursor) = try await call(
        .sessionVerify(scope: scope, cachedCursor: cachedCursor), on: connection)
    else { throw ClairRemoteError.protocolViolation }
    return cursor
  }

  // MARK: ClairMobilePushRegistering

  public func register(
    token: ClairPushDeviceToken,
    environment: ClairPushEnvironment,
    scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairMobilePushRegistrationSnapshot {
    let bytes = token.withBytes { $0 }
    guard
      case .pushRegistered(
        let registeredScope, let registeredEnvironment, let expiresAt, let requiresRegistration) =
        try await call(
          .pushRegister(token: bytes, environment: environment, scope: scope), on: connection),
      registeredScope == scope, registeredEnvironment == environment
    else { throw ClairRemoteError.protocolViolation }
    return ClairMobilePushRegistrationSnapshot(
      scope: registeredScope, environment: registeredEnvironment,
      expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt)),
      requiresRegistration: requiresRegistration)
  }

  public func unregister(
    environment: ClairPushEnvironment,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    guard case .ok = try await call(.pushUnregister(environment), on: connection) else {
      throw ClairRemoteError.protocolViolation
    }
  }

  // MARK: ClairMobileTerminalTransport

  public func attach(
    scope: ResourceScope,
    generation: UInt64,
    cursor: ClairTerminalCursor?,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairMobileTerminalAttachment {
    let (reply, _) = try await client(for: connection).call(
      .terminalAttach(scope: scope, generation: generation, subscriberID: UUID(), cursor: cursor))
    guard case .terminalAttached(let id, let confirmedCursor, let size, _, _, _) = reply else {
      throw ClairRemoteError.protocolViolation
    }
    return ClairMobileTerminalAttachment(
      id: id, scope: scope, generation: generation, cursor: confirmedCursor,
      size: size, epoch: confirmedCursor.epoch)
  }

  public func read(
    _ attachment: ClairMobileTerminalAttachment,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairTerminalFrame? {
    let (reply, data) = try await client(for: connection).call(
      .terminalRead(
        attachment: attachment.id, waitMilliseconds: ClairRemoteWire.maximumReadWaitMilliseconds))
    switch reply {
    case .terminalFrame:
      guard let data else { throw ClairRemoteError.protocolViolation }
      return try ClairTerminalFrame.decode(data)
    case .terminalIdle:
      return nil
    default:
      throw ClairRemoteError.protocolViolation
    }
  }

  public func acknowledge(
    _ attachment: ClairMobileTerminalAttachment,
    cursor: ClairTerminalCursor,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    guard cursor.epoch == attachment.epoch,
      case .ok = try await call(
        .terminalAcknowledge(attachment: attachment.id, cursor: cursor), on: connection)
    else { throw ClairRemoteError.protocolViolation }
  }

  public func input(
    _ bytes: Data,
    attachment: ClairMobileTerminalAttachment,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    let operationID = try OperationID("mobile-terminal-\(UUID().uuidString.lowercased())")
    let (reply, _) = try await client(for: connection).call(
      .terminalInput(
        operationID: operationID, scope: attachment.scope, epoch: attachment.epoch,
        processGeneration: attachment.generation), binary: bytes)
    guard case .terminalInput(.queued, _) = reply else {
      throw ClairRemoteError.remote(code: "terminalInputRejected")
    }
  }

  public func detach(
    _ attachment: ClairMobileTerminalAttachment,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    guard case .ok = try await call(.terminalDetach(attachment: attachment.id), on: connection)
    else {
      throw ClairRemoteError.protocolViolation
    }
  }

  // MARK: Channel routing

  private func clientForHandshake() async throws -> ClairRemoteClient {
    if let handshakeClient, await handshakeClient.isOpen { return handshakeClient }
    connections.removeAll()
    let channel = try await boundary.openChannel(to: endpoint, pinnedTo: hostPin)
    if let tls = channel as? ClairTLSChannel, let digest = tls.peerCertificateFingerprint {
      certificatePin = try ClairCertificateFingerprint(sha256Digest: digest)
    } else {
      certificatePin = nil
    }
    let client = ClairRemoteClient(channel: channel)
    handshakeClient = client
    return client
  }

  private func client(for connection: ClairAuthenticatedConnection) throws -> ClairRemoteClient {
    guard let entry = connections[connection.connectionID], entry.connection == connection else {
      throw ClairRemoteError.closed
    }
    return entry.client
  }

  private func call(
    _ request: ClairRemoteCall,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairRemoteReply {
    let (reply, _) = try await client(for: connection).call(request)
    return reply
  }
}

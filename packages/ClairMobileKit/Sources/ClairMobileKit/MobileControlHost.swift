import CryptoKit
import Foundation

// MARK: - Host identity and credentials

public struct MobileHostIdentity: Codable, Equatable, Sendable {
  public let hostID: UUID
  public let fingerprint: String
  public let protocolVersion: MobileProtocolVersion

  public init(
    hostID: UUID = UUID(),
    fingerprint: String,
    protocolVersion: MobileProtocolVersion = .init(major: 1, minor: 0)
  ) {
    self.hostID = hostID
    self.fingerprint = fingerprint
    self.protocolVersion = protocolVersion
  }
}

public struct MobileDeviceKeyPair: Sendable {
  private let privateKeyRepresentation: Data

  public init() {
    privateKeyRepresentation = P256.Signing.PrivateKey().rawRepresentation
  }

  public init(rawRepresentation: Data) throws {
    _ = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    privateKeyRepresentation = rawRepresentation
  }

  /// The private key bytes are only for protected local storage.
  /// They must never be put in a pairing link, log, or network payload.
  public var rawRepresentation: Data {
    privateKeyRepresentation
  }

  public var publicKeyRepresentation: Data {
    (try? P256.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation).publicKey
      .rawRepresentation) ?? Data()
  }

  public func sign(_ challenge: Data) throws -> Data {
    let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation)
    return try privateKey.signature(for: challenge).derRepresentation
  }
}

public struct MobilePairingLink: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let endpoint: String
  public let hostIdentity: MobileHostIdentity
  public let bootstrapSecret: String
  public let expiresAt: Date
  public let transport: MobilePrivateTransportKind

  public init(
    id: UUID,
    endpoint: String,
    hostIdentity: MobileHostIdentity,
    bootstrapSecret: String,
    expiresAt: Date,
    transport: MobilePrivateTransportKind = .loopback
  ) {
    self.id = id
    self.endpoint = endpoint
    self.hostIdentity = hostIdentity
    self.bootstrapSecret = bootstrapSecret
    self.expiresAt = expiresAt
    self.transport = transport
  }
}

public struct MobileDeviceCredential: Codable, Equatable, Sendable {
  public let deviceID: UUID
  public let token: String
  public let generation: UInt64
  public let scopes: Set<MobileControlScope>
  public let hostIdentity: MobileHostIdentity

  public init(
    deviceID: UUID,
    token: String,
    generation: UInt64,
    scopes: Set<MobileControlScope>,
    hostIdentity: MobileHostIdentity
  ) {
    self.deviceID = deviceID
    self.token = token
    self.generation = generation
    self.scopes = scopes
    self.hostIdentity = hostIdentity
  }
}

public struct MobileAuthenticationChallenge: Codable, Equatable, Sendable {
  public let id: UUID
  public let bytes: Data
  public let expiresAt: Date

  public init(id: UUID, bytes: Data, expiresAt: Date) {
    self.id = id
    self.bytes = bytes
    self.expiresAt = expiresAt
  }
}

public struct MobileDeviceSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let displayName: String
  public let generation: UInt64
  public let scopes: Set<MobileControlScope>
  public let createdAt: Date
  public let lastUsedAt: Date?
  public let isRevoked: Bool

  public init(
    id: UUID,
    displayName: String,
    generation: UInt64,
    scopes: Set<MobileControlScope>,
    createdAt: Date,
    lastUsedAt: Date?,
    isRevoked: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.generation = generation
    self.scopes = scopes
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.isRevoked = isRevoked
  }
}

public enum MobileHostError: Error, Equatable, LocalizedError, Sendable {
  case disabled
  case invalidEndpoint
  case invalidPairingLink
  case pairingExpired
  case pairingAlreadyUsed
  case invalidHostIdentity
  case invalidDeviceKey
  case authenticationFailed
  case challengeExpired
  case deviceNotFound(UUID)
  case revokedDevice
  case connectionNotFound(UUID)
  case sessionNotFound(UUID)
  case invalidCursor
  case outputOffsetDiscontinuity(expected: UInt64, actual: UInt64)
  case outputEpochMismatch
  case invalidOperation

  public var errorDescription: String? {
    switch self {
    case .disabled:
      "Mobile control is disabled."
    case .invalidEndpoint:
      "The mobile endpoint is invalid."
    case .invalidPairingLink:
      "The mobile pairing link is invalid."
    case .pairingExpired:
      "The mobile pairing link has expired."
    case .pairingAlreadyUsed:
      "The mobile pairing link has already been used."
    case .invalidHostIdentity:
      "The mobile host identity does not match the pinned identity."
    case .invalidDeviceKey:
      "The mobile device key is invalid."
    case .authenticationFailed:
      "The mobile device could not be authenticated."
    case .challengeExpired:
      "The mobile authentication challenge has expired or was already used."
    case .deviceNotFound(let deviceID):
      "Mobile device \(deviceID.uuidString) was not found."
    case .revokedDevice:
      "The mobile device has been revoked."
    case .connectionNotFound(let connectionID):
      "Mobile connection \(connectionID.uuidString) was not found."
    case .sessionNotFound(let sessionID):
      "Mobile session \(sessionID.uuidString) was not found."
    case .invalidCursor:
      "The mobile session cursor is invalid."
    case .outputOffsetDiscontinuity(let expected, let actual):
      "Mobile terminal output offset must continue at \(expected), got \(actual)."
    case .outputEpochMismatch:
      "Mobile terminal output belongs to a different session epoch."
    case .invalidOperation:
      "The mobile operation is invalid."
    }
  }
}

// The persisted record intentionally contains hashes and public material only.
// Raw pairing secrets, device tokens, and private keys never enter this type.
struct MobileHostDeviceRecord: Codable, Equatable, Sendable {
  let deviceID: UUID
  var displayName: String
  let publicKey: Data
  let tokenDigest: Data
  var generation: UInt64
  var scopes: Set<MobileControlScope>
  var allowedWorktreeIDs: Set<UUID>?
  let createdAt: Date
  var lastUsedAt: Date?
  var revokedAt: Date?

  var isRevoked: Bool {
    revokedAt != nil
  }

  func summary() -> MobileDeviceSummary {
    MobileDeviceSummary(
      id: deviceID,
      displayName: displayName,
      generation: generation,
      scopes: scopes,
      createdAt: createdAt,
      lastUsedAt: lastUsedAt,
      isRevoked: isRevoked
    )
  }

  func grant() -> MobileDeviceGrant {
    MobileDeviceGrant(
      deviceID: deviceID,
      scopes: scopes,
      allowedWorktreeIDs: allowedWorktreeIDs,
      isRevoked: isRevoked
    )
  }
}

struct MobileHostPairingRecord: Codable, Equatable, Sendable {
  let id: UUID
  let endpoint: String
  let hostIdentity: MobileHostIdentity
  let bootstrapDigest: Data
  let expiresAt: Date
}

public struct MobileHostSnapshot: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public var identity: MobileHostIdentity
  public var isEnabled: Bool
  var pairing: MobileHostPairingRecord?
  var devices: [MobileHostDeviceRecord]

  public init(
    identity: MobileHostIdentity,
    isEnabled: Bool = false
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.identity = identity
    self.isEnabled = isEnabled
    pairing = nil
    devices = []
  }
}

public final class MobileHostStore: @unchecked Sendable {
  public let fileURL: URL?
  private let fileManager: FileManager

  public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public func load(
    default snapshot: MobileHostSnapshot,
    expectedIdentity: MobileHostIdentity? = nil
  ) throws -> MobileHostSnapshot {
    guard let fileURL else {
      return snapshot
    }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return snapshot
    }
    let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard values.isSymbolicLink != true else {
      throw CocoaError(
        .fileReadNoPermission,
        userInfo: [NSLocalizedDescriptionKey: "Mobile host store must not be a symbolic link."]
      )
    }
    let data = try Data(contentsOf: fileURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let loaded = try decoder.decode(MobileHostSnapshot.self, from: data)
    guard loaded.schemaVersion == MobileHostSnapshot.currentSchemaVersion else {
      throw CocoaError(
        .fileReadCorruptFile,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported mobile host store version."]
      )
    }
    guard expectedIdentity == nil || loaded.identity == expectedIdentity else {
      throw MobileHostError.invalidHostIdentity
    }
    return loaded
  }

  public func save(_ snapshot: MobileHostSnapshot) throws {
    guard let fileURL else {
      return
    }
    let directory = fileURL.deletingLastPathComponent()
    let directoryAlreadyExists = fileManager.fileExists(atPath: directory.path)
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    if !directoryAlreadyExists {
      try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    try data.write(to: fileURL, options: [.atomic])
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }
}

// MARK: - Bounded stream state

public struct MobileTerminalGap: Codable, Equatable, Sendable {
  public let streamID: UInt32
  public let sessionEpoch: UInt64
  public let startOffset: UInt64
  public let endOffset: UInt64

  public init(
    streamID: UInt32,
    sessionEpoch: UInt64,
    startOffset: UInt64,
    endOffset: UInt64
  ) {
    self.streamID = streamID
    self.sessionEpoch = sessionEpoch
    self.startOffset = startOffset
    self.endOffset = endOffset
  }
}

public struct MobileTerminalExit: Codable, Equatable, Sendable {
  public let streamID: UInt32
  public let sessionEpoch: UInt64
  public let status: Int
  public let offset: UInt64

  public init(streamID: UInt32, sessionEpoch: UInt64, status: Int, offset: UInt64) {
    self.streamID = streamID
    self.sessionEpoch = sessionEpoch
    self.status = status
    self.offset = offset
  }
}

public enum MobileHostStreamEvent: Equatable, Sendable {
  case output(MobileTerminalFrame)
  case gap(MobileTerminalGap)
  case exit(MobileTerminalExit)

  public var byteCount: Int {
    switch self {
    case .output(let frame):
      frame.payload.count
    case .gap, .exit:
      0
    }
  }
}

public struct MobileSessionStreamSnapshot: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let epoch: UInt64
  public let currentOffset: UInt64
  public let oldestOffset: UInt64
  public let isExited: Bool

  public init(
    sessionID: UUID,
    epoch: UInt64,
    currentOffset: UInt64,
    oldestOffset: UInt64,
    isExited: Bool
  ) {
    self.sessionID = sessionID
    self.epoch = epoch
    self.currentOffset = currentOffset
    self.oldestOffset = oldestOffset
    self.isExited = isExited
  }
}

public struct MobileSubscriptionReceipt: Equatable, Sendable {
  public let subscriptionID: UUID
  public let streamID: UInt32
  public let session: MobileSessionStreamSnapshot
  public let events: [MobileHostStreamEvent]

  public init(
    subscriptionID: UUID,
    streamID: UInt32,
    session: MobileSessionStreamSnapshot,
    events: [MobileHostStreamEvent]
  ) {
    self.subscriptionID = subscriptionID
    self.streamID = streamID
    self.session = session
    self.events = events
  }
}

public struct MobileControlHostHandlers: Sendable {
  public var terminalInput: (@Sendable (MobileAcceptedInput) -> Void)?
  public var agentInput: (@Sendable (MobileAcceptedAgentInput) -> Void)?
  public var agentControl: (@Sendable (MobileAcceptedAgentControl) -> Void)?
  public var agentLaunch: (@Sendable (MobileAcceptedAgentLaunch) -> Void)?

  public init(
    terminalInput: (@Sendable (MobileAcceptedInput) -> Void)? = nil,
    agentInput: (@Sendable (MobileAcceptedAgentInput) -> Void)? = nil,
    agentControl: (@Sendable (MobileAcceptedAgentControl) -> Void)? = nil,
    agentLaunch: (@Sendable (MobileAcceptedAgentLaunch) -> Void)? = nil
  ) {
    self.terminalInput = terminalInput
    self.agentInput = agentInput
    self.agentControl = agentControl
    self.agentLaunch = agentLaunch
  }
}

private struct MobileJournalChunk: Equatable, Sendable {
  let offset: UInt64
  let data: Data

  var endOffset: UInt64 {
    offset &+ UInt64(data.count)
  }
}

private struct MobileHostSessionState: Sendable {
  var descriptor: MobileSessionDescriptor
  let epoch: UInt64
  var chunks: [MobileJournalChunk]
  var journalBytes: Int
  var currentOffset: UInt64
  var isExited: Bool
  var exitStatus: Int?

  var oldestOffset: UInt64 {
    chunks.first?.offset ?? currentOffset
  }

  var snapshot: MobileSessionStreamSnapshot {
    MobileSessionStreamSnapshot(
      sessionID: descriptor.id,
      epoch: epoch,
      currentOffset: currentOffset,
      oldestOffset: oldestOffset,
      isExited: isExited
    )
  }
}

private struct MobileHostSubscriptionState: Sendable {
  let id: UUID
  let deviceID: UUID
  let connectionID: UUID?
  let sessionID: UUID
  let streamID: UInt32
  let maximumQueueBytes: Int
  var events: [MobileHostStreamEvent]
  var queuedBytes: Int
  var cursor: UInt64
}

private enum MobileHostAcceptedOperation: Sendable {
  case agentInput(MobileAcceptedAgentInput)
  case agentControl(MobileAcceptedAgentControl)
  case agentLaunch(MobileAcceptedAgentLaunch)
}

private struct MobileHostOperationRecord: Sendable {
  let fingerprint: Data
  let accepted: MobileHostAcceptedOperation
}

// MARK: - Host core

/// The local, transport-neutral mobile host boundary.
///
/// This type owns pairing, authorization, session projection, journal replay,
/// subscriber bounds, and broker-order input acceptance. A TCP/WebSocket or
/// Cloudflare/Tailscale adapter must call these methods; it must not implement
/// a second authorization or ordering path.
public final class MobileControlHost: @unchecked Sendable {
  public static let defaultPairingLifetime: TimeInterval = 5 * 60
  public static let defaultChallengeLifetime: TimeInterval = 60
  public static let defaultJournalBytes = 256 * 1024
  public static let defaultSubscriberQueueBytes = 256 * 1024

  private let lock = NSLock()
  private let store: MobileHostStore
  private var snapshot: MobileHostSnapshot
  private var challenges: [UUID: (deviceID: UUID, bytes: Data, expiresAt: Date)] = [:]
  private var connections: [UUID: UUID] = [:]
  private var sessions: [UUID: MobileHostSessionState] = [:]
  private var agents: [UUID: MobileAgentDescriptor] = [:]
  private var registeredAgentProfiles: [String: MobileAgentProfileDescriptor] = [:]
  private var subscriptions: [UUID: MobileHostSubscriptionState] = [:]
  private var handlers = MobileControlHostHandlers()
  private var rememberedAgentOperations: [UUID: MobileHostOperationRecord] = [:]
  private var rememberedAgentOperationOrder: [UUID] = []
  private var sequencer = MobileInputSequencer()
  private var nextStreamID: UInt32 = 1

  public init(
    store: MobileHostStore = MobileHostStore(),
    identity: MobileHostIdentity = MobileHostIdentity(fingerprint: "")
  ) throws {
    let hasExplicitIdentity = !identity.fingerprint.isEmpty
    let resolvedIdentity =
      identity.fingerprint.isEmpty
      ? MobileHostIdentity(
        hostID: identity.hostID,
        fingerprint: Self.fingerprint(for: identity.hostID)
      )
      : identity
    let initial = MobileHostSnapshot(identity: resolvedIdentity)
    self.store = store
    snapshot = try store.load(
      default: initial,
      expectedIdentity: hasExplicitIdentity ? resolvedIdentity : nil
    )
  }

  public var identity: MobileHostIdentity {
    lock.withLock { snapshot.identity }
  }

  public var isEnabled: Bool {
    lock.withLock { snapshot.isEnabled }
  }

  public func makeConnection() -> MobileControlConnection {
    MobileControlConnection(host: self)
  }

  func closeConnection(_ connectionID: UUID) {
    lock.withLock {
      guard connections.removeValue(forKey: connectionID) != nil else {
        return
      }
      subscriptions = subscriptions.filter { $0.value.connectionID != connectionID }
    }
  }

  func deviceID(for connectionID: UUID) throws -> UUID {
    try lock.withLock {
      guard let deviceID = connections[connectionID] else {
        throw MobileHostError.connectionNotFound(connectionID)
      }
      _ = try grant(for: deviceID)
      return deviceID
    }
  }

  func requireScope(_ scope: MobileControlScope, for connectionID: UUID) throws -> UUID {
    let deviceID = try deviceID(for: connectionID)
    try lock.withLock {
      let deviceGrant = try grant(for: deviceID)
      guard deviceGrant.scopes.contains(scope) else {
        throw MobileProtocolError.invalidScope(scope)
      }
    }
    return deviceID
  }

  @discardableResult
  public func setEnabled(_ enabled: Bool) throws -> Set<UUID> {
    try lock.withLock {
      snapshot.isEnabled = enabled
      let closedConnections = enabled ? [] : Set(connections.keys)
      if !enabled {
        connections.removeAll()
        subscriptions.removeAll()
      }
      try store.save(snapshot)
      return closedConnections
    }
  }

  /// Installs the application-owned bridge for accepted operations. The
  /// closures are called outside the host lock and only successful, non-duplicate
  /// operations are delivered.
  public func setOperationHandlers(_ handlers: MobileControlHostHandlers) {
    lock.withLock {
      self.handlers = handlers
    }
  }

  public func createPairingLink(
    endpoint: String,
    now: Date = Date(),
    lifetime: TimeInterval = MobileControlHost.defaultPairingLifetime
  ) throws -> MobilePairingLink {
    guard Self.isValidEndpoint(endpoint) else {
      throw MobileHostError.invalidEndpoint
    }
    guard lifetime > 0 else {
      throw MobileHostError.invalidPairingLink
    }

    return try lock.withLock {
      let id = UUID()
      let secret = Self.randomToken()
      let expiresAt = now.addingTimeInterval(lifetime)
      snapshot.pairing = MobileHostPairingRecord(
        id: id,
        endpoint: endpoint,
        hostIdentity: snapshot.identity,
        bootstrapDigest: Self.digest(secret),
        expiresAt: expiresAt
      )
      try store.save(snapshot)
      return MobilePairingLink(
        id: id,
        endpoint: endpoint,
        hostIdentity: snapshot.identity,
        bootstrapSecret: secret,
        expiresAt: expiresAt
      )
    }
  }

  public func pair(
    link: MobilePairingLink,
    displayName: String,
    devicePublicKey: Data,
    now: Date = Date()
  ) throws -> MobileDeviceCredential {
    guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MobileHostError.invalidPairingLink
    }
    guard Self.isValidPublicKey(devicePublicKey) else {
      throw MobileHostError.invalidDeviceKey
    }

    return try lock.withLock {
      guard snapshot.isEnabled else {
        throw MobileHostError.disabled
      }
      guard let pairing = snapshot.pairing, pairing.id == link.id else {
        throw MobileHostError.invalidPairingLink
      }
      guard pairing.hostIdentity == link.hostIdentity,
        pairing.endpoint == link.endpoint,
        pairing.expiresAt == link.expiresAt
      else {
        throw MobileHostError.invalidHostIdentity
      }
      guard now < pairing.expiresAt else {
        snapshot.pairing = nil
        try store.save(snapshot)
        throw MobileHostError.pairingExpired
      }
      guard pairing.bootstrapDigest == Self.digest(link.bootstrapSecret) else {
        throw MobileHostError.invalidPairingLink
      }

      let deviceID = UUID()
      let token = Self.randomToken()
      let record = MobileHostDeviceRecord(
        deviceID: deviceID,
        displayName: displayName,
        publicKey: devicePublicKey,
        tokenDigest: Self.digest(token),
        generation: 1,
        scopes: [.view],
        allowedWorktreeIDs: nil,
        createdAt: now,
        lastUsedAt: now,
        revokedAt: nil
      )
      snapshot.devices.append(record)
      snapshot.pairing = nil
      try store.save(snapshot)
      return MobileDeviceCredential(
        deviceID: deviceID,
        token: token,
        generation: record.generation,
        scopes: record.scopes,
        hostIdentity: snapshot.identity
      )
    }
  }

  public func issueChallenge(
    for deviceID: UUID,
    now: Date = Date(),
    lifetime: TimeInterval = MobileControlHost.defaultChallengeLifetime
  ) throws -> MobileAuthenticationChallenge {
    try lock.withLock {
      try validateEnabledAndDevice(deviceID)
      let challenge = MobileAuthenticationChallenge(
        id: UUID(),
        bytes: Self.randomBytes(count: 32),
        expiresAt: now.addingTimeInterval(lifetime)
      )
      challenges[challenge.id] = (
        deviceID: deviceID,
        bytes: challenge.bytes,
        expiresAt: challenge.expiresAt
      )
      return challenge
    }
  }

  @discardableResult
  public func authenticate(
    deviceID: UUID,
    token: String,
    challenge: MobileAuthenticationChallenge,
    signature: Data,
    now: Date = Date(),
    connectionID: UUID = UUID()
  ) throws -> UUID {
    try lock.withLock {
      guard snapshot.isEnabled else {
        throw MobileHostError.disabled
      }
      guard let pending = challenges.removeValue(forKey: challenge.id),
        pending.deviceID == deviceID,
        pending.bytes == challenge.bytes,
        pending.expiresAt == challenge.expiresAt,
        now < pending.expiresAt
      else {
        throw MobileHostError.challengeExpired
      }
      guard let index = snapshot.devices.firstIndex(where: { $0.deviceID == deviceID }) else {
        throw MobileHostError.authenticationFailed
      }
      guard connections[connectionID] == nil else {
        throw MobileHostError.invalidOperation
      }
      var record = snapshot.devices[index]
      guard !record.isRevoked, record.tokenDigest == Self.digest(token) else {
        throw record.isRevoked
          ? MobileHostError.revokedDevice : MobileHostError.authenticationFailed
      }
      guard Self.isValidSignature(signature, challenge: pending.bytes, publicKey: record.publicKey)
      else {
        throw MobileHostError.authenticationFailed
      }
      record.lastUsedAt = now
      snapshot.devices[index] = record
      connections[connectionID] = deviceID
      try store.save(snapshot)
      return connectionID
    }
  }

  @discardableResult
  public func revokeDevice(_ deviceID: UUID, now: Date = Date()) throws -> Set<UUID> {
    try lock.withLock {
      guard let index = snapshot.devices.firstIndex(where: { $0.deviceID == deviceID }) else {
        throw MobileHostError.deviceNotFound(deviceID)
      }
      snapshot.devices[index].generation &+= 1
      snapshot.devices[index].revokedAt = now
      let closedConnections = Set(
        connections.compactMap { connectionID, connectedDeviceID in
          connectedDeviceID == deviceID ? connectionID : nil
        }
      )
      for connectionID in closedConnections {
        connections[connectionID] = nil
      }
      subscriptions = subscriptions.filter { $0.value.deviceID != deviceID }
      try store.save(snapshot)
      return closedConnections
    }
  }

  public func devices() -> [MobileDeviceSummary] {
    lock.withLock {
      snapshot.devices.map { $0.summary() }.sorted { $0.createdAt < $1.createdAt }
    }
  }

  public func setScopes(
    _ scopes: Set<MobileControlScope>,
    for deviceID: UUID,
    allowedWorktreeIDs: Set<UUID>? = nil
  ) throws {
    try lock.withLock {
      guard let index = snapshot.devices.firstIndex(where: { $0.deviceID == deviceID }) else {
        throw MobileHostError.deviceNotFound(deviceID)
      }
      guard !scopes.isEmpty, scopes.contains(.view) else {
        throw MobileProtocolError.invalidScope(.view)
      }
      snapshot.devices[index].scopes = scopes
      snapshot.devices[index].allowedWorktreeIDs = allowedWorktreeIDs
      try store.save(snapshot)
    }
  }

  public func registerSession(
    _ descriptor: MobileSessionDescriptor,
    epoch: UInt64,
    currentOffset: UInt64 = 0,
    isExited: Bool = false
  ) throws {
    guard epoch > 0 else {
      throw MobileHostError.outputEpochMismatch
    }
    lock.withLock {
      sessions[descriptor.id] = MobileHostSessionState(
        descriptor: descriptor,
        epoch: epoch,
        chunks: [],
        journalBytes: 0,
        currentOffset: currentOffset,
        isExited: isExited,
        exitStatus: nil
      )
    }
  }

  /// Updates the factual session projection without resetting its journal or
  /// active subscriptions. Runtime bridges call this when a terminal changes
  /// lifecycle or gains/loses an operation capability.
  public func updateSession(
    _ descriptor: MobileSessionDescriptor,
    isExited: Bool? = nil
  ) throws {
    try lock.withLock {
      guard var session = sessions[descriptor.id] else {
        throw MobileHostError.sessionNotFound(descriptor.id)
      }
      guard descriptor.projectID == session.descriptor.projectID,
        descriptor.worktreeID == session.descriptor.worktreeID,
        descriptor.cwd == session.descriptor.cwd
      else {
        throw MobileHostError.invalidOperation
      }
      session.descriptor = descriptor
      if let isExited {
        session.isExited = isExited
      }
      sessions[descriptor.id] = session
    }
  }

  public func registerAgent(_ descriptor: MobileAgentDescriptor) {
    lock.withLock {
      agents[descriptor.id] = descriptor
    }
  }

  public func registerAgentProfile(
    _ profileID: String,
    title: String? = nil,
    models: [MobileAgentModelDescriptor] = [],
    capabilities: Set<MobileCapability> = [.agentLaunch]
  ) throws {
    guard !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MobileProtocolError.invalidAgentProfile
    }
    lock.withLock {
      registeredAgentProfiles[profileID] = MobileAgentProfileDescriptor(
        id: profileID,
        title: title ?? profileID,
        models: models,
        capabilities: capabilities
      )
    }
  }

  public func registeredProfiles() -> [MobileAgentProfileDescriptor] {
    lock.withLock {
      registeredAgentProfiles.values.sorted { $0.id < $1.id }
    }
  }

  public func removeSession(_ sessionID: UUID) {
    lock.withLock {
      sessions[sessionID] = nil
      subscriptions = subscriptions.filter { $0.value.sessionID != sessionID }
      agents = agents.filter { $0.value.id != sessionID }
    }
  }

  public func unsubscribe(_ subscriptionID: UUID) {
    lock.withLock {
      subscriptions[subscriptionID] = nil
    }
  }

  public func unsubscribe(_ subscriptionID: UUID, deviceID: UUID) throws {
    try lock.withLock {
      guard let subscription = subscriptions[subscriptionID], subscription.deviceID == deviceID
      else {
        throw MobileHostError.invalidOperation
      }
      subscriptions[subscriptionID] = nil
    }
  }

  public func takeSubscriptionEvents(_ subscriptionID: UUID) throws -> [MobileHostStreamEvent] {
    try poll(subscriptionID: subscriptionID)
  }

  public func visibleSessions(for deviceID: UUID) throws -> [MobileSessionDescriptor] {
    try lock.withLock {
      let grant = try grant(for: deviceID)
      return sessions.values.map(\.descriptor).filter(grant.canAccess).sorted {
        $0.id.uuidString < $1.id.uuidString
      }
    }
  }

  public func visibleAgents(for deviceID: UUID) throws -> [MobileAgentDescriptor] {
    try lock.withLock {
      let grant = try grant(for: deviceID)
      return agents.values.filter(grant.canAccess).sorted {
        $0.id.uuidString < $1.id.uuidString
      }
    }
  }

  public func acceptTerminalInput(
    _ operation: MobileTerminalInputOperation
  ) throws -> MobileAcceptedInput {
    let accepted = try lock.withLock {
      let deviceGrant = try grant(for: operation.deviceID)
      let visibleSessionIDs = Set(
        sessions.values
          .filter { deviceGrant.canAccess($0.descriptor) }
          .map { $0.descriptor.id }
      )
      return try sequencer.accept(
        operation,
        grant: deviceGrant,
        visibleSessionIDs: visibleSessionIDs
      )
    }
    if !accepted.isDuplicate {
      let handler = lock.withLock { handlers.terminalInput }
      handler?(accepted)
    }
    return accepted
  }

  public func acceptTerminalInterrupt(
    id: UUID = UUID(),
    deviceID: UUID,
    sessionID: UUID
  ) throws -> MobileAcceptedInput {
    let accepted = try lock.withLock {
      let deviceGrant = try grant(for: deviceID)
      let visibleSessionIDs = Set(
        sessions.values
          .filter { deviceGrant.canAccess($0.descriptor) }
          .map { $0.descriptor.id }
      )
      return try sequencer.accept(
        MobileTerminalInputOperation(
          id: id,
          deviceID: deviceID,
          sessionID: sessionID,
          payload: Data([0x03])
        ),
        grant: deviceGrant,
        visibleSessionIDs: visibleSessionIDs,
        requiredScope: .signal
      )
    }
    if !accepted.isDuplicate {
      let handler = lock.withLock { handlers.terminalInput }
      handler?(accepted)
    }
    return accepted
  }

  public func acceptAgentInput(
    _ operation: MobileAgentInputOperation
  ) throws -> MobileAcceptedAgentInput {
    let (accepted, isDuplicate) = try lock.withLock {
      let grant = try grant(for: operation.deviceID)
      guard let agent = agents[operation.agentID] else {
        throw MobileHostError.sessionNotFound(operation.agentID)
      }
      let fingerprint = try Self.fingerprint(for: operation)
      if let previous = rememberedAgentOperations[operation.id] {
        guard previous.fingerprint == fingerprint else {
          throw MobileProtocolError.operationIDReuse(operation.id)
        }
        guard case .agentInput(let accepted) = previous.accepted else {
          throw MobileProtocolError.operationIDReuse(operation.id)
        }
        return (accepted, true)
      }
      let accepted = try MobileAgentInputAuthorizer.authorize(operation, agent: agent, grant: grant)
      rememberAgentOperation(
        id: operation.id,
        fingerprint: fingerprint,
        accepted: .agentInput(accepted)
      )
      return (accepted, false)
    }
    if !isDuplicate {
      let handler = lock.withLock { handlers.agentInput }
      handler?(accepted)
    }
    return accepted
  }

  public func acceptAgentLaunch(
    _ operation: MobileAgentLaunchOperation
  ) throws -> MobileAcceptedAgentLaunch {
    let (accepted, isDuplicate) = try lock.withLock {
      let deviceGrant = try grant(for: operation.deviceID)
      let fingerprint = try Self.fingerprint(for: operation)
      if let previous = rememberedAgentOperations[operation.id] {
        guard previous.fingerprint == fingerprint else {
          throw MobileProtocolError.operationIDReuse(operation.id)
        }
        guard case .agentLaunch(let accepted) = previous.accepted else {
          throw MobileProtocolError.operationIDReuse(operation.id)
        }
        return (accepted, true)
      }
      let accepted = try MobileAgentLaunchAuthorizer.authorize(
        operation,
        registeredProfiles: Set(registeredAgentProfiles.keys),
        grant: deviceGrant
      )
      rememberAgentOperation(
        id: operation.id,
        fingerprint: fingerprint,
        accepted: .agentLaunch(accepted)
      )
      return (accepted, false)
    }
    if !isDuplicate {
      let handler = lock.withLock { handlers.agentLaunch }
      handler?(accepted)
    }
    return accepted
  }

  public func acceptAgentControl(
    _ operation: MobileAgentControlOperation
  ) throws -> MobileAcceptedAgentControl {
    let (accepted, isDuplicate) = try lock.withLock {
      let grant = try grant(for: operation.deviceID)
      guard let agent = agents[operation.agentID] else {
        throw MobileHostError.sessionNotFound(operation.agentID)
      }
      let fingerprint = try Self.fingerprint(for: operation)
      if let previous = rememberedAgentOperations[operation.id] {
        guard previous.fingerprint == fingerprint else {
          throw MobileProtocolError.operationIDReuse(operation.id)
        }
        guard case .agentControl(let accepted) = previous.accepted else {
          throw MobileProtocolError.operationIDReuse(operation.id)
        }
        return (accepted, true)
      }
      let accepted = try MobileAgentControlAuthorizer.authorize(
        operation, agent: agent, grant: grant)
      rememberAgentOperation(
        id: operation.id,
        fingerprint: fingerprint,
        accepted: .agentControl(accepted)
      )
      return (accepted, false)
    }
    if !isDuplicate {
      let handler = lock.withLock { handlers.agentControl }
      handler?(accepted)
    }
    return accepted
  }

  public func subscribe(
    deviceID: UUID,
    sessionID: UUID,
    epoch requestedEpoch: UInt64?,
    cursor: UInt64,
    maximumQueueBytes: Int = MobileControlHost.defaultSubscriberQueueBytes,
    connectionID: UUID? = nil
  ) throws -> MobileSubscriptionReceipt {
    try lock.withLock {
      let grant = try grant(for: deviceID)
      guard let session = sessions[sessionID] else {
        throw MobileHostError.sessionNotFound(sessionID)
      }
      guard grant.canAccess(session.descriptor) else {
        throw MobileProtocolError.sessionNotVisible(sessionID)
      }
      guard cursor <= session.currentOffset else {
        throw MobileHostError.invalidCursor
      }
      let streamID = allocateStreamID()
      let subscriptionID = UUID()
      let events = replayEvents(
        session,
        streamID: streamID,
        requestedEpoch: requestedEpoch,
        cursor: cursor
      )
      let initialCursor = events.reduce(cursor) { current, event in
        if case .output(let frame) = event {
          return max(current, frame.startOffset &+ UInt64(frame.payload.count))
        }
        if case .gap(let gap) = event {
          return gap.endOffset
        }
        return current
      }
      subscriptions[subscriptionID] = MobileHostSubscriptionState(
        id: subscriptionID,
        deviceID: deviceID,
        connectionID: connectionID,
        sessionID: sessionID,
        streamID: streamID,
        maximumQueueBytes: max(1, maximumQueueBytes),
        events: [],
        queuedBytes: 0,
        cursor: initialCursor
      )
      return MobileSubscriptionReceipt(
        subscriptionID: subscriptionID,
        streamID: streamID,
        session: session.snapshot,
        events: events
      )
    }
  }

  public func poll(subscriptionID: UUID) throws -> [MobileHostStreamEvent] {
    try lock.withLock {
      guard let subscription = subscriptions[subscriptionID] else {
        throw MobileHostError.invalidOperation
      }
      _ = try grant(for: subscription.deviceID)
      let events = subscription.events
      subscriptions[subscriptionID]?.events.removeAll()
      subscriptions[subscriptionID]?.queuedBytes = 0
      return events
    }
  }

  public func publishOutput(
    sessionID: UUID,
    epoch: UInt64,
    data: Data,
    startOffset: UInt64? = nil,
    maximumJournalBytes: Int = MobileControlHost.defaultJournalBytes
  ) throws {
    guard !data.isEmpty else {
      throw MobileHostError.invalidOperation
    }
    try lock.withLock {
      guard var session = sessions[sessionID] else {
        throw MobileHostError.sessionNotFound(sessionID)
      }
      guard epoch == session.epoch else {
        throw MobileHostError.outputEpochMismatch
      }
      let offset = startOffset ?? session.currentOffset
      guard offset == session.currentOffset else {
        throw MobileHostError.outputOffsetDiscontinuity(
          expected: session.currentOffset,
          actual: offset
        )
      }

      var chunks: [MobileJournalChunk] = []
      var cursor = 0
      while cursor < data.count {
        let end = min(cursor + MobileTerminalFrame.defaultMaximumPayloadLength, data.count)
        chunks.append(
          MobileJournalChunk(
            offset: offset &+ UInt64(cursor),
            data: Data(data[cursor..<end])
          )
        )
        cursor = end
      }
      session.chunks.append(contentsOf: chunks)
      session.journalBytes += data.count
      session.currentOffset = offset &+ UInt64(data.count)
      trimJournal(&session, maximumBytes: maximumJournalBytes)
      sessions[sessionID] = session

      for subscriptionID in subscriptions.keys
      where subscriptions[subscriptionID]?.sessionID == sessionID {
        guard var subscription = subscriptions[subscriptionID] else { continue }
        for chunk in chunks {
          let frame = try MobileTerminalFrame(
            kind: .output,
            streamID: subscription.streamID,
            sessionEpoch: epoch,
            startOffset: chunk.offset,
            payload: chunk.data
          )
          let event = MobileHostStreamEvent.output(frame)
          enqueue(event, in: &subscription, currentOffset: session.currentOffset, epoch: epoch)
        }
        subscriptions[subscriptionID] = subscription
      }
    }
  }

  public func publishExit(sessionID: UUID, status: Int) throws {
    try lock.withLock {
      guard var session = sessions[sessionID] else {
        throw MobileHostError.sessionNotFound(sessionID)
      }
      session.isExited = true
      session.exitStatus = status
      sessions[sessionID] = session
      for subscriptionID in subscriptions.keys
      where subscriptions[subscriptionID]?.sessionID == sessionID {
        guard var subscription = subscriptions[subscriptionID] else { continue }
        enqueue(
          .exit(
            MobileTerminalExit(
              streamID: subscription.streamID,
              sessionEpoch: session.epoch,
              status: status,
              offset: session.currentOffset
            )
          ),
          in: &subscription,
          currentOffset: session.currentOffset,
          epoch: session.epoch
        )
        subscriptions[subscriptionID] = subscription
      }
    }
  }

  public func streamSnapshot(sessionID: UUID) throws -> MobileSessionStreamSnapshot {
    try lock.withLock {
      guard let session = sessions[sessionID] else {
        throw MobileHostError.sessionNotFound(sessionID)
      }
      return session.snapshot
    }
  }

  private func grant(for deviceID: UUID) throws -> MobileDeviceGrant {
    guard snapshot.isEnabled else {
      throw MobileHostError.disabled
    }
    guard let record = snapshot.devices.first(where: { $0.deviceID == deviceID }) else {
      throw MobileHostError.deviceNotFound(deviceID)
    }
    guard !record.isRevoked else {
      throw MobileHostError.revokedDevice
    }
    return record.grant()
  }

  private func validateEnabledAndDevice(_ deviceID: UUID) throws {
    _ = try grant(for: deviceID)
  }

  private func replayEvents(
    _ session: MobileHostSessionState,
    streamID: UInt32,
    requestedEpoch: UInt64?,
    cursor: UInt64
  ) -> [MobileHostStreamEvent] {
    guard requestedEpoch == nil || requestedEpoch == session.epoch else {
      return [
        .gap(
          MobileTerminalGap(
            streamID: streamID,
            sessionEpoch: session.epoch,
            startOffset: session.oldestOffset,
            endOffset: session.currentOffset
          )
        )
      ]
    }
    guard cursor >= session.oldestOffset else {
      return [
        .gap(
          MobileTerminalGap(
            streamID: streamID,
            sessionEpoch: session.epoch,
            startOffset: cursor,
            endOffset: session.oldestOffset
          )
        )
      ]
    }
    var events: [MobileHostStreamEvent] = []
    for chunk in session.chunks where chunk.endOffset > cursor {
      let trim = cursor > chunk.offset ? Int(cursor - chunk.offset) : 0
      let payload = Data(chunk.data.dropFirst(trim))
      guard !payload.isEmpty,
        let frame = try? MobileTerminalFrame(
          kind: .output,
          streamID: streamID,
          sessionEpoch: session.epoch,
          startOffset: chunk.offset &+ UInt64(trim),
          payload: payload
        )
      else {
        continue
      }
      events.append(.output(frame))
    }
    if session.isExited {
      events.append(
        .exit(
          MobileTerminalExit(
            streamID: streamID,
            sessionEpoch: session.epoch,
            status: session.exitStatus ?? 0,
            offset: session.currentOffset
          )
        )
      )
    }
    return events
  }

  private func enqueue(
    _ event: MobileHostStreamEvent,
    in subscription: inout MobileHostSubscriptionState,
    currentOffset: UInt64,
    epoch: UInt64
  ) {
    let eventBytes = event.byteCount
    if eventBytes > subscription.maximumQueueBytes
      || subscription.queuedBytes + eventBytes > subscription.maximumQueueBytes
    {
      let gap = MobileHostStreamEvent.gap(
        MobileTerminalGap(
          streamID: subscription.streamID,
          sessionEpoch: epoch,
          startOffset: subscription.cursor,
          endOffset: currentOffset
        )
      )
      subscription.events = [gap]
      subscription.queuedBytes = 0
      subscription.cursor = currentOffset
      return
    }
    subscription.events.append(event)
    subscription.queuedBytes += eventBytes
    switch event {
    case .output(let frame):
      subscription.cursor = frame.startOffset &+ UInt64(frame.payload.count)
    case .gap(let gap):
      subscription.cursor = gap.endOffset
    case .exit:
      break
    }
  }

  private func trimJournal(
    _ session: inout MobileHostSessionState,
    maximumBytes: Int
  ) {
    let limit = max(1, maximumBytes)
    while session.journalBytes > limit, !session.chunks.isEmpty {
      let removed = session.chunks.removeFirst()
      session.journalBytes -= removed.data.count
    }
  }

  private func allocateStreamID() -> UInt32 {
    defer {
      nextStreamID = nextStreamID == UInt32.max ? 1 : nextStreamID + 1
    }
    return nextStreamID == 0 ? 1 : nextStreamID
  }

  private func rememberAgentOperation(
    id: UUID,
    fingerprint: Data,
    accepted: MobileHostAcceptedOperation
  ) {
    rememberedAgentOperations[id] = MobileHostOperationRecord(
      fingerprint: fingerprint,
      accepted: accepted
    )
    rememberedAgentOperationOrder.append(id)
    while rememberedAgentOperationOrder.count > 512 {
      let evictedID = rememberedAgentOperationOrder.removeFirst()
      rememberedAgentOperations[evictedID] = nil
    }
  }

  private static func fingerprint(for hostID: UUID) -> String {
    digest(hostID.uuidString).map { String(format: "%02x", $0) }.joined()
  }

  private static func digest(_ value: String) -> Data {
    Data(SHA256.hash(data: Data(value.utf8)))
  }

  private static func fingerprint<Value: Encodable>(for value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private static func randomToken() -> String {
    base64URL(randomBytes(count: 32))
  }

  private static func randomBytes(count: Int) -> Data {
    let key = SymmetricKey(size: .bits256)
    let bytes = key.withUnsafeBytes { Data($0) }
    return count == bytes.count ? bytes : Data(bytes.prefix(count))
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func isValidEndpoint(_ endpoint: String) -> Bool {
    let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    return !value.isEmpty
      && value.utf8.count <= 2 * 1024
      && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
  }

  private static func isValidPublicKey(_ data: Data) -> Bool {
    (try? P256.Signing.PublicKey(rawRepresentation: data)) != nil
  }

  private static func isValidSignature(
    _ signature: Data,
    challenge: Data,
    publicKey: Data
  ) -> Bool {
    guard let key = try? P256.Signing.PublicKey(rawRepresentation: publicKey),
      let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature)
    else {
      return false
    }
    return key.isValidSignature(signature, for: challenge)
  }
}

extension NSLock {
  fileprivate func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock()
    defer { unlock() }
    return try body()
  }
}

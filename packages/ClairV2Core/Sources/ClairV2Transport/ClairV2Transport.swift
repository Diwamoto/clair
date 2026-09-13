import ClairV2Shared
import Foundation

public enum ClairTransportError: Error, Equatable, LocalizedError, Sendable {
  case invalidIdentifier
  case invalidDisplayName
  case invalidEndpoint
  case invalidTimestamp
  case invalidSecret
  case invalidToken
  case invalidDeviceKey
  case invalidHostKey
  case invalidSignature
  case invalidFingerprint
  case invalidPairingLink
  case invalidChallenge
  case invalidGrant
  case invalidProtocolOffer
  case invalidConnection
  case pairingUnavailable
  case pairingExpired
  case pairingConsumed
  case userConfirmationRequired
  case hostIdentityMismatch
  case authenticationFailed
  case deviceNotFound
  case deviceRevoked
  case credentialExpired
  case grantLimitReached
  case challengeLimitReached
  case connectionLimitReached
  case generationMismatch
  case challengeExpired
  case challengeConsumed
  case challengeMismatch
  case connectionClosed
  case notPaired
  case protocolFailure(ProtocolError)

  public var errorDescription: String? {
    switch self {
    case .invalidIdentifier:
      "The transport identity is invalid."
    case .invalidDisplayName:
      "The device display name is invalid."
    case .invalidEndpoint:
      "The transport endpoint is invalid."
    case .invalidTimestamp:
      "The transport timestamp is invalid."
    case .invalidSecret:
      "The pairing secret is invalid."
    case .invalidToken:
      "The device token is invalid."
    case .invalidDeviceKey:
      "The device key is invalid."
    case .invalidHostKey:
      "The host key is invalid."
    case .invalidSignature:
      "The device signature is invalid."
    case .invalidFingerprint:
      "The host fingerprint is invalid."
    case .invalidPairingLink:
      "The pairing link is invalid."
    case .invalidChallenge:
      "The authentication challenge is invalid."
    case .invalidGrant:
      "The device grant is invalid."
    case .invalidProtocolOffer:
      "The protocol offer is invalid or exceeds its bounds."
    case .invalidConnection:
      "The authenticated connection is invalid."
    case .pairingUnavailable:
      "The pairing link is not available."
    case .pairingExpired:
      "The pairing link has expired."
    case .pairingConsumed:
      "The pairing link has already been consumed."
    case .userConfirmationRequired:
      "The host fingerprint must be explicitly confirmed."
    case .hostIdentityMismatch:
      "The presented host identity does not match the pinned identity."
    case .authenticationFailed:
      "Device authentication failed."
    case .deviceNotFound:
      "The device grant was not found."
    case .deviceRevoked:
      "The device grant has been revoked."
    case .credentialExpired:
      "The device credential has expired."
    case .grantLimitReached:
      "The host cannot accept another device grant."
    case .challengeLimitReached:
      "The host cannot accept another authentication challenge."
    case .connectionLimitReached:
      "The host cannot accept another authenticated connection."
    case .generationMismatch:
      "The device grant generation is stale."
    case .challengeExpired:
      "The authentication challenge has expired."
    case .challengeConsumed:
      "The authentication challenge has already been consumed."
    case .challengeMismatch:
      "The authentication challenge does not match the connection."
    case .connectionClosed:
      "The authenticated connection is closed."
    case .notPaired:
      "The client has not been paired."
    case .protocolFailure(let error):
      error.localizedDescription
    }
  }
}

public protocol ClairTransportClock: Sendable {
  func now() -> Date
}

public struct ClairSystemTransportClock: ClairTransportClock {
  public init() {}

  public func now() -> Date { Date() }
}

public struct ClairTransportEndpoint: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let value: String

  private enum CodingKeys: String, CodingKey {
    case value
  }

  public init(_ value: String) throws {
    guard value.utf8.count > 0,
      value.utf8.count <= ClairTransportValidation.maximumEndpointBytes,
      value.unicodeScalars.allSatisfy({ scalar in
        scalar.value >= 0x21 && scalar.value != 0x7F
      }),
      let components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(),
      ["https", "wss", "tls", "tcp"].contains(scheme),
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      throw ClairTransportError.invalidEndpoint
    }
    self.value = value
  }

  public var description: String { value }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(container.decode(String.self, forKey: .value))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(value, forKey: .value)
  }
}

public struct ClairHostIdentity: Codable, Equatable, Hashable, Sendable {
  public let hostID: ClairHostID
  public let publicKey: ClairHostPublicKey
  public let fingerprint: ClairHostFingerprint

  private enum CodingKeys: String, CodingKey {
    case hostID
    case publicKey
    case fingerprint
  }

  public init(hostID: ClairHostID, publicKey: ClairHostPublicKey) throws {
    let fingerprint = publicKey.fingerprint
    self.hostID = hostID
    self.publicKey = publicKey
    self.fingerprint = fingerprint
  }

  public init(
    hostID: ClairHostID,
    publicKey: ClairHostPublicKey,
    fingerprint: ClairHostFingerprint
  ) throws {
    guard publicKey.fingerprint == fingerprint else {
      throw ClairTransportError.hostIdentityMismatch
    }
    self.hostID = hostID
    self.publicKey = publicKey
    self.fingerprint = fingerprint
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      hostID: container.decode(ClairHostID.self, forKey: .hostID),
      publicKey: container.decode(ClairHostPublicKey.self, forKey: .publicKey),
      fingerprint: container.decode(ClairHostFingerprint.self, forKey: .fingerprint)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hostID, forKey: .hostID)
    try container.encode(publicKey, forKey: .publicKey)
    try container.encode(fingerprint, forKey: .fingerprint)
  }
}

public struct ClairHostPresentation: Codable, Equatable, Sendable {
  public let hostID: ClairHostID
  public let publicKey: ClairHostPublicKey
  public let fingerprint: ClairHostFingerprint
  public let endpoint: ClairTransportEndpoint
  public let protocolOffer: ProtocolOffer

  private enum CodingKeys: String, CodingKey {
    case hostID
    case publicKey
    case fingerprint
    case endpoint
    case protocolOffer
  }

  public init(
    hostID: ClairHostID,
    publicKey: ClairHostPublicKey,
    fingerprint: ClairHostFingerprint,
    endpoint: ClairTransportEndpoint,
    protocolOffer: ProtocolOffer
  ) throws {
    guard publicKey.fingerprint == fingerprint else {
      throw ClairTransportError.hostIdentityMismatch
    }
    self.hostID = hostID
    self.publicKey = publicKey
    self.fingerprint = fingerprint
    self.endpoint = endpoint
    self.protocolOffer = protocolOffer
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      hostID: container.decode(ClairHostID.self, forKey: .hostID),
      publicKey: container.decode(ClairHostPublicKey.self, forKey: .publicKey),
      fingerprint: container.decode(ClairHostFingerprint.self, forKey: .fingerprint),
      endpoint: container.decode(ClairTransportEndpoint.self, forKey: .endpoint),
      protocolOffer: try ClairTransportValidation.decodeProtocolOffer(
        from: container,
        forKey: .protocolOffer
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hostID, forKey: .hostID)
    try container.encode(publicKey, forKey: .publicKey)
    try container.encode(fingerprint, forKey: .fingerprint)
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(protocolOffer, forKey: .protocolOffer)
  }
}

public struct ClairPairingLink: Codable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let pairingID: ClairPairingID
  public let hostID: ClairHostID
  public let endpoint: ClairTransportEndpoint
  public let hostFingerprint: ClairHostFingerprint
  public let protocolOffer: ProtocolOffer
  public let bootstrapSecret: ClairBootstrapSecret
  public let expiresAt: Date

  private enum CodingKeys: String, CodingKey {
    case pairingID
    case hostID
    case endpoint
    case hostFingerprint
    case protocolOffer
    case bootstrapSecret
    case expiresAt
  }

  public init(
    pairingID: ClairPairingID,
    hostID: ClairHostID,
    endpoint: ClairTransportEndpoint,
    hostFingerprint: ClairHostFingerprint,
    protocolOffer: ProtocolOffer,
    bootstrapSecret: ClairBootstrapSecret,
    expiresAt: Date
  ) throws {
    try ClairTransportValidation.validateDate(expiresAt)
    self.pairingID = pairingID
    self.hostID = hostID
    self.endpoint = endpoint
    self.hostFingerprint = hostFingerprint
    self.protocolOffer = protocolOffer
    self.bootstrapSecret = bootstrapSecret
    self.expiresAt = expiresAt
  }

  public func isExpired(at date: Date) -> Bool { date >= expiresAt }

  public var description: String {
    "ClairPairingLink(pairingID: \(pairingID), hostID: \(hostID), endpoint: \(endpoint), fingerprint: \(hostFingerprint), expiresAt: \(expiresAt))"
  }

  public var debugDescription: String { description }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      pairingID: container.decode(ClairPairingID.self, forKey: .pairingID),
      hostID: container.decode(ClairHostID.self, forKey: .hostID),
      endpoint: container.decode(ClairTransportEndpoint.self, forKey: .endpoint),
      hostFingerprint: container.decode(
        ClairHostFingerprint.self,
        forKey: .hostFingerprint
      ),
      protocolOffer: ClairTransportValidation.decodeProtocolOffer(
        from: container,
        forKey: .protocolOffer
      ),
      bootstrapSecret: container.decode(
        ClairBootstrapSecret.self,
        forKey: .bootstrapSecret
      ),
      expiresAt: container.decode(Date.self, forKey: .expiresAt)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(pairingID, forKey: .pairingID)
    try container.encode(hostID, forKey: .hostID)
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(hostFingerprint, forKey: .hostFingerprint)
    try container.encode(protocolOffer, forKey: .protocolOffer)
    try container.encode(bootstrapSecret, forKey: .bootstrapSecret)
    try container.encode(expiresAt, forKey: .expiresAt)
  }
}

public struct ClairDeviceGrant: Codable, Equatable, Hashable, Sendable {
  public let hostID: ClairHostID
  public let deviceID: ClairDeviceID
  public let devicePublicKey: ClairDevicePublicKey
  public let displayName: String
  public let generation: UInt64
  public let capabilities: CapabilitySet
  public let visibleScopes: [ResourceScope]
  public let createdAt: Date
  public let tokenExpiresAt: Date
  public let lastUsedAt: Date?
  public let revokedAt: Date?

  private enum CodingKeys: String, CodingKey {
    case hostID
    case deviceID
    case devicePublicKey
    case displayName
    case generation
    case capabilities
    case visibleScopes
    case createdAt
    case tokenExpiresAt
    case lastUsedAt
    case revokedAt
  }

  public init(
    hostID: ClairHostID,
    deviceID: ClairDeviceID,
    devicePublicKey: ClairDevicePublicKey,
    displayName: String,
    generation: UInt64 = 1,
    capabilities: CapabilitySet,
    visibleScopes: [ResourceScope],
    createdAt: Date,
    tokenExpiresAt: Date,
    lastUsedAt: Date? = nil,
    revokedAt: Date? = nil
  ) throws {
    guard generation > 0 else { throw ClairTransportError.invalidGrant }
    try ClairTransportValidation.validateDisplayName(displayName)
    try ClairTransportValidation.validateDate(createdAt)
    try ClairTransportValidation.validateDate(tokenExpiresAt)
    guard tokenExpiresAt > createdAt else { throw ClairTransportError.invalidGrant }
    if let lastUsedAt {
      try ClairTransportValidation.validateDate(lastUsedAt)
    }
    if let revokedAt {
      try ClairTransportValidation.validateDate(revokedAt)
    }
    guard visibleScopes.count <= ClairTransportValidation.maximumVisibleScopes else {
      throw ClairTransportError.invalidGrant
    }
    do {
      _ = try AccessBoundary(
        capabilities: capabilities,
        visibleScopes: visibleScopes
      )
    } catch {
      throw ClairTransportError.invalidGrant
    }
    self.hostID = hostID
    self.deviceID = deviceID
    self.devicePublicKey = devicePublicKey
    self.displayName = displayName
    self.generation = generation
    self.capabilities = capabilities
    self.visibleScopes = visibleScopes
    self.createdAt = createdAt
    self.tokenExpiresAt = tokenExpiresAt
    self.lastUsedAt = lastUsedAt
    self.revokedAt = revokedAt
  }

  public var isRevoked: Bool { revokedAt != nil }
  public func isTokenExpired(at date: Date) -> Bool { date >= tokenExpiresAt }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      hostID: container.decode(ClairHostID.self, forKey: .hostID),
      deviceID: container.decode(ClairDeviceID.self, forKey: .deviceID),
      devicePublicKey: container.decode(
        ClairDevicePublicKey.self,
        forKey: .devicePublicKey
      ),
      displayName: container.decode(String.self, forKey: .displayName),
      generation: container.decode(UInt64.self, forKey: .generation),
      capabilities: try ClairTransportValidation.decodeCapabilitySet(
        from: container,
        forKey: .capabilities,
        error: .invalidGrant
      ),
      visibleScopes: try ClairTransportValidation.decodeLimitedArray(
        ResourceScope.self,
        from: container,
        forKey: .visibleScopes,
        maximum: ClairTransportValidation.maximumVisibleScopes,
        error: .invalidGrant
      ),
      createdAt: container.decode(Date.self, forKey: .createdAt),
      tokenExpiresAt: container.decode(Date.self, forKey: .tokenExpiresAt),
      lastUsedAt: container.decodeIfPresent(Date.self, forKey: .lastUsedAt),
      revokedAt: container.decodeIfPresent(Date.self, forKey: .revokedAt)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hostID, forKey: .hostID)
    try container.encode(deviceID, forKey: .deviceID)
    try container.encode(devicePublicKey, forKey: .devicePublicKey)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(generation, forKey: .generation)
    try container.encode(capabilities, forKey: .capabilities)
    try container.encode(visibleScopes, forKey: .visibleScopes)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(tokenExpiresAt, forKey: .tokenExpiresAt)
    try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
    try container.encodeIfPresent(revokedAt, forKey: .revokedAt)
  }
}

/// Returned exactly at pairing time. The token is intentionally not part of
/// `ClairDeviceGrant`, which is safe to show in a device-management list.
public struct ClairDeviceCredential: Codable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let grant: ClairDeviceGrant
  public let token: ClairDeviceToken

  private enum CodingKeys: String, CodingKey {
    case grant
    case token
  }

  public init(grant: ClairDeviceGrant, token: ClairDeviceToken) {
    self.grant = grant
    self.token = token
  }

  public var description: String {
    "ClairDeviceCredential(deviceID: \(grant.deviceID), generation: \(grant.generation), token: <redacted>)"
  }

  public var debugDescription: String { description }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.grant = try container.decode(ClairDeviceGrant.self, forKey: .grant)
    self.token = try container.decode(ClairDeviceToken.self, forKey: .token)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(grant, forKey: .grant)
    try container.encode(token, forKey: .token)
  }
}

public struct ClairPairingRequest: Codable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let pairingID: ClairPairingID
  public let hostID: ClairHostID
  public let hostFingerprint: ClairHostFingerprint
  public let bootstrapSecret: ClairBootstrapSecret
  public let devicePublicKey: ClairDevicePublicKey
  public let displayName: String
  public let clientOffer: ProtocolOffer
  public let confirmedHostFingerprint: Bool

  private enum CodingKeys: String, CodingKey {
    case pairingID
    case hostID
    case hostFingerprint
    case bootstrapSecret
    case devicePublicKey
    case displayName
    case clientOffer
    case confirmedHostFingerprint
  }

  public init(
    link: ClairPairingLink,
    devicePublicKey: ClairDevicePublicKey,
    displayName: String,
    clientOffer: ProtocolOffer = .current,
    confirmedHostFingerprint: Bool
  ) {
    self.pairingID = link.pairingID
    self.hostID = link.hostID
    self.hostFingerprint = link.hostFingerprint
    self.bootstrapSecret = link.bootstrapSecret
    self.devicePublicKey = devicePublicKey
    self.displayName = displayName
    self.clientOffer = clientOffer
    self.confirmedHostFingerprint = confirmedHostFingerprint
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let displayName = try container.decode(String.self, forKey: .displayName)
    try ClairTransportValidation.validateDisplayName(displayName)
    self.pairingID = try container.decode(ClairPairingID.self, forKey: .pairingID)
    self.hostID = try container.decode(ClairHostID.self, forKey: .hostID)
    self.hostFingerprint = try container.decode(
      ClairHostFingerprint.self,
      forKey: .hostFingerprint
    )
    self.bootstrapSecret = try container.decode(
      ClairBootstrapSecret.self,
      forKey: .bootstrapSecret
    )
    self.devicePublicKey = try container.decode(
      ClairDevicePublicKey.self,
      forKey: .devicePublicKey
    )
    self.displayName = displayName
    self.clientOffer = try ClairTransportValidation.decodeProtocolOffer(
      from: container,
      forKey: .clientOffer
    )
    self.confirmedHostFingerprint = try container.decode(
      Bool.self,
      forKey: .confirmedHostFingerprint
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(pairingID, forKey: .pairingID)
    try container.encode(hostID, forKey: .hostID)
    try container.encode(hostFingerprint, forKey: .hostFingerprint)
    try container.encode(bootstrapSecret, forKey: .bootstrapSecret)
    try container.encode(devicePublicKey, forKey: .devicePublicKey)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(clientOffer, forKey: .clientOffer)
    try container.encode(confirmedHostFingerprint, forKey: .confirmedHostFingerprint)
  }

  public var description: String {
    "ClairPairingRequest(pairingID: \(pairingID), hostID: \(hostID), devicePublicKey: <public-key>, confirmedHostFingerprint: \(confirmedHostFingerprint))"
  }

  public var debugDescription: String { description }
}

public struct ClairPairingResult: Codable, Equatable, Sendable {
  public let host: ClairHostIdentity
  public let endpoint: ClairTransportEndpoint
  public let negotiatedProtocol: NegotiatedProtocol
  public let credential: ClairDeviceCredential

  private enum CodingKeys: String, CodingKey {
    case host
    case endpoint
    case negotiatedProtocol
    case credential
  }

  public init(
    host: ClairHostIdentity,
    endpoint: ClairTransportEndpoint,
    negotiatedProtocol: NegotiatedProtocol,
    credential: ClairDeviceCredential
  ) {
    self.host = host
    self.endpoint = endpoint
    self.negotiatedProtocol = negotiatedProtocol
    self.credential = credential
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.host = try container.decode(ClairHostIdentity.self, forKey: .host)
    self.endpoint = try container.decode(ClairTransportEndpoint.self, forKey: .endpoint)
    self.negotiatedProtocol = try ClairTransportValidation.decodeNegotiatedProtocol(
      from: container,
      forKey: .negotiatedProtocol
    )
    self.credential = try container.decode(
      ClairDeviceCredential.self,
      forKey: .credential
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(host, forKey: .host)
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(negotiatedProtocol, forKey: .negotiatedProtocol)
    try container.encode(credential, forKey: .credential)
  }
}

public struct ClairReconnectRequest: Codable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let hostID: ClairHostID
  public let hostFingerprint: ClairHostFingerprint
  public let deviceID: ClairDeviceID
  public let token: ClairDeviceToken
  public let clientOffer: ProtocolOffer
  public let resourceScope: ResourceScope?

  private enum CodingKeys: String, CodingKey {
    case hostID
    case hostFingerprint
    case deviceID
    case token
    case clientOffer
    case resourceScope
  }

  public init(
    hostID: ClairHostID,
    hostFingerprint: ClairHostFingerprint,
    deviceID: ClairDeviceID,
    token: ClairDeviceToken,
    clientOffer: ProtocolOffer = .current,
    resourceScope: ResourceScope? = nil
  ) {
    self.hostID = hostID
    self.hostFingerprint = hostFingerprint
    self.deviceID = deviceID
    self.token = token
    self.clientOffer = clientOffer
    self.resourceScope = resourceScope
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.hostID = try container.decode(ClairHostID.self, forKey: .hostID)
    self.hostFingerprint = try container.decode(
      ClairHostFingerprint.self,
      forKey: .hostFingerprint
    )
    self.deviceID = try container.decode(ClairDeviceID.self, forKey: .deviceID)
    self.token = try container.decode(ClairDeviceToken.self, forKey: .token)
    self.clientOffer = try ClairTransportValidation.decodeProtocolOffer(
      from: container,
      forKey: .clientOffer
    )
    self.resourceScope = try container.decodeIfPresent(
      ResourceScope.self,
      forKey: .resourceScope
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hostID, forKey: .hostID)
    try container.encode(hostFingerprint, forKey: .hostFingerprint)
    try container.encode(deviceID, forKey: .deviceID)
    try container.encode(token, forKey: .token)
    try container.encode(clientOffer, forKey: .clientOffer)
    try container.encodeIfPresent(resourceScope, forKey: .resourceScope)
  }

  public var description: String {
    "ClairReconnectRequest(hostID: \(hostID), deviceID: \(deviceID), token: <redacted>)"
  }

  public var debugDescription: String { description }
}

public struct ClairChallenge: Codable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let challengeID: ClairChallengeID
  public let connectionID: ClairConnectionID
  public let hostID: ClairHostID
  public let hostFingerprint: ClairHostFingerprint
  public let deviceID: ClairDeviceID
  public let generation: UInt64
  public let nonce: Data
  public let expiresAt: Date
  public let negotiatedProtocol: NegotiatedProtocol
  public let resourceScope: ResourceScope?

  private enum CodingKeys: String, CodingKey {
    case challengeID
    case connectionID
    case hostID
    case hostFingerprint
    case deviceID
    case generation
    case nonce
    case expiresAt
    case negotiatedProtocol
    case resourceScope
  }

  init(
    challengeID: ClairChallengeID,
    connectionID: ClairConnectionID,
    hostID: ClairHostID,
    hostFingerprint: ClairHostFingerprint,
    deviceID: ClairDeviceID,
    generation: UInt64,
    nonce: Data,
    expiresAt: Date,
    negotiatedProtocol: NegotiatedProtocol,
    resourceScope: ResourceScope? = nil
  ) throws {
    guard generation > 0, nonce.count == ClairTransportValidation.secretBytes else {
      throw ClairTransportError.invalidChallenge
    }
    try ClairTransportValidation.validateDate(expiresAt)
    _ = try ClairTransportValidation.timestampMilliseconds(expiresAt)
    self.challengeID = challengeID
    self.connectionID = connectionID
    self.hostID = hostID
    self.hostFingerprint = hostFingerprint
    self.deviceID = deviceID
    self.generation = generation
    self.nonce = nonce
    self.expiresAt = expiresAt
    self.negotiatedProtocol = negotiatedProtocol
    self.resourceScope = resourceScope
  }

  public func makeProof(using deviceKey: ClairDeviceKey) throws -> ClairChallengeProof {
    let signature = try deviceKey.sign(try signingBytes())
    return try ClairChallengeProof(
      challengeID: challengeID,
      connectionID: connectionID,
      hostID: hostID,
      deviceID: deviceID,
      generation: generation,
      signature: signature,
      resourceScope: resourceScope
    )
  }

  func signingBytes() throws -> Data {
    try ProtocolCodec.encode(
      ClairChallengeSigningPayload(
        challengeID: challengeID,
        connectionID: connectionID,
        hostID: hostID,
        hostFingerprint: hostFingerprint,
        deviceID: deviceID,
        generation: generation,
        nonce: nonce,
        expiresAtMilliseconds: try ClairTransportValidation.timestampMilliseconds(expiresAt),
        resourceScope: resourceScope
      )
    )
  }

  public var description: String {
    "ClairChallenge(challengeID: \(challengeID), connectionID: \(connectionID), hostID: \(hostID), deviceID: \(deviceID), generation: \(generation), expiresAt: \(expiresAt))"
  }

  public var debugDescription: String { description }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      challengeID: container.decode(ClairChallengeID.self, forKey: .challengeID),
      connectionID: container.decode(ClairConnectionID.self, forKey: .connectionID),
      hostID: container.decode(ClairHostID.self, forKey: .hostID),
      hostFingerprint: container.decode(
        ClairHostFingerprint.self,
        forKey: .hostFingerprint
      ),
      deviceID: container.decode(ClairDeviceID.self, forKey: .deviceID),
      generation: container.decode(UInt64.self, forKey: .generation),
      nonce: ClairTransportValidation.decodeBoundedData(
        from: container,
        forKey: .nonce,
        maximum: ClairTransportValidation.secretBytes,
        error: .invalidChallenge
      ),
      expiresAt: container.decode(Date.self, forKey: .expiresAt),
      negotiatedProtocol: ClairTransportValidation.decodeNegotiatedProtocol(
        from: container,
        forKey: .negotiatedProtocol
      ),
      resourceScope: container.decodeIfPresent(ResourceScope.self, forKey: .resourceScope)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(challengeID, forKey: .challengeID)
    try container.encode(connectionID, forKey: .connectionID)
    try container.encode(hostID, forKey: .hostID)
    try container.encode(hostFingerprint, forKey: .hostFingerprint)
    try container.encode(deviceID, forKey: .deviceID)
    try container.encode(generation, forKey: .generation)
    try container.encode(nonce, forKey: .nonce)
    try container.encode(expiresAt, forKey: .expiresAt)
    try container.encode(negotiatedProtocol, forKey: .negotiatedProtocol)
    try container.encodeIfPresent(resourceScope, forKey: .resourceScope)
  }
}

public struct ClairChallengeProof: Codable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let challengeID: ClairChallengeID
  public let connectionID: ClairConnectionID
  public let hostID: ClairHostID
  public let deviceID: ClairDeviceID
  public let generation: UInt64
  public let signature: Data
  public let resourceScope: ResourceScope?

  private enum CodingKeys: String, CodingKey {
    case challengeID
    case connectionID
    case hostID
    case deviceID
    case generation
    case signature
    case resourceScope
  }

  public init(
    challengeID: ClairChallengeID,
    connectionID: ClairConnectionID,
    hostID: ClairHostID,
    deviceID: ClairDeviceID,
    generation: UInt64,
    signature: Data,
    resourceScope: ResourceScope? = nil
  ) throws {
    guard generation > 0, signature.count == ClairTransportValidation.signatureBytes else {
      throw ClairTransportError.invalidSignature
    }
    self.challengeID = challengeID
    self.connectionID = connectionID
    self.hostID = hostID
    self.deviceID = deviceID
    self.generation = generation
    self.signature = signature
    self.resourceScope = resourceScope
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      challengeID: container.decode(ClairChallengeID.self, forKey: .challengeID),
      connectionID: container.decode(ClairConnectionID.self, forKey: .connectionID),
      hostID: container.decode(ClairHostID.self, forKey: .hostID),
      deviceID: container.decode(ClairDeviceID.self, forKey: .deviceID),
      generation: container.decode(UInt64.self, forKey: .generation),
      signature: ClairTransportValidation.decodeBoundedData(
        from: container,
        forKey: .signature,
        maximum: ClairTransportValidation.signatureBytes,
        error: .invalidSignature
      ),
      resourceScope: container.decodeIfPresent(ResourceScope.self, forKey: .resourceScope)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(challengeID, forKey: .challengeID)
    try container.encode(connectionID, forKey: .connectionID)
    try container.encode(hostID, forKey: .hostID)
    try container.encode(deviceID, forKey: .deviceID)
    try container.encode(generation, forKey: .generation)
    try container.encode(signature, forKey: .signature)
    try container.encodeIfPresent(resourceScope, forKey: .resourceScope)
  }

  public var description: String {
    "ClairChallengeProof(challengeID: \(challengeID), connectionID: \(connectionID), hostID: \(hostID), deviceID: \(deviceID), generation: \(generation), signature: <redacted>)"
  }

  public var debugDescription: String { description }
}

/// Wire-safe connection metadata. It is a DTO only; possession of this value
/// never grants authority to close or use a live connection.
public struct ClairConnectionInfo: Codable, Equatable, Sendable {
  public let connectionID: ClairConnectionID
  public let hostID: ClairHostID
  public let deviceID: ClairDeviceID
  public let generation: UInt64
  public let negotiatedProtocol: NegotiatedProtocol
  public let resourceScope: ResourceScope?

  private enum CodingKeys: String, CodingKey {
    case connectionID
    case hostID
    case deviceID
    case generation
    case negotiatedProtocol
    case resourceScope
  }

  public init(
    connectionID: ClairConnectionID,
    hostID: ClairHostID,
    deviceID: ClairDeviceID,
    generation: UInt64,
    negotiatedProtocol: NegotiatedProtocol,
    resourceScope: ResourceScope? = nil
  ) throws {
    guard generation > 0 else { throw ClairTransportError.invalidConnection }
    self.connectionID = connectionID
    self.hostID = hostID
    self.deviceID = deviceID
    self.generation = generation
    self.negotiatedProtocol = negotiatedProtocol
    self.resourceScope = resourceScope
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      connectionID: container.decode(ClairConnectionID.self, forKey: .connectionID),
      hostID: container.decode(ClairHostID.self, forKey: .hostID),
      deviceID: container.decode(ClairDeviceID.self, forKey: .deviceID),
      generation: container.decode(UInt64.self, forKey: .generation),
      negotiatedProtocol: ClairTransportValidation.decodeNegotiatedProtocol(
        from: container,
        forKey: .negotiatedProtocol
      ),
      resourceScope: container.decodeIfPresent(ResourceScope.self, forKey: .resourceScope)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(connectionID, forKey: .connectionID)
    try container.encode(hostID, forKey: .hostID)
    try container.encode(deviceID, forKey: .deviceID)
    try container.encode(generation, forKey: .generation)
    try container.encode(negotiatedProtocol, forKey: .negotiatedProtocol)
    try container.encodeIfPresent(resourceScope, forKey: .resourceScope)
  }
}

private struct ClairConnectionHandle: Equatable, Sendable {
  let nonce: Data

  init() {
    self.nonce = ClairTransportValidation.randomBytes(count: ClairTransportValidation.secretBytes)
  }
}

/// A live authenticated capability. The private handle is deliberately not
/// Codable or constructible from wire metadata; the authority compares it
/// before accepting close or authorization requests.
public struct ClairAuthenticatedConnection: Equatable, Sendable {
  public let info: ClairConnectionInfo
  private let handle: ClairConnectionHandle

  init(info: ClairConnectionInfo) {
    self.info = info
    self.handle = ClairConnectionHandle()
  }

  init(
    connectionID: ClairConnectionID,
    hostID: ClairHostID,
    deviceID: ClairDeviceID,
    generation: UInt64,
    negotiatedProtocol: NegotiatedProtocol,
    resourceScope: ResourceScope? = nil
  ) {
    self.info = try! ClairConnectionInfo(
      connectionID: connectionID,
      hostID: hostID,
      deviceID: deviceID,
      generation: generation,
      negotiatedProtocol: negotiatedProtocol,
      resourceScope: resourceScope
    )
    self.handle = ClairConnectionHandle()
  }

  public var connectionID: ClairConnectionID { info.connectionID }
  public var hostID: ClairHostID { info.hostID }
  public var deviceID: ClairDeviceID { info.deviceID }
  public var generation: UInt64 { info.generation }
  public var negotiatedProtocol: NegotiatedProtocol { info.negotiatedProtocol }
  public var resourceScope: ResourceScope? { info.resourceScope }
}

public struct ClairRevocation: Codable, Equatable, Sendable {
  public let deviceID: ClairDeviceID
  public let previousGeneration: UInt64
  public let newGeneration: UInt64
  public let closedConnectionIDs: [ClairConnectionID]
  public let revokedAt: Date

  private enum CodingKeys: String, CodingKey {
    case deviceID
    case previousGeneration
    case newGeneration
    case closedConnectionIDs
    case revokedAt
  }

  init(
    deviceID: ClairDeviceID,
    previousGeneration: UInt64,
    newGeneration: UInt64,
    closedConnectionIDs: [ClairConnectionID],
    revokedAt: Date
  ) {
    self.deviceID = deviceID
    self.previousGeneration = previousGeneration
    self.newGeneration = newGeneration
    self.closedConnectionIDs = closedConnectionIDs
    self.revokedAt = revokedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let previousGeneration = try container.decode(
      UInt64.self,
      forKey: .previousGeneration
    )
    let newGeneration = try container.decode(UInt64.self, forKey: .newGeneration)
    guard previousGeneration > 0, newGeneration > previousGeneration else {
      throw ClairTransportError.invalidGrant
    }
    let revokedAt = try container.decode(Date.self, forKey: .revokedAt)
    try ClairTransportValidation.validateDate(revokedAt)
    self.init(
      deviceID: try container.decode(ClairDeviceID.self, forKey: .deviceID),
      previousGeneration: previousGeneration,
      newGeneration: newGeneration,
      closedConnectionIDs: try ClairTransportValidation.decodeLimitedArray(
        ClairConnectionID.self,
        from: container,
        forKey: .closedConnectionIDs,
        maximum: ClairTransportValidation.maximumActiveConnections,
        error: .invalidGrant
      ),
      revokedAt: revokedAt
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(deviceID, forKey: .deviceID)
    try container.encode(previousGeneration, forKey: .previousGeneration)
    try container.encode(newGeneration, forKey: .newGeneration)
    try container.encode(closedConnectionIDs, forKey: .closedConnectionIDs)
    try container.encode(revokedAt, forKey: .revokedAt)
  }
}

/// A future Network.framework/TLS adapter implements this bounded message
/// channel. Authentication and authorization remain owned by the authority,
/// not by the channel or the network route.
public protocol ClairNativeTransportChannel: Sendable {
  func send(_ frame: Data) async throws
  func receive() async throws -> Data
  func close() async
}

private struct ClairChallengeSigningPayload: Encodable {
  let domain = "clair-v2-device-challenge-v1"
  let challengeID: ClairChallengeID
  let connectionID: ClairConnectionID
  let hostID: ClairHostID
  let hostFingerprint: ClairHostFingerprint
  let deviceID: ClairDeviceID
  let generation: UInt64
  let nonce: Data
  let expiresAtMilliseconds: Int64
  let resourceScope: ResourceScope?

  private enum CodingKeys: String, CodingKey {
    case domain
    case challengeID = "challenge_id"
    case connectionID = "connection_id"
    case hostID = "host_id"
    case hostFingerprint = "host_fingerprint"
    case deviceID = "device_id"
    case generation
    case nonce
    case expiresAtMilliseconds = "expires_at_ms"
    case resourceScope = "resource_scope"
  }
}

public enum ClairNativeTransportCodec {
  public static func encodeFrame<T: Encodable>(
    _ value: T,
    limits: FrameLimits = .standard
  ) throws -> Data {
    do {
      return try ProtocolCodec.encodeFrame(value, limits: limits)
    } catch let error as ProtocolError {
      throw ClairTransportError.protocolFailure(error)
    }
  }

  public static func decodeFrame<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    limits: FrameLimits = .standard
  ) throws -> T {
    do {
      return try ProtocolCodec.decodeFrame(type, from: data, limits: limits)
    } catch let error as ProtocolError {
      throw ClairTransportError.protocolFailure(error)
    }
  }
}

/// The typed hand-off from H03 authorization to H06 dispatch. H03 issues and
/// revalidates this ticket; H06 must perform effect/dispatch linearization
/// immediately after validation in its own actor.
public struct ClairAuthorizationTicket<Payload: Codable & Sendable>: Sendable {
  public let operation: OperationRequest<Payload>
  public let receipt: OperationReceipt
  public let connection: ClairConnectionInfo
  public let deviceID: ClairDeviceID
  public let connectionID: ClairConnectionID
  public let generation: UInt64

  init(
    operation: OperationRequest<Payload>,
    receipt: OperationReceipt,
    connection: ClairConnectionInfo
  ) {
    self.operation = operation
    self.receipt = receipt
    self.connection = connection
    self.deviceID = connection.deviceID
    self.connectionID = connection.connectionID
    self.generation = connection.generation
  }
}

/// Host-side pairing authority and the transport-neutral server security seam.
/// The actor is the revocation/authorization linearization point.
public actor ClairPairingAuthority {
  public let hostIdentity: ClairHostIdentity
  public let endpoint: ClairTransportEndpoint
  public let protocolOffer: ProtocolOffer

  private let clock: any ClairTransportClock
  private let challengeLifetime: TimeInterval
  private let tokenLifetime: TimeInterval
  private let defaultVisibleScopes: [ResourceScope]
  private var currentPairing: PairingState?
  private var grants: [ClairDeviceID: StoredGrant] = [:]
  private var challenges: [ClairChallengeID: PendingChallenge] = [:]
  private var connections: [ClairConnectionID: ClairAuthenticatedConnection] = [:]

  private struct PairingState {
    let link: ClairPairingLink
    let consumed: Bool
  }

  private struct StoredGrant {
    var grant: ClairDeviceGrant
    let tokenDigest: Data
    var operationLedger: OperationLedger
    var activeConnections: Set<ClairConnectionID>
  }

  private struct PendingChallenge {
    let challenge: ClairChallenge
    let devicePublicKey: ClairDevicePublicKey
    let tokenDigest: Data
  }

  public init(
    hostID: ClairHostID,
    endpoint: ClairTransportEndpoint,
    hostKey: ClairHostSigningKey = ClairHostSigningKey(),
    protocolOffer: ProtocolOffer = .current,
    defaultVisibleScopes: [ResourceScope] = [],
    challengeLifetime: TimeInterval = 30,
    tokenLifetime: TimeInterval = 30 * 24 * 60 * 60,
    clock: any ClairTransportClock = ClairSystemTransportClock()
  ) throws {
    guard challengeLifetime > 0, challengeLifetime.isFinite, challengeLifetime <= 300 else {
      throw ClairTransportError.invalidChallenge
    }
    guard tokenLifetime > 0, tokenLifetime.isFinite,
      tokenLifetime <= ClairTransportValidation.maximumTokenLifetime
    else {
      throw ClairTransportError.invalidGrant
    }
    _ = try AccessBoundary(
      capabilities: .viewOnly,
      visibleScopes: defaultVisibleScopes
    )
    self.hostIdentity = try ClairHostIdentity(
      hostID: hostID,
      publicKey: hostKey.publicKey
    )
    self.endpoint = endpoint
    self.protocolOffer = protocolOffer
    self.defaultVisibleScopes = defaultVisibleScopes
    self.challengeLifetime = challengeLifetime
    self.tokenLifetime = tokenLifetime
    self.clock = clock
  }

  public func presentation(
    endpoint overrideEndpoint: ClairTransportEndpoint? = nil
  ) -> ClairHostPresentation {
    try! ClairHostPresentation(
      hostID: hostIdentity.hostID,
      publicKey: hostIdentity.publicKey,
      fingerprint: hostIdentity.fingerprint,
      endpoint: overrideEndpoint ?? endpoint,
      protocolOffer: protocolOffer
    )
  }

  public func issuePairingLink(
    lifetime: TimeInterval = 300
  ) throws -> ClairPairingLink {
    guard lifetime > 0, lifetime.isFinite, lifetime <= 3_600 else {
      throw ClairTransportError.invalidPairingLink
    }
    let now = clock.now()
    try ClairTransportValidation.validateDate(now)
    let expiresAt = now.addingTimeInterval(lifetime)
    let link = try ClairPairingLink(
      pairingID: .random(),
      hostID: hostIdentity.hostID,
      endpoint: endpoint,
      hostFingerprint: hostIdentity.fingerprint,
      protocolOffer: protocolOffer,
      bootstrapSecret: .random(),
      expiresAt: expiresAt
    )
    currentPairing = PairingState(link: link, consumed: false)
    return link
  }

  public func pair(_ request: ClairPairingRequest) throws -> ClairPairingResult {
    guard request.confirmedHostFingerprint else {
      throw ClairTransportError.userConfirmationRequired
    }
    guard request.hostID == hostIdentity.hostID,
      request.hostFingerprint == hostIdentity.fingerprint
    else {
      throw ClairTransportError.hostIdentityMismatch
    }
    guard let pairing = currentPairing else {
      throw ClairTransportError.pairingUnavailable
    }
    guard pairing.link.pairingID == request.pairingID else {
      throw ClairTransportError.pairingUnavailable
    }
    guard !pairing.consumed else {
      throw ClairTransportError.pairingConsumed
    }
    let now = clock.now()
    try ClairTransportValidation.validateDate(now)
    guard now < pairing.link.expiresAt else {
      throw ClairTransportError.pairingExpired
    }
    guard grants.count < ClairTransportValidation.maximumDeviceGrants else {
      throw ClairTransportError.grantLimitReached
    }
    guard pairing.link.bootstrapSecret.matches(request.bootstrapSecret) else {
      throw ClairTransportError.authenticationFailed
    }
    guard
      request.devicePublicKey.rawRepresentation.count
        == ClairTransportValidation.publicKeyBytes
    else {
      throw ClairTransportError.invalidDeviceKey
    }

    let negotiatedProtocol: NegotiatedProtocol
    do {
      negotiatedProtocol = try ProtocolNegotiator.negotiate(
        client: request.clientOffer,
        server: protocolOffer
      )
    } catch let error as ProtocolError {
      throw ClairTransportError.protocolFailure(error)
    }

    let deviceID = uniqueDeviceID()
    let token = ClairDeviceToken.random()
    let grant = try ClairDeviceGrant(
      hostID: hostIdentity.hostID,
      deviceID: deviceID,
      devicePublicKey: request.devicePublicKey,
      displayName: request.displayName,
      generation: 1,
      capabilities: .viewOnly,
      visibleScopes: defaultVisibleScopes,
      createdAt: now,
      tokenExpiresAt: now.addingTimeInterval(tokenLifetime)
    )
    grants[deviceID] = StoredGrant(
      grant: grant,
      tokenDigest: token.digest,
      operationLedger: try OperationLedger(),
      activeConnections: []
    )
    currentPairing = PairingState(link: pairing.link, consumed: true)

    return ClairPairingResult(
      host: hostIdentity,
      endpoint: endpoint,
      negotiatedProtocol: negotiatedProtocol,
      credential: ClairDeviceCredential(grant: grant, token: token)
    )
  }

  public func beginAuthentication(
    _ request: ClairReconnectRequest
  ) throws -> ClairChallenge {
    guard request.hostID == hostIdentity.hostID,
      request.hostFingerprint == hostIdentity.fingerprint
    else {
      throw ClairTransportError.hostIdentityMismatch
    }
    guard let storedGrant = grants[request.deviceID] else {
      throw ClairTransportError.authenticationFailed
    }
    guard !storedGrant.grant.isRevoked else {
      throw ClairTransportError.deviceRevoked
    }
    let now = clock.now()
    try ClairTransportValidation.validateDate(now)
    guard !storedGrant.grant.isTokenExpired(at: now) else {
      closeConnections(for: request.deviceID)
      throw ClairTransportError.credentialExpired
    }
    guard
      ClairTransportValidation.constantTimeEqual(
        storedGrant.tokenDigest,
        request.token.digest
      )
    else {
      throw ClairTransportError.authenticationFailed
    }

    pruneExpiredChallenges(at: now)
    guard challenges.count < ClairTransportValidation.maximumPendingChallenges else {
      throw ClairTransportError.challengeLimitReached
    }
    guard
      pendingChallengeCount(for: request.deviceID)
        < ClairTransportValidation.maximumPendingChallengesPerDevice
    else {
      throw ClairTransportError.challengeLimitReached
    }

    if let resourceScope = request.resourceScope,
      !storedGrant.grant.visibleScopes.contains(where: { $0.contains(resourceScope) })
    {
      throw ClairTransportError.protocolFailure(.scopeDenied)
    }

    let negotiatedProtocol: NegotiatedProtocol
    do {
      negotiatedProtocol = try ProtocolNegotiator.negotiate(
        client: request.clientOffer,
        server: protocolOffer
      )
    } catch let error as ProtocolError {
      throw ClairTransportError.protocolFailure(error)
    }

    let challenge = try ClairChallenge(
      challengeID: uniqueChallengeID(),
      connectionID: uniqueConnectionID(),
      hostID: hostIdentity.hostID,
      hostFingerprint: hostIdentity.fingerprint,
      deviceID: storedGrant.grant.deviceID,
      generation: storedGrant.grant.generation,
      nonce: ClairTransportValidation.randomBytes(
        count: ClairTransportValidation.secretBytes
      ),
      expiresAt: now.addingTimeInterval(challengeLifetime),
      negotiatedProtocol: negotiatedProtocol,
      resourceScope: request.resourceScope
    )
    challenges[challenge.challengeID] = PendingChallenge(
      challenge: challenge,
      devicePublicKey: storedGrant.grant.devicePublicKey,
      tokenDigest: storedGrant.tokenDigest
    )
    return challenge
  }

  public func authenticate(
    _ proof: ClairChallengeProof
  ) throws -> ClairAuthenticatedConnection {
    guard let pending = challenges.removeValue(forKey: proof.challengeID) else {
      throw ClairTransportError.challengeConsumed
    }
    let challenge = pending.challenge
    let now = clock.now()
    try ClairTransportValidation.validateDate(now)
    guard now < challenge.expiresAt else {
      throw ClairTransportError.challengeExpired
    }
    guard proof.connectionID == challenge.connectionID,
      proof.hostID == challenge.hostID,
      proof.deviceID == challenge.deviceID,
      proof.generation == challenge.generation,
      proof.resourceScope == challenge.resourceScope
    else {
      throw ClairTransportError.challengeMismatch
    }
    guard let storedGrant = grants[challenge.deviceID] else {
      throw ClairTransportError.authenticationFailed
    }
    guard !storedGrant.grant.isRevoked else {
      throw ClairTransportError.deviceRevoked
    }
    guard storedGrant.grant.generation == challenge.generation else {
      throw ClairTransportError.generationMismatch
    }
    guard !storedGrant.grant.isTokenExpired(at: now) else {
      closeConnections(for: challenge.deviceID)
      throw ClairTransportError.credentialExpired
    }
    guard
      ClairTransportValidation.constantTimeEqual(
        storedGrant.tokenDigest,
        pending.tokenDigest
      )
    else {
      throw ClairTransportError.authenticationFailed
    }
    guard
      pending.devicePublicKey.verifies(
        signature: proof.signature,
        for: try challenge.signingBytes()
      )
    else {
      throw ClairTransportError.authenticationFailed
    }
    guard connections.count < ClairTransportValidation.maximumActiveConnections else {
      throw ClairTransportError.connectionLimitReached
    }

    let connection = ClairAuthenticatedConnection(
      connectionID: challenge.connectionID,
      hostID: challenge.hostID,
      deviceID: challenge.deviceID,
      generation: challenge.generation,
      negotiatedProtocol: challenge.negotiatedProtocol,
      resourceScope: challenge.resourceScope
    )
    var updatedGrant = storedGrant
    updatedGrant.grant = try replaceGrant(
      storedGrant.grant,
      generation: storedGrant.grant.generation,
      capabilities: storedGrant.grant.capabilities,
      visibleScopes: storedGrant.grant.visibleScopes,
      lastUsedAt: now,
      revokedAt: storedGrant.grant.revokedAt
    )
    updatedGrant.activeConnections.insert(connection.connectionID)
    connections[connection.connectionID] = connection
    grants[connection.deviceID] = updatedGrant
    return connection
  }

  public func authorizeRead(
    scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) throws {
    let storedGrant = try currentGrant(for: connection)
    try authorizeConnectionScope(scope, on: connection)
    let boundary = try AccessBoundary(
      capabilities: storedGrant.grant.capabilities,
      visibleScopes: storedGrant.grant.visibleScopes
    )
    try boundary.authorize(scope: scope, requiring: .view)
    try markUsed(storedGrant, at: clock.now())
  }

  @discardableResult
  public func authorize<Payload: Codable & Sendable>(
    _ operation: OperationRequest<Payload>,
    on connection: ClairAuthenticatedConnection
  ) throws -> OperationReceipt {
    let storedGrant = try currentGrant(for: connection)
    try authorizeConnectionScope(operation.scope, on: connection)
    let boundary = try AccessBoundary(
      capabilities: storedGrant.grant.capabilities,
      visibleScopes: storedGrant.grant.visibleScopes
    )
    try boundary.authorize(operation)
    var updatedGrant = storedGrant
    let receipt = try updatedGrant.operationLedger.register(operation)
    updatedGrant.grant = try replaceGrant(
      storedGrant.grant,
      generation: storedGrant.grant.generation,
      capabilities: storedGrant.grant.capabilities,
      visibleScopes: storedGrant.grant.visibleScopes,
      lastUsedAt: clock.now(),
      revokedAt: storedGrant.grant.revokedAt
    )
    grants[connection.deviceID] = updatedGrant
    return receipt
  }

  /// Issues the H03 authorization result in a typed form that H06 can pass to
  /// its dispatch actor. This does not perform the requested effect.
  public func authorizeForDispatch<Payload: Codable & Sendable>(
    _ operation: OperationRequest<Payload>,
    on connection: ClairAuthenticatedConnection
  ) throws -> ClairAuthorizationTicket<Payload> {
    let receipt = try authorize(operation, on: connection)
    guard receipt.operationID == operation.operationID,
      receipt.arrivalSequence > 0
    else {
      throw ClairTransportError.invalidConnection
    }
    return ClairAuthorizationTicket(
      operation: operation,
      receipt: receipt,
      connection: connection.info
    )
  }

  /// Rechecks connection identity, generation, scope, and operation authority
  /// immediately before H06 dispatch. H03 does not promise atomicity between
  /// this check and the later effect; H06 owns that dispatch/revoke boundary.
  public func validateDispatch<Payload: Codable & Sendable>(
    _ ticket: ClairAuthorizationTicket<Payload>,
    on connection: ClairAuthenticatedConnection
  ) throws -> OperationReceipt {
    let storedGrant = try currentGrant(for: connection)
    guard ticket.connection == connection.info,
      ticket.deviceID == connection.deviceID,
      ticket.connectionID == connection.connectionID
    else {
      throw ClairTransportError.connectionClosed
    }
    guard ticket.generation == storedGrant.grant.generation else {
      throw ClairTransportError.generationMismatch
    }
    guard ticket.receipt.operationID == ticket.operation.operationID,
      ticket.receipt.arrivalSequence > 0
    else {
      throw ClairTransportError.invalidConnection
    }
    try authorizeConnectionScope(ticket.operation.scope, on: connection)
    let boundary = try AccessBoundary(
      capabilities: storedGrant.grant.capabilities,
      visibleScopes: storedGrant.grant.visibleScopes
    )
    try boundary.authorize(ticket.operation)
    return ticket.receipt
  }

  public func updateGrant(
    deviceID: ClairDeviceID,
    capabilities: CapabilitySet,
    visibleScopes: [ResourceScope]
  ) throws -> ClairDeviceGrant {
    guard let storedGrant = grants[deviceID] else {
      throw ClairTransportError.deviceNotFound
    }
    guard !storedGrant.grant.isRevoked else {
      throw ClairTransportError.deviceRevoked
    }
    let newGeneration = try nextGeneration(after: storedGrant.grant.generation)
    let updatedGrant = try replaceGrant(
      storedGrant.grant,
      generation: newGeneration,
      capabilities: capabilities,
      visibleScopes: visibleScopes,
      lastUsedAt: storedGrant.grant.lastUsedAt,
      revokedAt: nil
    )
    let ledger = try OperationLedger()
    closeConnections(for: deviceID)
    challenges = challenges.filter { $0.value.challenge.deviceID != deviceID }
    grants[deviceID] = StoredGrant(
      grant: updatedGrant,
      tokenDigest: storedGrant.tokenDigest,
      operationLedger: ledger,
      activeConnections: []
    )
    return updatedGrant
  }

  public func revoke(deviceID: ClairDeviceID) throws -> ClairRevocation {
    guard let storedGrant = grants[deviceID] else {
      throw ClairTransportError.deviceNotFound
    }
    let revokedAt = clock.now()
    try ClairTransportValidation.validateDate(revokedAt)
    let newGeneration = try nextGeneration(after: storedGrant.grant.generation)
    let closedConnectionIDs = storedGrant.activeConnections.sorted {
      $0.rawValue < $1.rawValue
    }
    let revokedGrant = try replaceGrant(
      storedGrant.grant,
      generation: newGeneration,
      capabilities: .empty,
      visibleScopes: [],
      lastUsedAt: storedGrant.grant.lastUsedAt,
      revokedAt: revokedAt
    )
    let ledger = try OperationLedger()
    closeConnections(for: deviceID)
    challenges = challenges.filter { $0.value.challenge.deviceID != deviceID }
    grants[deviceID] = StoredGrant(
      grant: revokedGrant,
      tokenDigest: storedGrant.tokenDigest,
      operationLedger: ledger,
      activeConnections: []
    )
    return ClairRevocation(
      deviceID: deviceID,
      previousGeneration: storedGrant.grant.generation,
      newGeneration: newGeneration,
      closedConnectionIDs: closedConnectionIDs,
      revokedAt: revokedAt
    )
  }

  public func grant(for deviceID: ClairDeviceID) -> ClairDeviceGrant? {
    grants[deviceID]?.grant
  }

  public func allGrants() -> [ClairDeviceGrant] {
    grants.values.map(\.grant).sorted { $0.deviceID.rawValue < $1.deviceID.rawValue }
  }

  public func isConnectionActive(_ connection: ClairAuthenticatedConnection) -> Bool {
    connections[connection.connectionID] == connection
  }

  public func close(_ connection: ClairAuthenticatedConnection) {
    guard let existing = connections[connection.connectionID], existing == connection else {
      return
    }
    connections.removeValue(forKey: connection.connectionID)
    guard var storedGrant = grants[existing.deviceID] else { return }
    storedGrant.activeConnections.remove(existing.connectionID)
    grants[existing.deviceID] = storedGrant
  }

  private func currentGrant(
    for connection: ClairAuthenticatedConnection
  ) throws -> StoredGrant {
    guard connections[connection.connectionID] == connection else {
      throw ClairTransportError.connectionClosed
    }
    guard let storedGrant = grants[connection.deviceID] else {
      throw ClairTransportError.authenticationFailed
    }
    guard !storedGrant.grant.isRevoked else {
      throw ClairTransportError.deviceRevoked
    }
    guard storedGrant.grant.generation == connection.generation else {
      throw ClairTransportError.generationMismatch
    }
    let now = clock.now()
    try ClairTransportValidation.validateDate(now)
    guard !storedGrant.grant.isTokenExpired(at: now) else {
      closeConnections(for: connection.deviceID)
      throw ClairTransportError.credentialExpired
    }
    return storedGrant
  }

  private func authorizeConnectionScope(
    _ scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) throws {
    if let connectionScope = connection.resourceScope,
      !connectionScope.contains(scope)
    {
      throw ClairTransportError.protocolFailure(.scopeDenied)
    }
  }

  private func markUsed(
    _ storedGrant: StoredGrant,
    at date: Date
  ) throws {
    var updatedGrant = storedGrant
    updatedGrant.grant = try replaceGrant(
      storedGrant.grant,
      generation: storedGrant.grant.generation,
      capabilities: storedGrant.grant.capabilities,
      visibleScopes: storedGrant.grant.visibleScopes,
      lastUsedAt: date,
      revokedAt: storedGrant.grant.revokedAt
    )
    grants[storedGrant.grant.deviceID] = updatedGrant
  }

  private func closeConnections(for deviceID: ClairDeviceID) {
    guard var storedGrant = grants[deviceID] else { return }
    for connectionID in storedGrant.activeConnections {
      connections.removeValue(forKey: connectionID)
    }
    storedGrant.activeConnections.removeAll()
    grants[deviceID] = storedGrant
  }

  private func pendingChallengeCount(for deviceID: ClairDeviceID) -> Int {
    challenges.values.reduce(into: 0) { count, pending in
      if pending.challenge.deviceID == deviceID {
        count += 1
      }
    }
  }

  private func pruneExpiredChallenges(at date: Date) {
    challenges = challenges.filter { $0.value.challenge.expiresAt > date }
  }

  private func uniqueDeviceID() -> ClairDeviceID {
    var candidate = ClairDeviceID.random()
    while grants[candidate] != nil {
      candidate = ClairDeviceID.random()
    }
    return candidate
  }

  private func uniqueChallengeID() -> ClairChallengeID {
    var candidate = ClairChallengeID.random()
    while challenges[candidate] != nil {
      candidate = ClairChallengeID.random()
    }
    return candidate
  }

  private func uniqueConnectionID() -> ClairConnectionID {
    var candidate = ClairConnectionID.random()
    while connections[candidate] != nil {
      candidate = ClairConnectionID.random()
    }
    return candidate
  }

  private func nextGeneration(after generation: UInt64) throws -> UInt64 {
    guard generation < UInt64.max else { throw ClairTransportError.invalidGrant }
    return generation + 1
  }

  private func replaceGrant(
    _ grant: ClairDeviceGrant,
    generation: UInt64,
    capabilities: CapabilitySet,
    visibleScopes: [ResourceScope],
    lastUsedAt: Date?,
    revokedAt: Date?
  ) throws -> ClairDeviceGrant {
    try ClairDeviceGrant(
      hostID: grant.hostID,
      deviceID: grant.deviceID,
      devicePublicKey: grant.devicePublicKey,
      displayName: grant.displayName,
      generation: generation,
      capabilities: capabilities,
      visibleScopes: visibleScopes,
      createdAt: grant.createdAt,
      tokenExpiresAt: grant.tokenExpiresAt,
      lastUsedAt: lastUsedAt,
      revokedAt: revokedAt
    )
  }
}

extension CapabilitySet {
  static let viewOnly: Self = try! Self([.view])
}

/// Native client-side state machine. Credentials are held in memory here;
/// N02 supplies the Keychain/Secure Enclave persistence adapter.
public actor ClairNativeClientTransport {
  public let deviceKey: ClairDeviceKey

  private var credential: ClairDeviceCredential?
  private var pinnedHost: (hostID: ClairHostID, fingerprint: ClairHostFingerprint)?
  private var endpoint: ClairTransportEndpoint?
  private var activeConnection: ClairAuthenticatedConnection?

  public init(deviceKey: ClairDeviceKey = ClairDeviceKey()) {
    self.deviceKey = deviceKey
  }

  public var devicePublicKey: ClairDevicePublicKey { deviceKey.publicKey }

  public var deviceID: ClairDeviceID? { credential?.grant.deviceID }

  public var isPaired: Bool { credential != nil }

  public var isConnected: Bool { activeConnection != nil }

  public var pinnedHostIdentity: (hostID: ClairHostID, fingerprint: ClairHostFingerprint)? {
    pinnedHost
  }

  public var currentEndpoint: ClairTransportEndpoint? { endpoint }

  public func pair(
    using link: ClairPairingLink,
    with authority: ClairPairingAuthority,
    displayName: String,
    clientOffer: ProtocolOffer = .current,
    confirmHostFingerprint: Bool
  ) async throws -> ClairPairingResult {
    guard confirmHostFingerprint else {
      throw ClairTransportError.userConfirmationRequired
    }
    let request = ClairPairingRequest(
      link: link,
      devicePublicKey: deviceKey.publicKey,
      displayName: displayName,
      clientOffer: clientOffer,
      confirmedHostFingerprint: confirmHostFingerprint
    )
    let result = try await authority.pair(request)
    guard result.host.hostID == link.hostID,
      result.host.fingerprint == link.hostFingerprint
    else {
      throw ClairTransportError.hostIdentityMismatch
    }
    credential = result.credential
    pinnedHost = (result.host.hostID, result.host.fingerprint)
    endpoint = result.endpoint
    activeConnection = nil
    return result
  }

  public func reconnect(
    to presentation: ClairHostPresentation,
    using authority: ClairPairingAuthority,
    clientOffer: ProtocolOffer = .current,
    resourceScope: ResourceScope? = nil
  ) async throws -> ClairAuthenticatedConnection {
    guard let credential, let pinnedHost else {
      throw ClairTransportError.notPaired
    }
    guard presentation.hostID == pinnedHost.hostID,
      presentation.fingerprint == pinnedHost.fingerprint,
      presentation.publicKey.fingerprint == presentation.fingerprint
    else {
      throw ClairTransportError.hostIdentityMismatch
    }
    let previousConnection = activeConnection
    activeConnection = nil
    if let previousConnection {
      await authority.close(previousConnection)
    }
    let request = ClairReconnectRequest(
      hostID: presentation.hostID,
      hostFingerprint: presentation.fingerprint,
      deviceID: credential.grant.deviceID,
      token: credential.token,
      clientOffer: clientOffer,
      resourceScope: resourceScope
    )
    let challenge = try await authority.beginAuthentication(request)
    guard challenge.hostID == pinnedHost.hostID,
      challenge.hostFingerprint == pinnedHost.fingerprint,
      challenge.deviceID == credential.grant.deviceID,
      challenge.resourceScope == resourceScope
    else {
      throw ClairTransportError.hostIdentityMismatch
    }
    let proof = try challenge.makeProof(using: deviceKey)
    let connection = try await authority.authenticate(proof)
    endpoint = presentation.endpoint
    activeConnection = connection
    return connection
  }

  public func authorize<Payload: Codable & Sendable>(
    _ operation: OperationRequest<Payload>,
    using authority: ClairPairingAuthority
  ) async throws -> OperationReceipt {
    guard let activeConnection else {
      throw ClairTransportError.connectionClosed
    }
    do {
      return try await authority.authorize(operation, on: activeConnection)
    } catch {
      if Self.shouldInvalidateConnection(for: error) {
        self.activeConnection = nil
      }
      throw error
    }
  }

  public func authorizeRead(
    scope: ResourceScope,
    using authority: ClairPairingAuthority
  ) async throws {
    guard let activeConnection else {
      throw ClairTransportError.connectionClosed
    }
    do {
      try await authority.authorizeRead(scope: scope, on: activeConnection)
    } catch {
      if Self.shouldInvalidateConnection(for: error) {
        self.activeConnection = nil
      }
      throw error
    }
  }

  /// Polls the authority after a transport-neutral channel-close or revoke
  /// notification. This is the explicit refresh boundary for `isConnected`.
  @discardableResult
  public func refreshConnectionState(
    using authority: ClairPairingAuthority
  ) async -> Bool {
    guard let activeConnection else { return false }
    guard await authority.isConnectionActive(activeConnection) else {
      self.activeConnection = nil
      return false
    }
    return true
  }

  /// Lets a concrete channel invalidate the cached live connection when it
  /// observes a close without waiting for the next authorization call.
  public func invalidateConnection() {
    activeConnection = nil
  }

  public func disconnect(from authority: ClairPairingAuthority) async {
    if let activeConnection {
      await authority.close(activeConnection)
    }
    activeConnection = nil
  }

  public func clearPairing(from authority: ClairPairingAuthority) async {
    await disconnect(from: authority)
    credential = nil
    pinnedHost = nil
    endpoint = nil
  }

  private static func shouldInvalidateConnection(for error: Error) -> Bool {
    guard let error = error as? ClairTransportError else { return false }
    switch error {
    case .connectionClosed, .deviceRevoked, .credentialExpired, .generationMismatch:
      return true
    default:
      return false
    }
  }
}

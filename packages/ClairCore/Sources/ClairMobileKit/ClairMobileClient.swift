import ClairShared
import ClairTransport
import Foundation

/// SHA-256 fingerprint of the peer certificate (or certificate public-key
/// material) presented by the concrete TLS adapter. The concrete adapter owns
/// certificate parsing; the mobile client only compares this normalized pin.
public struct ClairCertificateFingerprint: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    let normalized = rawValue.lowercased()
    guard normalized.count == 64,
      normalized.unicodeScalars.allSatisfy({ scalar in
        switch scalar.value {
        case 0x30...0x39, 0x61...0x66:
          true
        default:
          false
        }
      })
    else {
      throw ClairMobileClientError.invalidHandshake
    }
    self.rawValue = normalized
  }

  public init(sha256Digest: Data) throws {
    guard sha256Digest.count == 32 else {
      throw ClairMobileClientError.invalidHandshake
    }
    try self.init(sha256Digest.map { String(format: "%02x", $0) }.joined())
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Compatibility spelling for callers that refer to the TLS value as a pin.
public typealias ClairCertificatePin = ClairCertificateFingerprint

/// The application-level host identity pin. Endpoint changes are intentionally
/// not part of this value: a route may move while the pinned host key stays
/// the same. When a TLS adapter supplies a certificate fingerprint, it is
/// checked as an additional pin.
public struct ClairHostPin: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let hostID: ClairHostID
  public let fingerprint: ClairHostFingerprint
  public let certificateFingerprint: ClairCertificateFingerprint?

  public init(
    identity: ClairHostIdentity,
    certificateFingerprint: ClairCertificateFingerprint? = nil
  ) {
    self.hostID = identity.hostID
    self.fingerprint = identity.fingerprint
    self.certificateFingerprint = certificateFingerprint
  }

  public init(
    hostID: ClairHostID,
    fingerprint: ClairHostFingerprint,
    certificateFingerprint: ClairCertificateFingerprint? = nil
  ) {
    self.hostID = hostID
    self.fingerprint = fingerprint
    self.certificateFingerprint = certificateFingerprint
  }

  public func validate(
    _ presentation: ClairHostPresentation,
    certificateFingerprint: ClairCertificateFingerprint? = nil
  ) throws {
    guard presentation.hostID == hostID,
      presentation.fingerprint == fingerprint,
      presentation.publicKey.fingerprint == presentation.fingerprint
    else {
      throw ClairMobileClientError.hostIdentityMismatch
    }
    if let expectedCertificateFingerprint = self.certificateFingerprint,
      certificateFingerprint != expectedCertificateFingerprint
    {
      throw ClairMobileClientError.hostIdentityMismatch
    }
  }

  public var description: String {
    let certificate = certificateFingerprint.map { ", certificateFingerprint: \($0)" } ?? ""
    return "ClairHostPin(hostID: \(hostID), fingerprint: \(fingerprint)\(certificate))"
  }
}

/// Typed, transport-neutral operations needed by the native client. The
/// in-process implementation below is the deterministic H03 test seam. A
/// Network.framework/TLS adapter can implement this protocol without changing
/// client state, pairing, or authorization semantics.
public protocol ClairMobileTransport: Sendable {
  func presentation() async throws -> ClairHostPresentation
  /// Returns the certificate pin observed by the TLS adapter. The default is
  /// nil for the H03 in-process seam, which has no certificate layer.
  func certificateFingerprint() async throws -> ClairCertificateFingerprint?
  func pair(_ request: ClairPairingRequest) async throws -> ClairPairingResult
  func beginAuthentication(_ request: ClairReconnectRequest) async throws -> ClairChallenge
  func authenticate(_ proof: ClairChallengeProof) async throws -> ClairAuthenticatedConnection
  func authorizeRead(
    scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws
  func isConnectionActive(_ connection: ClairAuthenticatedConnection) async -> Bool
  func close(_ connection: ClairAuthenticatedConnection) async
}

extension ClairMobileTransport {
  public func certificateFingerprint() async throws -> ClairCertificateFingerprint? { nil }
}

/// The H03 transport-neutral adapter used by client tests and local fixtures.
/// It deliberately does not open a socket or infer trust from reachability.
public actor ClairInProcessMobileTransport: ClairMobileTransport {
  private let authority: ClairPairingAuthority
  private var presentationOverride: ClairHostPresentation?
  private var certificateFingerprintOverride: ClairCertificateFingerprint?

  public init(
    authority: ClairPairingAuthority,
    certificateFingerprint: ClairCertificateFingerprint? = nil
  ) {
    self.authority = authority
    self.certificateFingerprintOverride = certificateFingerprint
  }

  public func presentation() async throws -> ClairHostPresentation {
    if let presentationOverride {
      return presentationOverride
    }
    return await authority.presentation()
  }

  public func setPresentation(_ presentation: ClairHostPresentation?) {
    presentationOverride = presentation
  }

  public func certificateFingerprint() async throws -> ClairCertificateFingerprint? {
    certificateFingerprintOverride
  }

  public func setCertificateFingerprint(_ fingerprint: ClairCertificateFingerprint?) {
    certificateFingerprintOverride = fingerprint
  }

  public func pair(_ request: ClairPairingRequest) async throws -> ClairPairingResult {
    try await authority.pair(request)
  }

  public func beginAuthentication(
    _ request: ClairReconnectRequest
  ) async throws -> ClairChallenge {
    try await authority.beginAuthentication(request)
  }

  public func authenticate(
    _ proof: ClairChallengeProof
  ) async throws -> ClairAuthenticatedConnection {
    try await authority.authenticate(proof)
  }

  public func authorizeRead(
    scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    try await authority.authorizeRead(scope: scope, on: connection)
  }

  public func isConnectionActive(_ connection: ClairAuthenticatedConnection) async -> Bool {
    await authority.isConnectionActive(connection)
  }

  public func close(_ connection: ClairAuthenticatedConnection) async {
    await authority.close(connection)
  }
}

/// Explicit boundary for the eventual Network.framework/TLS byte-stream
/// implementation. The current N02 client only depends on
/// `ClairMobileTransport`; it must never silently substitute a raw socket or
/// skip the application-level host pin.
public enum ClairMobileTransportBoundaryError: Error, Equatable, LocalizedError, Sendable {
  case unavailable

  public var errorDescription: String? {
    "The production Network.framework/TLS transport adapter is unavailable."
  }
}

public struct ClairNetworkTLSMobileTransportBoundary: Sendable {
  public init() {}

  public func openChannel(
    to endpoint: ClairTransportEndpoint,
    pinnedTo host: ClairHostPin
  ) async throws -> any ClairNativeTransportChannel {
    throw ClairMobileTransportBoundaryError.unavailable
  }
}

public enum ClairMobileClientError: Error, Equatable, LocalizedError, Sendable {
  case credentialStore(ClairDeviceIdentityStoreError)
  case pairingExpired
  case pairingUnavailable
  case pairingReplayRejected
  case userConfirmationRequired
  case hostIdentityMismatch
  case capabilityNegotiationFailed
  case protocolNegotiationFailed
  case authenticationFailed
  case credentialExpired
  case deviceRevoked
  case connectionClosed
  case transportUnavailable
  case notPaired
  case invalidHandshake
  case operationInProgress
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .credentialStore(let error):
      error.localizedDescription
    case .pairingExpired:
      "The pairing link has expired."
    case .pairingUnavailable:
      "The pairing link is not available."
    case .pairingReplayRejected:
      "The pairing link has already been consumed."
    case .userConfirmationRequired:
      "The host fingerprint must be explicitly confirmed."
    case .hostIdentityMismatch:
      "The presented host identity does not match the pinned identity."
    case .capabilityNegotiationFailed:
      "The host does not provide the required client capabilities."
    case .protocolNegotiationFailed:
      "The client and host do not support a compatible protocol."
    case .authenticationFailed:
      "Device authentication failed."
    case .credentialExpired:
      "The saved device credential has expired."
    case .deviceRevoked:
      "The device grant has been revoked."
    case .connectionClosed:
      "The authenticated connection is closed."
    case .transportUnavailable:
      "The native transport is unavailable."
    case .notPaired:
      "This device is not paired with a host."
    case .invalidHandshake:
      "The host returned an invalid authentication handshake."
    case .operationInProgress:
      "Another client connection operation is already in progress."
    case .cancelled:
      "The client connection operation was cancelled."
    }
  }
}

public struct ClairMobileConnectionSummary: Equatable, Sendable {
  public let hostID: ClairHostID
  public let hostFingerprint: ClairHostFingerprint
  public let certificateFingerprint: ClairCertificateFingerprint?
  public let deviceID: ClairDeviceID
  public let endpoint: ClairTransportEndpoint
  public let negotiatedProtocol: NegotiatedProtocol

  public init(
    hostID: ClairHostID,
    hostFingerprint: ClairHostFingerprint,
    certificateFingerprint: ClairCertificateFingerprint? = nil,
    deviceID: ClairDeviceID,
    endpoint: ClairTransportEndpoint,
    negotiatedProtocol: NegotiatedProtocol
  ) {
    self.hostID = hostID
    self.hostFingerprint = hostFingerprint
    self.certificateFingerprint = certificateFingerprint
    self.deviceID = deviceID
    self.endpoint = endpoint
    self.negotiatedProtocol = negotiatedProtocol
  }
}

public enum ClairMobileClientState: Equatable, Sendable {
  case disconnected
  case connecting
  case pairing
  case authenticated(ClairMobileConnectionSummary)
  case reconnecting
  case failed(ClairMobileClientError)
}

/// Native client state machine. All long-lived credential material stays in
/// the protected store and H03 transport actor; the public state contains only
/// safe identity/capability metadata and typed, redacted failures.
public actor ClairMobileClient {
  private let store: any ClairDeviceIdentityStore
  private let transport: any ClairMobileTransport
  private let clientOffer: ProtocolOffer
  private let requiredCapabilities: CapabilitySet

  private var stateValue: ClairMobileClientState = .disconnected
  private var operationGeneration: UInt64 = 0
  private var activeOperation: UInt64?
  private var activeConnection: ClairAuthenticatedConnection?

  public init(
    store: any ClairDeviceIdentityStore,
    transport: any ClairMobileTransport,
    clientOffer: ProtocolOffer = .current,
    requiredCapabilities: CapabilitySet? = nil
  ) throws {
    let requiredCapabilities = requiredCapabilities ?? (try! CapabilitySet([.view]))
    guard !requiredCapabilities.values.isEmpty,
      requiredCapabilities.values.allSatisfy(clientOffer.capabilities.contains)
    else {
      throw ClairMobileClientError.capabilityNegotiationFailed
    }
    self.store = store
    self.transport = transport
    self.clientOffer = clientOffer
    self.requiredCapabilities = requiredCapabilities
  }

  public var state: ClairMobileClientState { stateValue }

  /// Performs one-time pairing and persists the resulting opaque credential.
  /// Pairing itself does not create an authenticated session; callers invoke
  /// `reconnect()` to perform the fresh challenge proof.
  @discardableResult
  public func pair(
    using link: ClairPairingLink,
    displayName: String,
    confirmHostFingerprint: Bool,
    certificateFingerprint: ClairCertificateFingerprint? = nil
  ) async throws -> ClairMobileConnectionSummary {
    guard activeConnection == nil else {
      throw ClairMobileClientError.operationInProgress
    }
    let token = try begin(.pairing)

    do {
      guard confirmHostFingerprint else {
        throw ClairMobileClientError.userConfirmationRequired
      }
      let persistedIdentity = try await store.load()
      try ensureCurrent(token)
      let presentation = try await transport.presentation()
      try ensureCurrent(token)
      guard presentation.hostID == link.hostID,
        presentation.fingerprint == link.hostFingerprint,
        presentation.publicKey.fingerprint == presentation.fingerprint,
        presentation.protocolOffer == link.protocolOffer
      else {
        throw ClairMobileClientError.hostIdentityMismatch
      }
      let observedCertificateFingerprint = try await transport.certificateFingerprint()
      try ensureCurrent(token)
      let pinnedCertificateFingerprint = certificateFingerprint ?? observedCertificateFingerprint
      guard
        pinnedCertificateFingerprint == nil
          || observedCertificateFingerprint == pinnedCertificateFingerprint
      else {
        throw ClairMobileClientError.hostIdentityMismatch
      }
      let hostPin = ClairHostPin(
        hostID: link.hostID,
        fingerprint: link.hostFingerprint,
        certificateFingerprint: pinnedCertificateFingerprint
      )
      try hostPin.validate(
        presentation,
        certificateFingerprint: observedCertificateFingerprint
      )
      let predictedNegotiation = try negotiate(serverOffer: presentation.protocolOffer)
      let deviceKey: ClairDeviceKey
      if let persistedIdentity {
        deviceKey = try persistedIdentity.makeDeviceKey()
      } else {
        deviceKey = try await store.createDeviceKey()
      }
      try ensureCurrent(token)

      let result = try await transport.pair(
        ClairPairingRequest(
          link: link,
          devicePublicKey: deviceKey.publicKey,
          displayName: displayName,
          clientOffer: clientOffer,
          confirmedHostFingerprint: confirmHostFingerprint
        )
      )
      try ensureCurrent(token)
      try validatePairingResult(
        result,
        link: link,
        expectedNegotiation: predictedNegotiation,
        expectedDeviceKey: deviceKey
      )

      let identity = ClairStoredDeviceIdentity(
        deviceKey: deviceKey,
        credential: result.credential,
        hostIdentity: result.host,
        endpoint: result.endpoint,
        negotiatedProtocol: result.negotiatedProtocol,
        certificateFingerprint: pinnedCertificateFingerprint
      )
      try await store.save(identity)
      try ensureCurrent(token)

      stateValue = .disconnected
      activeOperation = nil
      return summary(for: identity)
    } catch {
      throw handleFailure(error, for: token)
    }
  }

  /// Restores the protected identity after restart and authenticates with a
  /// fresh H03 challenge. An endpoint may change, but the pinned host identity
  /// and application fingerprint must remain unchanged.
  @discardableResult
  public func reconnect() async throws -> ClairMobileConnectionSummary {
    if case .authenticated(let summary) = stateValue,
      let activeConnection
    {
      let observedGeneration = operationGeneration
      let isActive = await transport.isConnectionActive(activeConnection)
      guard observedGeneration == operationGeneration,
        self.activeConnection == activeConnection
      else {
        throw ClairMobileClientError.cancelled
      }
      if isActive {
        return summary
      }
      self.activeConnection = nil
      stateValue = .disconnected
    }

    let token = try begin(.connecting)
    do {
      guard let identity = try await store.load() else {
        throw ClairMobileClientError.notPaired
      }
      try ensureCurrent(token)
      let deviceKey = try identity.makeDeviceKey()
      try validateStoredIdentity(identity, deviceKey: deviceKey)

      let presentation = try await transport.presentation()
      try ensureCurrent(token)
      let observedCertificateFingerprint = try await transport.certificateFingerprint()
      try ensureCurrent(token)
      try ClairHostPin(
        identity: identity.hostIdentity,
        certificateFingerprint: identity.certificateFingerprint
      ).validate(
        presentation,
        certificateFingerprint: observedCertificateFingerprint
      )
      let predictedNegotiation = try negotiate(serverOffer: presentation.protocolOffer)

      stateValue = .reconnecting
      let previousConnection = activeConnection
      activeConnection = nil
      if let previousConnection {
        await transport.close(previousConnection)
        try ensureCurrent(token)
      }

      let request = ClairReconnectRequest(
        hostID: presentation.hostID,
        hostFingerprint: presentation.fingerprint,
        deviceID: identity.credential.grant.deviceID,
        token: identity.credential.token,
        clientOffer: clientOffer
      )
      let challenge = try await transport.beginAuthentication(request)
      try ensureCurrent(token)
      guard challenge.hostID == identity.hostIdentity.hostID,
        challenge.hostFingerprint == identity.hostIdentity.fingerprint,
        challenge.deviceID == identity.credential.grant.deviceID,
        challenge.generation == identity.credential.grant.generation,
        challenge.resourceScope == nil,
        challenge.negotiatedProtocol == predictedNegotiation
      else {
        throw ClairMobileClientError.invalidHandshake
      }

      let proof = try challenge.makeProof(using: deviceKey)
      let connection = try await transport.authenticate(proof)
      guard isCurrent(token), !Task.isCancelled else {
        await transport.close(connection)
        throw ClairMobileClientError.cancelled
      }
      guard connection.hostID == identity.hostIdentity.hostID,
        connection.deviceID == identity.credential.grant.deviceID,
        connection.generation == identity.credential.grant.generation,
        connection.negotiatedProtocol == challenge.negotiatedProtocol,
        connection.resourceScope == nil
      else {
        await transport.close(connection)
        throw ClairMobileClientError.invalidHandshake
      }

      // Endpoint persistence is deliberately after identity validation and
      // successful authentication. A changed endpoint can never rewrite the
      // pin, and a failed store update does not leave a live unrecorded link.
      let updatedIdentity = try identity.updating(
        endpoint: presentation.endpoint,
        negotiatedProtocol: connection.negotiatedProtocol,
        certificateFingerprint: identity.certificateFingerprint ?? observedCertificateFingerprint
      )
      do {
        try await store.save(updatedIdentity)
      } catch {
        await transport.close(connection)
        throw error
      }
      guard isCurrent(token), !Task.isCancelled else {
        await transport.close(connection)
        throw ClairMobileClientError.cancelled
      }

      activeConnection = connection
      stateValue = .authenticated(summary(for: updatedIdentity))
      activeOperation = nil
      return summary(for: updatedIdentity)
    } catch {
      throw handleFailure(error, for: token)
    }
  }

  /// Idempotently closes the live connection and invalidates any in-flight
  /// handshake before it can commit a newly authenticated connection.
  public func disconnect() async {
    operationGeneration &+= 1
    let connection = activeConnection
    activeConnection = nil
    stateValue = .disconnected
    if let connection {
      await transport.close(connection)
    }
  }

  public func clearPairing() async throws {
    await disconnect()
    guard activeOperation == nil else {
      throw ClairMobileClientError.operationInProgress
    }
    do {
      try await store.remove()
    } catch {
      let mapped = Self.map(error)
      stateValue = .failed(mapped)
      throw mapped
    }
  }

  /// Revalidates the cached live handle after a channel-close or revoke event.
  @discardableResult
  public func refreshConnectionState() async -> Bool {
    guard let activeConnection else { return false }
    let observedGeneration = operationGeneration
    let active = await transport.isConnectionActive(activeConnection)
    guard observedGeneration == operationGeneration,
      self.activeConnection == activeConnection
    else {
      return false
    }
    guard active else {
      self.activeConnection = nil
      stateValue = .disconnected
      return false
    }
    return true
  }

  public func authorizeRead(scope: ResourceScope) async throws {
    guard let activeConnection else {
      throw ClairMobileClientError.connectionClosed
    }
    let observedGeneration = operationGeneration
    do {
      try await transport.authorizeRead(scope: scope, on: activeConnection)
      guard observedGeneration == operationGeneration,
        self.activeConnection == activeConnection
      else {
        throw ClairMobileClientError.cancelled
      }
    } catch {
      let mapped = Self.map(error)
      if observedGeneration == operationGeneration,
        self.activeConnection == activeConnection
      {
        if mapped == .deviceRevoked || mapped == .credentialExpired || mapped == .connectionClosed {
          self.activeConnection = nil
        }
        stateValue = .failed(mapped)
      }
      throw mapped
    }
  }

  private enum OperationState {
    case pairing
    case connecting
  }

  private func begin(_ state: OperationState) throws -> UInt64 {
    guard activeOperation == nil else {
      throw ClairMobileClientError.operationInProgress
    }
    operationGeneration &+= 1
    activeOperation = operationGeneration
    switch state {
    case .pairing:
      stateValue = .pairing
    case .connecting:
      stateValue = .connecting
    }
    return operationGeneration
  }

  private func isCurrent(_ token: UInt64) -> Bool {
    activeOperation == token && operationGeneration == token
  }

  private func ensureCurrent(_ token: UInt64) throws {
    guard isCurrent(token), !Task.isCancelled else {
      throw ClairMobileClientError.cancelled
    }
  }

  private func negotiate(serverOffer: ProtocolOffer) throws -> NegotiatedProtocol {
    let negotiated: NegotiatedProtocol
    do {
      negotiated = try ProtocolNegotiator.negotiate(
        client: clientOffer,
        server: serverOffer
      )
    } catch {
      throw ClairMobileClientError.protocolNegotiationFailed
    }
    guard requiredCapabilities.values.allSatisfy(negotiated.capabilities.contains) else {
      throw ClairMobileClientError.capabilityNegotiationFailed
    }
    return negotiated
  }

  private func validatePairingResult(
    _ result: ClairPairingResult,
    link: ClairPairingLink,
    expectedNegotiation: NegotiatedProtocol,
    expectedDeviceKey: ClairDeviceKey
  ) throws {
    guard result.host.hostID == link.hostID,
      result.host.fingerprint == link.hostFingerprint,
      result.host.publicKey.fingerprint == result.host.fingerprint,
      result.negotiatedProtocol == expectedNegotiation,
      result.credential.grant.hostID == result.host.hostID,
      result.credential.grant.devicePublicKey == expectedDeviceKey.publicKey
    else {
      throw ClairMobileClientError.invalidHandshake
    }
  }

  private func validateStoredIdentity(
    _ identity: ClairStoredDeviceIdentity,
    deviceKey: ClairDeviceKey
  ) throws {
    if identity.credential.grant.isRevoked {
      throw ClairMobileClientError.deviceRevoked
    }
    if identity.credential.grant.isTokenExpired(at: Date()) {
      throw ClairMobileClientError.credentialExpired
    }
    guard identity.credential.grant.hostID == identity.hostIdentity.hostID,
      identity.hostIdentity.publicKey.fingerprint == identity.hostIdentity.fingerprint,
      identity.credential.grant.devicePublicKey == deviceKey.publicKey
    else {
      throw ClairMobileClientError.invalidHandshake
    }
  }

  private func summary(for identity: ClairStoredDeviceIdentity) -> ClairMobileConnectionSummary {
    ClairMobileConnectionSummary(
      hostID: identity.hostIdentity.hostID,
      hostFingerprint: identity.hostIdentity.fingerprint,
      certificateFingerprint: identity.certificateFingerprint,
      deviceID: identity.credential.grant.deviceID,
      endpoint: identity.endpoint,
      negotiatedProtocol: identity.negotiatedProtocol
    )
  }

  private func handleFailure(_ error: Error, for token: UInt64) -> ClairMobileClientError {
    let mapped = Self.map(error)
    let ownsOperation = activeOperation == token
    if ownsOperation {
      activeOperation = nil
    }
    if ownsOperation && operationGeneration == token {
      stateValue = .failed(mapped)
    }
    return mapped
  }

  private static func map(_ error: Error) -> ClairMobileClientError {
    if error is CancellationError {
      return .cancelled
    }
    if let error = error as? ClairMobileClientError {
      return error
    }
    if let error = error as? ClairDeviceIdentityStoreError {
      return .credentialStore(error)
    }
    if error is ClairMobileTransportBoundaryError {
      return .transportUnavailable
    }
    guard let error = error as? ClairTransportError else {
      return .invalidHandshake
    }
    switch error {
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
    case .credentialExpired:
      return .credentialExpired
    case .deviceRevoked:
      return .deviceRevoked
    case .connectionClosed:
      return .connectionClosed
    case .notPaired:
      return .notPaired
    case .deviceNotFound:
      return .notPaired
    case .invalidToken, .invalidDeviceKey:
      return .authenticationFailed
    case .generationMismatch, .challengeExpired, .challengeConsumed, .challengeMismatch:
      return .authenticationFailed
    case .authenticationFailed:
      return .authenticationFailed
    case .protocolFailure(let protocolError):
      switch protocolError {
      case .noCompatibleVersion, .unsupportedMajor:
        return .protocolNegotiationFailed
      case .capabilityDenied, .capabilityMismatch:
        return .capabilityNegotiationFailed
      default:
        return .invalidHandshake
      }
    default:
      return .invalidHandshake
    }
  }
}

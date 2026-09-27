import ClairShared
import ClairTransport
import Foundation

#if canImport(Security)
  import Security
#endif

/// The protection boundary used by a native client credential store.
///
/// `secureEnclave` is intentionally an explicit choice. It must not silently
/// fall back to an exportable software key when the platform cannot provide
/// the requested protection.
public enum ClairDeviceKeyProtection: String, Codable, Equatable, Sendable {
  case keychainWhenUnlockedThisDeviceOnly
  case secureEnclave
}

/// Safe, typed failures from the protected credential boundary. The cases do
/// not carry OSStatus values or stored bytes so they can safely cross the
/// client/UI boundary.
public enum ClairDeviceIdentityStoreError: Error, Equatable, LocalizedError, Sendable {
  case unavailable
  case locked
  case accessDenied
  case unsupportedProtection
  case corrupted
  case keyRotationRequired
  case serializationFailure

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "Protected device identity storage is unavailable."
    case .locked:
      "Protected device identity storage is locked."
    case .accessDenied:
      "Protected device identity storage access was denied."
    case .unsupportedProtection:
      "The requested device-key protection is unavailable on this build."
    case .corrupted:
      "The protected device identity record is invalid."
    case .keyRotationRequired:
      "The protected device key cannot be used and must be rotated by explicit re-pairing."
    case .serializationFailure:
      "The protected device identity record could not be encoded."
    }
  }
}

/// The complete persisted client identity. It is deliberately separate from
/// `ClairMobileClientState`: credentials never become SwiftUI state,
/// navigation state, or a user-facing description.
public struct ClairStoredDeviceIdentity: Codable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let credential: ClairDeviceCredential
  public let hostIdentity: ClairHostIdentity
  public let endpoint: ClairTransportEndpoint
  public let negotiatedProtocol: NegotiatedProtocol
  public let certificateFingerprint: ClairCertificateFingerprint?

  private let deviceKeyRepresentation: Data

  public init(
    deviceKey: ClairDeviceKey,
    credential: ClairDeviceCredential,
    hostIdentity: ClairHostIdentity,
    endpoint: ClairTransportEndpoint,
    negotiatedProtocol: NegotiatedProtocol,
    certificateFingerprint: ClairCertificateFingerprint? = nil
  ) {
    self.deviceKeyRepresentation = deviceKey.rawRepresentation
    self.credential = credential
    self.hostIdentity = hostIdentity
    self.endpoint = endpoint
    self.negotiatedProtocol = negotiatedProtocol
    self.certificateFingerprint = certificateFingerprint
  }

  /// Rehydrates the signer only inside the client/transport boundary.
  /// Invalid persisted key material is a rotation event, never a fallback to
  /// a newly generated key that could strand an existing grant.
  public func makeDeviceKey() throws -> ClairDeviceKey {
    do {
      return try ClairDeviceKey(rawRepresentation: deviceKeyRepresentation)
    } catch {
      throw ClairDeviceIdentityStoreError.keyRotationRequired
    }
  }

  public func updating(
    endpoint: ClairTransportEndpoint,
    negotiatedProtocol: NegotiatedProtocol,
    certificateFingerprint: ClairCertificateFingerprint? = nil
  ) throws -> Self {
    try Self(
      deviceKey: makeDeviceKey(),
      credential: credential,
      hostIdentity: hostIdentity,
      endpoint: endpoint,
      negotiatedProtocol: negotiatedProtocol,
      certificateFingerprint: certificateFingerprint ?? self.certificateFingerprint
    )
  }

  public var description: String {
    let certificate = certificateFingerprint.map { ", certificateFingerprint: \($0)" } ?? ""
    return
      "ClairStoredDeviceIdentity(hostID: \(hostIdentity.hostID), deviceID: \(credential.grant.deviceID), endpoint: \(endpoint)\(certificate), credential: <redacted>, deviceKey: <redacted>)"
  }

  public var debugDescription: String { description }

  public init(from decoder: Decoder) throws {
    let record: ClairStoredIdentityRecord
    do {
      record = try ClairStoredIdentityRecord(from: decoder)
    } catch {
      throw ClairDeviceIdentityStoreError.corrupted
    }

    let deviceKeyRepresentation: Data
    do {
      deviceKeyRepresentation = try record.deviceKeyRepresentation.decoded(exactly: 32)
      _ = try ClairDeviceKey(rawRepresentation: deviceKeyRepresentation)
    } catch {
      throw ClairDeviceIdentityStoreError.keyRotationRequired
    }

    let credential: ClairDeviceCredential
    let hostIdentity: ClairHostIdentity
    do {
      credential = try record.credential.makeCredential()
      hostIdentity = try record.hostIdentity.makeIdentity()
    } catch {
      throw ClairDeviceIdentityStoreError.corrupted
    }

    self.deviceKeyRepresentation = deviceKeyRepresentation
    self.credential = credential
    self.hostIdentity = hostIdentity
    self.endpoint = record.endpoint
    self.negotiatedProtocol = record.negotiatedProtocol
    self.certificateFingerprint = record.certificateFingerprint
  }

  public func encode(to encoder: Encoder) throws {
    try ClairStoredIdentityRecord(
      deviceKeyRepresentation: ClairStoredIdentityBytes(data: deviceKeyRepresentation),
      credential: ClairStoredCredential(credential),
      hostIdentity: ClairStoredHostIdentity(hostIdentity),
      endpoint: endpoint,
      negotiatedProtocol: negotiatedProtocol,
      certificateFingerprint: certificateFingerprint
    ).encode(to: encoder)
  }
}

/// Storage-only Codable envelope. H03's wire values intentionally encode
/// bounded bytes as base64 strings; using the same representation here keeps
/// JSON and PropertyList persistence interoperable without changing H03.
private struct ClairStoredIdentityBytes: Codable {
  let encoded: String

  init(data: Data) {
    encoded = data.base64EncodedString()
  }

  init(from decoder: Decoder) throws {
    encoded = try decoder.singleValueContainer().decode(String.self)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(encoded)
  }

  func decoded(exactly length: Int) throws -> Data {
    guard let data = Data(base64Encoded: encoded), data.count == length else {
      throw ClairDeviceIdentityStoreError.corrupted
    }
    return data
  }
}

private struct ClairStoredDevicePublicKey: Codable {
  let rawRepresentation: ClairStoredIdentityBytes

  init(_ key: ClairDevicePublicKey) {
    rawRepresentation = ClairStoredIdentityBytes(data: key.rawRepresentation)
  }

  func makeKey() throws -> ClairDevicePublicKey {
    try ClairDevicePublicKey(rawRepresentation: rawRepresentation.decoded(exactly: 64))
  }
}

private struct ClairStoredHostPublicKey: Codable {
  let rawRepresentation: ClairStoredIdentityBytes

  init(_ key: ClairHostPublicKey) {
    rawRepresentation = ClairStoredIdentityBytes(data: key.rawRepresentation)
  }

  func makeKey() throws -> ClairHostPublicKey {
    try ClairHostPublicKey(rawRepresentation: rawRepresentation.decoded(exactly: 64))
  }
}

private struct ClairStoredGrant: Codable {
  let hostID: ClairHostID
  let deviceID: ClairDeviceID
  let devicePublicKey: ClairStoredDevicePublicKey
  let displayName: String
  let generation: UInt64
  let capabilities: CapabilitySet
  let visibleScopes: [ResourceScope]
  let createdAt: Date
  let tokenExpiresAt: Date
  let lastUsedAt: Date?
  let revokedAt: Date?

  init(_ grant: ClairDeviceGrant) {
    hostID = grant.hostID
    deviceID = grant.deviceID
    devicePublicKey = ClairStoredDevicePublicKey(grant.devicePublicKey)
    displayName = grant.displayName
    generation = grant.generation
    capabilities = grant.capabilities
    visibleScopes = grant.visibleScopes
    createdAt = grant.createdAt
    tokenExpiresAt = grant.tokenExpiresAt
    lastUsedAt = grant.lastUsedAt
    revokedAt = grant.revokedAt
  }

  func makeGrant() throws -> ClairDeviceGrant {
    try ClairDeviceGrant(
      hostID: hostID,
      deviceID: deviceID,
      devicePublicKey: devicePublicKey.makeKey(),
      displayName: displayName,
      generation: generation,
      capabilities: capabilities,
      visibleScopes: visibleScopes,
      createdAt: createdAt,
      tokenExpiresAt: tokenExpiresAt,
      lastUsedAt: lastUsedAt,
      revokedAt: revokedAt
    )
  }
}

private struct ClairStoredCredential: Codable {
  let grant: ClairStoredGrant
  let token: ClairStoredIdentityBytes

  init(_ credential: ClairDeviceCredential) {
    grant = ClairStoredGrant(credential.grant)
    token = ClairStoredIdentityBytes(data: credential.token.rawRepresentation)
  }

  func makeCredential() throws -> ClairDeviceCredential {
    ClairDeviceCredential(
      grant: try grant.makeGrant(),
      token: try ClairDeviceToken(rawRepresentation: token.decoded(exactly: 32))
    )
  }
}

private struct ClairStoredHostIdentity: Codable {
  let hostID: ClairHostID
  let publicKey: ClairStoredHostPublicKey
  let fingerprint: ClairHostFingerprint

  init(_ identity: ClairHostIdentity) {
    hostID = identity.hostID
    publicKey = ClairStoredHostPublicKey(identity.publicKey)
    fingerprint = identity.fingerprint
  }

  func makeIdentity() throws -> ClairHostIdentity {
    try ClairHostIdentity(
      hostID: hostID,
      publicKey: publicKey.makeKey(),
      fingerprint: fingerprint
    )
  }
}

private struct ClairStoredIdentityRecord: Codable {
  let deviceKeyRepresentation: ClairStoredIdentityBytes
  let credential: ClairStoredCredential
  let hostIdentity: ClairStoredHostIdentity
  let endpoint: ClairTransportEndpoint
  let negotiatedProtocol: NegotiatedProtocol
  let certificateFingerprint: ClairCertificateFingerprint?
}

/// Protected storage used by the native client. Implementations own both the
/// device signer material and the opaque device credential as one record so a
/// restart cannot accidentally pair a token with a different key.
public protocol ClairDeviceIdentityStore: Sendable {
  func load() async throws -> ClairStoredDeviceIdentity?
  func createDeviceKey() async throws -> ClairDeviceKey
  func save(_ identity: ClairStoredDeviceIdentity) async throws
  func remove() async throws
}

/// Deterministic protected-store substitute for protocol and client tests.
/// It never serializes secrets to logs and allows tests to inject explicit
/// locked/unavailable/corrupt-store failures.
public actor ClairInMemoryDeviceIdentityStore: ClairDeviceIdentityStore {
  private var identity: ClairStoredDeviceIdentity?
  private let deviceKey: ClairDeviceKey
  private var injectedError: ClairDeviceIdentityStoreError?

  public init(
    deviceKey: ClairDeviceKey,
    identity: ClairStoredDeviceIdentity? = nil
  ) {
    self.deviceKey = deviceKey
    self.identity = identity
  }

  public func load() async throws -> ClairStoredDeviceIdentity? {
    try throwIfInjected()
    return identity
  }

  public func createDeviceKey() async throws -> ClairDeviceKey {
    try throwIfInjected()
    return deviceKey
  }

  public func save(_ identity: ClairStoredDeviceIdentity) async throws {
    try throwIfInjected()
    self.identity = identity
  }

  public func remove() async throws {
    try throwIfInjected()
    identity = nil
  }

  public func setInjectedError(_ error: ClairDeviceIdentityStoreError?) {
    injectedError = error
  }

  private func throwIfInjected() throws {
    if let injectedError {
      throw injectedError
    }
  }
}

/// The concrete iOS/macOS Keychain boundary. It stores a single JSON record
/// as device-only Keychain data and never puts credentials in UserDefaults or
/// files.
public struct ClairKeychainDeviceIdentityStore: ClairDeviceIdentityStore {
  public let service: String
  public let account: String
  public let protection: ClairDeviceKeyProtection

  public init(
    service: String = "com.diwamoto.clair.mobile.v2",
    account: String = "device-identity",
    protection: ClairDeviceKeyProtection = .keychainWhenUnlockedThisDeviceOnly
  ) {
    self.service = service
    self.account = account
    self.protection = protection
  }

  public func load() async throws -> ClairStoredDeviceIdentity? {
    try ensureSupportedProtection()
    #if canImport(Security)
      var query = baseQuery
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne

      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      switch status {
      case errSecSuccess:
        guard let data = result as? Data else {
          throw ClairDeviceIdentityStoreError.corrupted
        }
        do {
          return try JSONDecoder().decode(ClairStoredDeviceIdentity.self, from: data)
        } catch let error as ClairDeviceIdentityStoreError {
          throw error
        } catch {
          throw ClairDeviceIdentityStoreError.corrupted
        }
      case errSecItemNotFound:
        return nil
      default:
        throw mapKeychainStatus(status)
      }
    #else
      throw ClairDeviceIdentityStoreError.unavailable
    #endif
  }

  public func createDeviceKey() async throws -> ClairDeviceKey {
    try ensureSupportedProtection()
    // H03 currently signs with its transport-neutral CryptoKit key type. A
    // future Secure Enclave signer must be added at that boundary; this
    // adapter never exports an enclave key into a software key as a fallback.
    return ClairDeviceKey()
  }

  public func save(_ identity: ClairStoredDeviceIdentity) async throws {
    try ensureSupportedProtection()
    #if canImport(Security)
      let data: Data
      do {
        data = try JSONEncoder().encode(identity)
      } catch {
        throw ClairDeviceIdentityStoreError.serializationFailure
      }

      let attributes: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
      let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
      if updateStatus == errSecSuccess {
        return
      }
      guard updateStatus == errSecItemNotFound else {
        throw mapKeychainStatus(updateStatus)
      }

      var insert = baseQuery
      insert[kSecValueData as String] = data
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      let insertStatus = SecItemAdd(insert as CFDictionary, nil)
      guard insertStatus == errSecSuccess else {
        throw mapKeychainStatus(insertStatus)
      }
    #else
      throw ClairDeviceIdentityStoreError.unavailable
    #endif
  }

  public func remove() async throws {
    try ensureSupportedProtection()
    #if canImport(Security)
      let status = SecItemDelete(baseQuery as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw mapKeychainStatus(status)
      }
    #else
      throw ClairDeviceIdentityStoreError.unavailable
    #endif
  }

  private func ensureSupportedProtection() throws {
    guard protection == .keychainWhenUnlockedThisDeviceOnly else {
      throw ClairDeviceIdentityStoreError.unsupportedProtection
    }
  }

  #if canImport(Security)
    private var baseQuery: [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false,
      ]
    }

    private func mapKeychainStatus(_ status: OSStatus) -> ClairDeviceIdentityStoreError {
      switch status {
      case errSecInteractionNotAllowed:
        .locked
      case errSecAuthFailed:
        .accessDenied
      case errSecNotAvailable:
        .unavailable
      case errSecDecode, errSecParam:
        .corrupted
      default:
        .unavailable
      }
    }
  #endif
}

/// Secure Enclave is a deliberate production boundary. H03's current public
/// signer accepts `ClairDeviceKey`, so enabling an enclave-backed key would
/// require a signer protocol change outside N02. Failing explicitly prevents
/// an unsafe software-key fallback on devices that requested enclave
/// protection.
public struct ClairSecureEnclaveDeviceIdentityStore: ClairDeviceIdentityStore {
  public init() {}

  public func load() async throws -> ClairStoredDeviceIdentity? {
    throw ClairDeviceIdentityStoreError.unsupportedProtection
  }

  public func createDeviceKey() async throws -> ClairDeviceKey {
    throw ClairDeviceIdentityStoreError.unsupportedProtection
  }

  public func save(_ identity: ClairStoredDeviceIdentity) async throws {
    throw ClairDeviceIdentityStoreError.unsupportedProtection
  }

  public func remove() async throws {
    throw ClairDeviceIdentityStoreError.unsupportedProtection
  }
}

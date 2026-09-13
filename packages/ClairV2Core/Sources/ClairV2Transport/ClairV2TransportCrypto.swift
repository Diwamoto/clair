import ClairV2Shared
import CryptoKit
import Foundation

enum ClairTransportValidation {
  static let maximumIdentifierBytes = 256
  static let maximumEndpointBytes = 2_048
  static let maximumDisplayNameBytes = 256
  static let maximumVisibleScopes = 256
  static let maximumDeviceGrants = 256
  static let maximumPendingChallenges = 1_024
  static let maximumPendingChallengesPerDevice = 4
  static let maximumActiveConnections = 1_024
  static let maximumProtocolVersionRanges = 16
  static let maximumCapabilities = 128
  static let defaultTokenLifetime: TimeInterval = 30 * 24 * 60 * 60
  static let maximumTokenLifetime: TimeInterval = 365 * 24 * 60 * 60
  static let secretBytes = 32
  static let signatureBytes = 64
  static let publicKeyBytes = 64
  static let privateKeyBytes = 32

  static func validateIdentifier(_ value: String) throws {
    guard !value.isEmpty,
      value.utf8.count <= maximumIdentifierBytes,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.unicodeScalars.allSatisfy({ scalar in
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x3A, 0x5F:
          true
        default:
          false
        }
      })
    else {
      throw ClairTransportError.invalidIdentifier
    }
  }

  static func validateDisplayName(_ value: String) throws {
    guard !value.isEmpty,
      value.utf8.count <= maximumDisplayNameBytes,
      value.unicodeScalars.allSatisfy({ scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F
      })
    else {
      throw ClairTransportError.invalidDisplayName
    }
  }

  static func validateDate(_ date: Date) throws {
    guard date.timeIntervalSince1970.isFinite else {
      throw ClairTransportError.invalidTimestamp
    }
  }

  static func decodeLimitedArray<Value: Decodable, Key: CodingKey>(
    _: Value.Type,
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key,
    maximum: Int,
    error failure: ClairTransportError
  ) throws -> [Value] {
    do {
      var nested = try container.nestedUnkeyedContainer(forKey: key)
      if let count = nested.count, count > maximum {
        throw failure
      }
      var values: [Value] = []
      if let count = nested.count {
        values.reserveCapacity(count)
      }
      while !nested.isAtEnd {
        guard values.count < maximum else { throw failure }
        values.append(try nested.decode(Value.self))
      }
      return values
    } catch let transportError as ClairTransportError {
      throw transportError
    } catch {
      throw failure
    }
  }

  private enum ProtocolOfferCodingKeys: String, CodingKey {
    case versionRanges = "version_ranges"
    case maximumFramePayloadBytes = "maximum_frame_payload_bytes"
    case capabilities
  }

  private enum NegotiatedProtocolCodingKeys: String, CodingKey {
    case version
    case maximumFramePayloadBytes = "maximum_frame_payload_bytes"
    case capabilities
  }

  static func decodeBoundedData<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key,
    maximum: Int,
    error failure: ClairTransportError
  ) throws -> Data {
    do {
      let encoded = try container.decode(String.self, forKey: key)
      let maximumEncodedBytes = ((maximum + 2) / 3) * 4
      guard encoded.utf8.count <= maximumEncodedBytes,
        let data = Data(base64Encoded: encoded),
        data.count <= maximum
      else {
        throw failure
      }
      return data
    } catch let transportError as ClairTransportError {
      throw transportError
    } catch {
      throw failure
    }
  }

  static func decodeCapabilitySet<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key,
    error failure: ClairTransportError
  ) throws -> CapabilitySet {
    do {
      var nested = try container.nestedUnkeyedContainer(forKey: key)
      if let count = nested.count, count > maximumCapabilities {
        throw failure
      }
      var values: [Capability] = []
      if let count = nested.count {
        values.reserveCapacity(count)
      }
      while !nested.isAtEnd {
        guard values.count < maximumCapabilities else { throw failure }
        values.append(try nested.decode(Capability.self))
      }
      return try CapabilitySet(values)
    } catch let transportError as ClairTransportError {
      throw transportError
    } catch {
      throw failure
    }
  }

  static func decodeProtocolOffer<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key
  ) throws -> ProtocolOffer {
    do {
      let nested = try container.nestedContainer(
        keyedBy: ProtocolOfferCodingKeys.self,
        forKey: key
      )
      let versionRanges = try decodeLimitedArray(
        ProtocolVersionRange.self,
        from: nested,
        forKey: .versionRanges,
        maximum: maximumProtocolVersionRanges,
        error: .invalidProtocolOffer
      )
      let maximumFramePayloadBytes = try nested.decode(
        Int.self,
        forKey: .maximumFramePayloadBytes
      )
      let capabilities = try decodeCapabilitySet(
        from: nested,
        forKey: .capabilities,
        error: .invalidProtocolOffer
      )
      return try ProtocolOffer(
        versionRanges: versionRanges,
        maximumFramePayloadBytes: maximumFramePayloadBytes,
        capabilities: capabilities
      )
    } catch let transportError as ClairTransportError {
      throw transportError
    } catch {
      throw ClairTransportError.invalidProtocolOffer
    }
  }

  static func decodeNegotiatedProtocol<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key
  ) throws -> NegotiatedProtocol {
    do {
      let nested = try container.nestedContainer(
        keyedBy: NegotiatedProtocolCodingKeys.self,
        forKey: key
      )
      let version = try nested.decode(ProtocolVersion.self, forKey: .version)
      let maximumFramePayloadBytes = try nested.decode(
        Int.self,
        forKey: .maximumFramePayloadBytes
      )
      let capabilities = try decodeCapabilitySet(
        from: nested,
        forKey: .capabilities,
        error: .invalidProtocolOffer
      )
      return try NegotiatedProtocol(
        version: version,
        maximumFramePayloadBytes: maximumFramePayloadBytes,
        capabilities: capabilities
      )
    } catch let transportError as ClairTransportError {
      throw transportError
    } catch {
      throw ClairTransportError.invalidProtocolOffer
    }
  }

  static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in 0..<left.count {
      difference |= left[index] ^ right[index]
    }
    return difference == 0
  }

  static func sha256Digest(_ value: Data) -> Data {
    Data(SHA256.hash(data: value))
  }

  static func randomBytes(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data(
      (0..<count).map { _ in
        UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
      })
  }

  static func hexadecimal(_ data: Data) -> String {
    let digits = Array("0123456789abcdef".utf8)
    return data.reduce(into: String()) { result, byte in
      result.append(Character(UnicodeScalar(digits[Int(byte >> 4)])))
      result.append(Character(UnicodeScalar(digits[Int(byte & 0x0F)])))
    }
  }

  static func timestampMilliseconds(_ date: Date) throws -> Int64 {
    try validateDate(date)
    let seconds = date.timeIntervalSince1970
    guard seconds >= 0 else {
      throw ClairTransportError.invalidTimestamp
    }
    let milliseconds = seconds * 1_000
    guard milliseconds.isFinite, milliseconds >= 0 else {
      throw ClairTransportError.invalidTimestamp
    }
    let truncated = milliseconds.rounded(.towardZero)
    guard truncated < Double(Int64.max),
      let result = Int64(exactly: truncated)
    else {
      throw ClairTransportError.invalidTimestamp
    }
    return result
  }
}

/// Stable host identity used for application-level fingerprint pinning.
public struct ClairHostID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try ClairTransportValidation.validateIdentifier(rawValue)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public static func random() -> Self {
    try! Self(UUID().uuidString.lowercased())
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

/// Stable per-pairing device identity. It is not a secret.
public struct ClairDeviceID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try ClairTransportValidation.validateIdentifier(rawValue)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public static func random() -> Self {
    try! Self(UUID().uuidString.lowercased())
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

/// Connection-local identity. It is never used as authorization by itself.
public struct ClairConnectionID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try ClairTransportValidation.validateIdentifier(rawValue)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  static func random() -> Self {
    try! Self(UUID().uuidString.lowercased())
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

/// Pairing and challenge identifiers are public correlation metadata, not credentials.
public struct ClairPairingID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try ClairTransportValidation.validateIdentifier(rawValue)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  static func random() -> Self {
    try! Self(UUID().uuidString.lowercased())
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

public struct ClairChallengeID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try ClairTransportValidation.validateIdentifier(rawValue)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  static func random() -> Self {
    try! Self(UUID().uuidString.lowercased())
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

/// A high-entropy bootstrap value. Its description intentionally never exposes bytes.
public struct ClairBootstrapSecret: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let bytes: Data

  private enum CodingKeys: String, CodingKey {
    case bytes
  }

  public init(rawRepresentation: Data) throws {
    guard rawRepresentation.count == ClairTransportValidation.secretBytes else {
      throw ClairTransportError.invalidSecret
    }
    self.bytes = rawRepresentation
  }

  public static func random() -> Self {
    try! Self(
      rawRepresentation: ClairTransportValidation.randomBytes(
        count: ClairTransportValidation.secretBytes
      ))
  }

  public var rawRepresentation: Data { bytes }
  public var description: String { "<redacted-bootstrap-secret>" }
  public var debugDescription: String { description }

  public func matches(_ other: Self) -> Bool {
    ClairTransportValidation.constantTimeEqual(bytes, other.bytes)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      rawRepresentation: ClairTransportValidation.decodeBoundedData(
        from: container,
        forKey: .bytes,
        maximum: ClairTransportValidation.secretBytes,
        error: .invalidSecret
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(bytes, forKey: .bytes)
  }
}

/// An opaque, per-device bearer value. It is always paired with device-key proof.
public struct ClairDeviceToken: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let bytes: Data

  private enum CodingKeys: String, CodingKey {
    case bytes
  }

  public init(rawRepresentation: Data) throws {
    guard rawRepresentation.count == ClairTransportValidation.secretBytes else {
      throw ClairTransportError.invalidToken
    }
    self.bytes = rawRepresentation
  }

  public static func random() -> Self {
    try! Self(
      rawRepresentation: ClairTransportValidation.randomBytes(
        count: ClairTransportValidation.secretBytes
      ))
  }

  public var rawRepresentation: Data { bytes }
  public var description: String { "<redacted-device-token>" }
  public var debugDescription: String { description }
  var digest: Data { ClairTransportValidation.sha256Digest(bytes) }

  public func matches(_ other: Self) -> Bool {
    ClairTransportValidation.constantTimeEqual(bytes, other.bytes)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      rawRepresentation: ClairTransportValidation.decodeBoundedData(
        from: container,
        forKey: .bytes,
        maximum: ClairTransportValidation.secretBytes,
        error: .invalidToken
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(bytes, forKey: .bytes)
  }
}

/// A P-256 signing public key. The raw representation is public identity material.
public struct ClairDevicePublicKey: Codable, Equatable, Hashable, Sendable {
  public let rawRepresentation: Data

  private enum CodingKeys: String, CodingKey {
    case rawRepresentation
  }

  public init(rawRepresentation: Data) throws {
    guard rawRepresentation.count == ClairTransportValidation.publicKeyBytes else {
      throw ClairTransportError.invalidDeviceKey
    }
    do {
      _ = try P256.Signing.PublicKey(rawRepresentation: rawRepresentation)
    } catch {
      throw ClairTransportError.invalidDeviceKey
    }
    self.rawRepresentation = rawRepresentation
  }

  func verifies(signature: Data, for message: Data) -> Bool {
    guard signature.count == ClairTransportValidation.signatureBytes,
      let key = try? P256.Signing.PublicKey(rawRepresentation: rawRepresentation),
      let ecdsaSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
    else {
      return false
    }
    return key.isValidSignature(ecdsaSignature, for: message)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      rawRepresentation: ClairTransportValidation.decodeBoundedData(
        from: container,
        forKey: .rawRepresentation,
        maximum: ClairTransportValidation.publicKeyBytes,
        error: .invalidDeviceKey
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(rawRepresentation, forKey: .rawRepresentation)
  }
}

/// An in-memory signing key used by the transport seam until Keychain/Secure Enclave
/// storage is added by the native client task. It has no Codable representation.
public struct ClairDeviceKey: @unchecked Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  private let key: P256.Signing.PrivateKey

  public init() {
    self.key = P256.Signing.PrivateKey()
  }

  public init(rawRepresentation: Data) throws {
    guard rawRepresentation.count == ClairTransportValidation.privateKeyBytes else {
      throw ClairTransportError.invalidDeviceKey
    }
    do {
      self.key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    } catch {
      throw ClairTransportError.invalidDeviceKey
    }
  }

  public var publicKey: ClairDevicePublicKey {
    try! ClairDevicePublicKey(rawRepresentation: key.publicKey.rawRepresentation)
  }

  public var rawRepresentation: Data { key.rawRepresentation }

  public var description: String { "<redacted-device-private-key>" }
  public var debugDescription: String { description }

  public func sign(_ message: Data) throws -> Data {
    do {
      return try key.signature(for: message).rawRepresentation
    } catch {
      throw ClairTransportError.invalidSignature
    }
  }
}

/// Host signing key used to derive a stable application fingerprint. The private
/// representation is intentionally not Codable or printable.
public struct ClairHostSigningKey: @unchecked Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  private let key: P256.Signing.PrivateKey

  public init() {
    self.key = P256.Signing.PrivateKey()
  }

  public init(rawRepresentation: Data) throws {
    guard rawRepresentation.count == ClairTransportValidation.privateKeyBytes else {
      throw ClairTransportError.invalidHostKey
    }
    do {
      self.key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    } catch {
      throw ClairTransportError.invalidHostKey
    }
  }

  public var publicKey: ClairHostPublicKey {
    try! ClairHostPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
  }

  public var rawRepresentation: Data { key.rawRepresentation }

  public var description: String { "<redacted-host-private-key>" }
  public var debugDescription: String { description }
}

public struct ClairHostPublicKey: Codable, Equatable, Hashable, Sendable {
  public let rawRepresentation: Data

  private enum CodingKeys: String, CodingKey {
    case rawRepresentation
  }

  public init(rawRepresentation: Data) throws {
    guard rawRepresentation.count == ClairTransportValidation.publicKeyBytes else {
      throw ClairTransportError.invalidHostKey
    }
    do {
      _ = try P256.Signing.PublicKey(rawRepresentation: rawRepresentation)
    } catch {
      throw ClairTransportError.invalidHostKey
    }
    self.rawRepresentation = rawRepresentation
  }

  public var fingerprint: ClairHostFingerprint {
    ClairHostFingerprint(publicKey: self)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      rawRepresentation: ClairTransportValidation.decodeBoundedData(
        from: container,
        forKey: .rawRepresentation,
        maximum: ClairTransportValidation.publicKeyBytes,
        error: .invalidHostKey
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(rawRepresentation, forKey: .rawRepresentation)
  }
}

/// Lowercase SHA-256 fingerprint of a host public-key raw representation.
public struct ClairHostFingerprint: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard rawValue.count == 64,
      rawValue.unicodeScalars.allSatisfy({ scalar in
        switch scalar.value {
        case 0x30...0x39, 0x61...0x66:
          true
        default:
          false
        }
      })
    else {
      throw ClairTransportError.invalidFingerprint
    }
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  init(publicKey: ClairHostPublicKey) {
    let digest = SHA256.hash(data: publicKey.rawRepresentation)
    self.rawValue = ClairTransportValidation.hexadecimal(Data(digest))
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

import Foundation

public enum ClairPushError: String, Error, LocalizedError, Sendable {
  case invalidInput
  case payloadTooLarge
  case expired
  case futureEvent
  case unauthorized
  case registrationRequired
  case staleGeneration
  case conflictingDuplicate
  case capacityExceeded
  case credentialUnavailable
  case credentialRejected
  case storeUnavailable

  public var errorDescription: String? { "Push request failed: \(rawValue)." }
}

public enum ClairPushEnvironment: String, Codable, CaseIterable, Sendable {
  case sandbox
  case production
}

public enum ClairPushTopic: String, Codable, Sendable {
  case mobile = "com.diwamoto.clair.mobile"
}

public enum ClairPushEventKind: String, Codable, Sendable {
  case attention
  case completion
}

public protocol ClairPushClock: Sendable {
  func now() -> Date
}

public struct ClairSystemPushClock: ClairPushClock {
  public init() {}
  public func now() -> Date { Date() }
}

public enum ClairPushBounds {
  public static let maximumPayloadBytes = 1024
  public static let maximumTTL: UInt64 = 300
  public static let maximumTimestamp: UInt64 = 253_402_300_799
  public static let maximumTokenBytes = 256
  public static let maximumRegistrationTTL: UInt64 = 30 * 24 * 60 * 60

  public static func timestamp(_ date: Date) throws -> UInt64 {
    let value = date.timeIntervalSince1970
    guard value.isFinite, value >= 0, value <= Double(maximumTimestamp) else {
      throw ClairPushError.invalidInput
    }
    return UInt64(value.rounded(.down))
  }
}

/// A token is routing material, never a wire payload or diagnostic value.
public struct ClairPushDeviceToken: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private let bytes: Data

  public init(_ bytes: Data) throws {
    guard !bytes.isEmpty, bytes.count <= ClairPushBounds.maximumTokenBytes else {
      throw ClairPushError.invalidInput
    }
    self.bytes = bytes
  }

  /// Available only to a protected routing/provider adapter. Do not log it.
  public func withBytes<T>(_ body: (Data) throws -> T) rethrows -> T {
    try body(bytes)
  }

  public var description: String { "ClairPushDeviceToken(<redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Fixed-size references intentionally cannot contain B03's free-form IDs.
/// Event details always come from an authenticated daemon resync.
public struct ClairPushEvent: Codable, Equatable, Sendable {
  public let host: UUID
  public let resource: UUID
  public let wake: UUID
  public let kind: ClairPushEventKind
  public let epoch: UInt64
  public let revision: UInt64
  public let issuedAt: UInt64
  public let expiresAt: UInt64

  public init(
    host: UUID, resource: UUID, wake: UUID, kind: ClairPushEventKind,
    epoch: UInt64, revision: UInt64, issuedAt: UInt64, ttl: UInt64
  ) throws {
    guard epoch > 0, ttl > 0, ttl <= ClairPushBounds.maximumTTL,
      issuedAt <= ClairPushBounds.maximumTimestamp - ttl
    else { throw ClairPushError.invalidInput }
    self.host = host
    self.resource = resource
    self.wake = wake
    self.kind = kind
    self.epoch = epoch
    self.revision = revision
    self.issuedAt = issuedAt
    self.expiresAt = issuedAt + ttl
  }

  public func validate(at now: UInt64) throws {
    guard now <= ClairPushBounds.maximumTimestamp else { throw ClairPushError.invalidInput }
    guard now >= issuedAt else { throw ClairPushError.futureEvent }
    guard now < expiresAt else { throw ClairPushError.expired }
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case host, resource, wake, kind, epoch, revision, issuedAt, expiresAt
  }

  private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  public init(from decoder: Decoder) throws {
    do {
      let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
      guard Set(keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
        throw ClairPushError.invalidInput
      }
      let values = try decoder.container(keyedBy: CodingKeys.self)
      let issuedAt = try values.decode(UInt64.self, forKey: .issuedAt)
      let expiresAt = try values.decode(UInt64.self, forKey: .expiresAt)
      guard expiresAt > issuedAt else { throw ClairPushError.invalidInput }
      try self.init(
        host: values.decode(UUID.self, forKey: .host),
        resource: values.decode(UUID.self, forKey: .resource),
        wake: values.decode(UUID.self, forKey: .wake),
        kind: values.decode(ClairPushEventKind.self, forKey: .kind),
        epoch: values.decode(UInt64.self, forKey: .epoch),
        revision: values.decode(UInt64.self, forKey: .revision),
        issuedAt: issuedAt, ttl: expiresAt - issuedAt
      )
    } catch { throw ClairPushError.invalidInput }
  }

  /// The only untrusted-byte entry point: bound before parsing, redact errors.
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= ClairPushBounds.maximumPayloadBytes else {
      throw ClairPushError.payloadTooLarge
    }
    do { return try JSONDecoder().decode(Self.self, from: data) } catch {
      throw ClairPushError.invalidInput
    }
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count <= ClairPushBounds.maximumPayloadBytes else {
      throw ClairPushError.payloadTooLarge
    }
    return data
  }
}

/// Trusted daemon-to-relay admission value, not a remotely decodable request.
/// A future network adapter must authenticate its daemon before constructing it.
public struct ClairPushDelivery: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let device: UUID
  public let environment: ClairPushEnvironment
  public let topic: ClairPushTopic
  public let generation: UInt64
  public let token: ClairPushDeviceToken
  public let event: ClairPushEvent

  public init(
    device: UUID, environment: ClairPushEnvironment, topic: ClairPushTopic = .mobile,
    generation: UInt64, token: ClairPushDeviceToken, event: ClairPushEvent
  ) throws {
    guard generation > 0 else { throw ClairPushError.invalidInput }
    self.device = device
    self.environment = environment
    self.topic = topic
    self.generation = generation
    self.token = token
    self.event = event
  }

  public var description: String { "ClairPushDelivery(<redacted routing>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum ClairPushProviderStatus: String, Equatable, Sendable {
  case accepted
  case invalidToken
  case environmentMismatch
  case credentialRejected
  case rateLimited
  case unavailable
}

public struct ClairPushDeliveryResult: Equatable, Sendable {
  public let status: ClairPushProviderStatus
  public let isDuplicate: Bool

  public init(status: ClairPushProviderStatus, isDuplicate: Bool = false) {
    self.status = status
    self.isDuplicate = isDuplicate
  }
}

/// Implementations must perform bounded, synchronous, non-reentrant admission.
public protocol ClairPushSending: Sendable {
  func send(_ delivery: ClairPushDelivery) throws -> ClairPushDeliveryResult
}

public protocol ClairPushProvider: Sendable {
  func submit(_ delivery: ClairPushDelivery, at now: UInt64) throws -> ClairPushProviderStatus
}

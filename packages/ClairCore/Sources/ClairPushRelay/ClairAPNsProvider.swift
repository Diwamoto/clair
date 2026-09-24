import ClairPush
import Foundation

/// Secret material exists only in the relay target and is never Codable.
public struct ClairAPNsCredential: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let environment: ClairPushEnvironment
  public let topic: ClairPushTopic
  public let generation: UInt64
  public let expiresAt: UInt64
  private let keyID: String
  private let teamID: String
  private let privateKey: Data

  public init(
    environment: ClairPushEnvironment, topic: ClairPushTopic = .mobile,
    generation: UInt64, expiresAt: UInt64, keyID: String, teamID: String, privateKey: Data
  ) throws {
    func validIdentifier(_ value: String) -> Bool {
      value.utf8.count == 10
        && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
    guard generation > 0, expiresAt > 0, expiresAt <= ClairPushBounds.maximumTimestamp,
      validIdentifier(keyID), validIdentifier(teamID),
      !privateKey.isEmpty, privateKey.count <= 4096
    else { throw ClairPushError.invalidInput }
    self.environment = environment
    self.topic = topic
    self.generation = generation
    self.expiresAt = expiresAt
    self.keyID = keyID
    self.teamID = teamID
    self.privateKey = privateKey
  }

  /// A future signing adapter consumes these bytes inside protected-store use.
  public func withSigningMaterial<T>(
    _ body: (_ keyID: String, _ teamID: String, _ privateKey: Data) throws -> T
  ) rethrows -> T {
    try body(keyID, teamID, privateKey)
  }

  public var description: String { "ClairAPNsCredential(<redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Store adapters must serialize the entire use with rotation and revoke.
/// They must not cache/copy a credential outside the synchronous callback.
public protocol ClairAPNsCredentialStore: Sendable {
  func withCredential(
    environment: ClairPushEnvironment, topic: ClairPushTopic,
    expectedGeneration: UInt64?, at now: UInt64,
    _ body: (ClairAPNsCredential) throws -> ClairPushProviderStatus
  ) throws -> ClairPushProviderStatus
}

/// Deterministic protected-store fixture; never writes a key to disk.
public final class ClairInMemoryAPNsCredentialStore: ClairAPNsCredentialStore,
  @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  private struct Record {
    let generation: UInt64
    let credential: ClairAPNsCredential?
  }
  private let lock = NSLock()
  private var records: [ClairPushEnvironment: Record] = [:]
  private var available = true

  public init() {}

  public func setAvailable(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    available = value
  }

  public func rotate(to credential: ClairAPNsCredential) throws {
    lock.lock()
    defer { lock.unlock() }
    guard available else { throw ClairPushError.storeUnavailable }
    guard credential.generation > (records[credential.environment]?.generation ?? 0) else {
      throw ClairPushError.staleGeneration
    }
    records[credential.environment] = Record(
      generation: credential.generation, credential: credential
    )
  }

  public func revoke(environment: ClairPushEnvironment, generation: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    guard available else { throw ClairPushError.storeUnavailable }
    guard let record = records[environment], record.generation == generation else {
      throw ClairPushError.staleGeneration
    }
    records[environment] = Record(generation: generation, credential: nil)
  }

  public func withCredential(
    environment: ClairPushEnvironment, topic: ClairPushTopic = .mobile,
    expectedGeneration: UInt64? = nil, at now: UInt64,
    _ body: (ClairAPNsCredential) throws -> ClairPushProviderStatus
  ) throws -> ClairPushProviderStatus {
    lock.lock()
    defer { lock.unlock() }
    guard available else { throw ClairPushError.storeUnavailable }
    guard now <= ClairPushBounds.maximumTimestamp else { throw ClairPushError.invalidInput }
    guard let record = records[environment], let credential = record.credential else {
      throw ClairPushError.credentialUnavailable
    }
    guard expectedGeneration == nil || record.generation == expectedGeneration,
      credential.environment == environment, credential.topic == topic
    else { throw ClairPushError.credentialRejected }
    guard now < credential.expiresAt else { throw ClairPushError.credentialRejected }
    return try body(credential)
  }

  public var description: String { "ClairInMemoryAPNsCredentialStore(<protected>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct ClairAPNsRequest: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let environment: ClairPushEnvironment
  public let topic: ClairPushTopic
  public let token: ClairPushDeviceToken
  public let expiration: UInt64
  public let payload: Data
  public var endpoint: URL {
    switch environment {
    case .sandbox: URL(string: "https://api.sandbox.push.apple.com")!
    case .production: URL(string: "https://api.push.apple.com")!
    }
  }
  public var pushType: String { "background" }
  public var priority: Int { 5 }

  init(_ delivery: ClairPushDelivery) throws {
    environment = delivery.environment
    topic = delivery.topic
    token = delivery.token
    expiration = delivery.event.expiresAt
    struct Body: Encodable {
      struct APS: Encodable {
        let contentAvailable = 1
        enum CodingKeys: String, CodingKey { case contentAvailable = "content-available" }
      }
      let aps = APS()
      let clair: ClairPushEvent
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(Body(clair: delivery.event))
    guard bytes.count <= ClairPushBounds.maximumPayloadBytes else {
      throw ClairPushError.payloadTooLarge
    }
    payload = bytes
  }

  public var description: String { "ClairAPNsRequest(<redacted routing>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The future HTTP2/JWT adapter returns classifications, never APNs body text.
/// No network implementation is installed by H09.
public protocol ClairAPNsTransport: Sendable {
  func submit(
    _ request: ClairAPNsRequest, credential: ClairAPNsCredential
  ) throws -> ClairPushProviderStatus
}

public struct ClairAPNsProvider: ClairPushProvider {
  private let store: any ClairAPNsCredentialStore
  private let transport: any ClairAPNsTransport

  public init(store: any ClairAPNsCredentialStore, transport: any ClairAPNsTransport) {
    self.store = store
    self.transport = transport
  }

  public func submit(
    _ delivery: ClairPushDelivery, at now: UInt64
  ) throws -> ClairPushProviderStatus {
    try delivery.event.validate(at: now)
    let request = try ClairAPNsRequest(delivery)
    do {
      return try store.withCredential(
        environment: delivery.environment, topic: delivery.topic,
        expectedGeneration: nil, at: now
      ) { credential in
        // Revalidate an injected store's result at the provider boundary too.
        guard credential.environment == delivery.environment,
          credential.topic == delivery.topic, now < credential.expiresAt
        else { return .credentialRejected }
        return try transport.submit(request, credential: credential)
      }
    } catch ClairPushError.credentialRejected {
      return .credentialRejected
    } catch {
      return .unavailable
    }
  }
}

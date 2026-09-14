import ClairV2Push
import CryptoKit
import Foundation

/// Provider-independent, in-memory relay. It retains only bounded digests and
/// outcomes; routing tokens, events and provider errors are not retained.
public final class ClairPushRelay: ClairPushSending, @unchecked Sendable {
  private struct Key: Hashable {
    let host: UUID
    let device: UUID
    let environment: ClairPushEnvironment
    let topic: ClairPushTopic
    let wake: UUID
  }

  private struct Entry {
    let digest: Data
    let expiresAt: UInt64
    let status: ClairPushProviderStatus
  }

  private let lock = NSLock()
  private let provider: any ClairPushProvider
  private let clock: any ClairPushClock
  private let capacity: Int
  private var entries: [Key: Entry] = [:]

  public init(
    provider: any ClairPushProvider,
    clock: any ClairPushClock = ClairSystemPushClock(), capacity: Int = 4096
  ) throws {
    guard (1...65_536).contains(capacity) else { throw ClairPushError.invalidInput }
    self.provider = provider
    self.clock = clock
    self.capacity = capacity
  }

  public func send(_ delivery: ClairPushDelivery) throws -> ClairPushDeliveryResult {
    lock.lock()
    defer { lock.unlock() }
    let now = try ClairPushBounds.timestamp(clock.now())
    try delivery.event.validate(at: now)
    entries = entries.filter { $0.value.expiresAt > now }
    let key = Key(
      host: delivery.event.host, device: delivery.device,
      environment: delivery.environment, topic: delivery.topic, wake: delivery.event.wake
    )
    var hasher = SHA256()
    hasher.update(data: try delivery.event.encoded())
    var generation = delivery.generation.bigEndian
    withUnsafeBytes(of: &generation) { hasher.update(data: Data($0)) }
    delivery.token.withBytes { hasher.update(data: $0) }
    let digest = Data(hasher.finalize())
    if let entry = entries[key] {
      guard entry.digest == digest else { throw ClairPushError.conflictingDuplicate }
      return ClairPushDeliveryResult(status: entry.status, isDuplicate: true)
    }
    guard entries.count < capacity else { throw ClairPushError.capacityExceeded }

    // Never retry an ambiguous provider failure automatically. The same wake
    // remains deduplicated until its original expiry, even after rotation.
    let status: ClairPushProviderStatus
    do {
      status = try provider.submit(delivery, at: now)
    } catch {
      status = .unavailable
    }
    entries[key] = Entry(digest: digest, expiresAt: delivery.event.expiresAt, status: status)
    return ClairPushDeliveryResult(status: status)
  }
}

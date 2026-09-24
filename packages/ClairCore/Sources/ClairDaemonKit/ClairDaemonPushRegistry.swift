import ClairAgent
import ClairPush
import ClairShared
import ClairTransport
import CryptoKit
import Foundation

public struct ClairPushRegistrationSnapshot: Equatable, Sendable {
  public let generation: UInt64
  public let grantGeneration: UInt64
  public let scope: ResourceScope
  public let environment: ClairPushEnvironment
  public let lastSeen: UInt64
  public let expiresAt: UInt64
  public let requiresRegistration: Bool
}

/// Host-only projection: inspect a normalized kind, then discard its payload.
/// No full agent event is ever passed into the relay module.
public struct ClairDaemonPushEvent: Sendable {
  public let scope: ResourceScope
  public let event: ClairPushEvent

  public init?(
    normalized: ClairAgentNormalizedEvent, host: ClairHostIdentity,
    issuedAt: UInt64, ttl: UInt64 = 60
  ) throws {
    let kind: ClairPushEventKind
    switch normalized.payload {
    case .attention: kind = .attention
    case .completion: kind = .completion
    default: return nil
    }
    guard normalized.kind.rawValue == "agent.\(kind.rawValue)",
      let epoch = normalized.epoch, let revision = normalized.revision,
      normalized.scope.sessionID != nil
    else { throw ClairPushError.invalidInput }
    scope = normalized.scope
    let hostReference = pushHostReference(host)
    let scopeBytes = try pushScopeBytes(scope)
    event = try ClairPushEvent(
      host: hostReference,
      resource: pushReference([Data(hostReference.uuidString.utf8), scopeBytes]),
      wake: pushReference([
        Data(hostReference.uuidString.utf8), scopeBytes,
        Data(normalized.eventID.rawValue.utf8), Data(String(epoch.value).utf8),
      ]),
      kind: kind, epoch: epoch.value, revision: revision.value,
      issuedAt: issuedAt, ttl: ttl
    )
  }
}

/// Bound to one H03 authority. All state accesses occur on that actor, with no
/// suspension between authority checks, registry changes and relay admission.
/// APNs provider credentials are not a dependency of this module.
public final class ClairDaemonPushRegistry: @unchecked Sendable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  private struct Key: Hashable {
    let device: ClairDeviceID
    let environment: ClairPushEnvironment
  }
  private struct Record {
    let generation: UInt64
    let grantGeneration: UInt64
    let scope: ResourceScope
    var token: ClairPushDeviceToken?
    let lastSeen: UInt64
    let expiresAt: UInt64

    func snapshot(_ environment: ClairPushEnvironment) -> ClairPushRegistrationSnapshot {
      ClairPushRegistrationSnapshot(
        generation: generation, grantGeneration: grantGeneration, scope: scope,
        environment: environment, lastSeen: lastSeen, expiresAt: expiresAt,
        requiresRegistration: token == nil
      )
    }
  }

  private let authority: ClairPairingAuthority
  private let relay: any ClairPushSending
  private let clock: any ClairPushClock
  private let capacity: Int
  private var records: [Key: Record] = [:]

  public init(
    authority: ClairPairingAuthority, relay: any ClairPushSending,
    clock: any ClairPushClock = ClairSystemPushClock(), capacity: Int = 1024
  ) throws {
    guard (1...4096).contains(capacity) else { throw ClairPushError.invalidInput }
    self.authority = authority
    self.relay = relay
    self.clock = clock
    self.capacity = capacity
  }

  public func register(
    token: ClairPushDeviceToken, generation: UInt64, environment: ClairPushEnvironment,
    scope: ResourceScope, ttl: UInt64 = ClairPushBounds.maximumRegistrationTTL,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairPushRegistrationSnapshot {
    try await authority.withPushAdmission { authority in
      let now = try ClairPushBounds.timestamp(self.clock.now())
      guard generation > 0, ttl > 0, ttl <= ClairPushBounds.maximumRegistrationTTL,
        now <= ClairPushBounds.maximumTimestamp - ttl
      else { throw ClairPushError.invalidInput }
      do { try authority.authorizeRead(scope: scope, on: connection) } catch {
        throw ClairPushError.unauthorized
      }
      let grant = try self.authorizedGrant(
        authority, device: connection.deviceID, generation: connection.generation,
        scope: scope, at: now
      )
      let key = Key(device: connection.deviceID, environment: environment)
      self.expire(key, at: now)
      if let previous = self.records[key] {
        guard generation >= previous.generation else { throw ClairPushError.staleGeneration }
        if generation == previous.generation {
          guard previous.token == token, previous.scope == scope,
            previous.grantGeneration == grant.generation
          else { throw ClairPushError.staleGeneration }
          return previous.snapshot(environment)
        }
      } else if self.records.count >= self.capacity {
        throw ClairPushError.capacityExceeded
      }
      let grantExpiry = try ClairPushBounds.timestamp(grant.tokenExpiresAt)
      let record = Record(
        generation: generation, grantGeneration: grant.generation,
        scope: scope, token: token, lastSeen: now, expiresAt: min(now + ttl, grantExpiry)
      )
      guard now < record.expiresAt else { throw ClairPushError.expired }
      self.records[key] = record
      return record.snapshot(environment)
    }
  }

  /// Authenticated unregister affects only this device/environment/generation.
  public func unregister(
    environment: ClairPushEnvironment, generation: UInt64,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    try await authority.withPushAdmission { authority in
      let key = Key(device: connection.deviceID, environment: environment)
      guard let record = self.records[key] else { throw ClairPushError.registrationRequired }
      do { try authority.authorizeRead(scope: record.scope, on: connection) } catch {
        throw ClairPushError.unauthorized
      }
      guard generation == record.generation else { throw ClairPushError.staleGeneration }
      self.records[key]?.token = nil
    }
  }

  /// Trusted host-owner revoke entry point; H03 is still the grant authority.
  @discardableResult
  public func revoke(device: ClairDeviceID) async throws -> ClairRevocation {
    try await authority.withPushAdmission { authority in
      let revocation: ClairRevocation
      do { revocation = try authority.revoke(deviceID: device) } catch {
        throw ClairPushError.unauthorized
      }
      for key in self.records.keys where key.device == device {
        self.records[key]?.token = nil
      }
      return revocation
    }
  }

  public func send(
    _ event: ClairDaemonPushEvent, to device: ClairDeviceID,
    environment: ClairPushEnvironment
  ) async throws -> ClairPushDeliveryResult {
    try await authority.withPushAdmission { authority in
      let now = try ClairPushBounds.timestamp(self.clock.now())
      try event.event.validate(at: now)
      guard event.event.host == pushHostReference(authority.hostIdentity) else {
        throw ClairPushError.unauthorized
      }
      let key = Key(device: device, environment: environment)
      self.expire(key, at: now)
      guard let record = self.records[key], let token = record.token else {
        throw ClairPushError.registrationRequired
      }
      do {
        _ = try self.authorizedGrant(
          authority, device: device, generation: record.grantGeneration,
          scope: event.scope, at: now
        )
      } catch {
        // Clear only invalid grants; a wrong-scope request cannot erase a
        // valid subscription and cause a denial of service.
        let grantRemainsValid: Bool
        if let grant = authority.grant(for: device) {
          grantRemainsValid =
            !grant.isRevoked
            && grant.generation == record.grantGeneration
            && !grant.isTokenExpired(at: self.clock.now())
        } else {
          grantRemainsValid = false
        }
        if !grantRemainsValid {
          self.records[key]?.token = nil
        }
        throw ClairPushError.unauthorized
      }
      guard record.scope.contains(event.scope) else { throw ClairPushError.unauthorized }
      let delivery = try ClairPushDelivery(
        device: pushReference([
          Data(event.event.host.uuidString.utf8), Data(device.rawValue.utf8),
        ]),
        environment: environment, generation: record.generation,
        token: token, event: event.event
      )
      let result: ClairPushDeliveryResult
      do { result = try self.relay.send(delivery) } catch let error as ClairPushError {
        throw error
      } catch {
        return ClairPushDeliveryResult(status: .unavailable)
      }
      if result.status == .invalidToken || result.status == .environmentMismatch {
        self.records[key]?.token = nil
      }
      return result
    }
  }

  public func snapshot(
    device: ClairDeviceID, environment: ClairPushEnvironment
  ) async throws -> ClairPushRegistrationSnapshot? {
    try await authority.withPushAdmission { authority in
      let now = try ClairPushBounds.timestamp(self.clock.now())
      let key = Key(device: device, environment: environment)
      self.expire(key, at: now)
      if let record = self.records[key] {
        do {
          _ = try self.authorizedGrant(
            authority, device: device, generation: record.grantGeneration,
            scope: record.scope, at: now
          )
        } catch { self.records[key]?.token = nil }
      }
      return self.records[key]?.snapshot(environment)
    }
  }

  private func expire(_ key: Key, at now: UInt64) {
    if let record = records[key], now >= record.expiresAt { records[key]?.token = nil }
  }

  private func authorizedGrant(
    _ authority: isolated ClairPairingAuthority, device: ClairDeviceID,
    generation: UInt64, scope: ResourceScope, at now: UInt64
  ) throws -> ClairDeviceGrant {
    guard let grant = authority.grant(for: device),
      grant.hostID == authority.hostIdentity.hostID,
      !grant.isRevoked, grant.generation == generation,
      !grant.isTokenExpired(at: Date(timeIntervalSince1970: Double(now)))
    else { throw ClairPushError.unauthorized }
    do {
      try AccessBoundary(capabilities: grant.capabilities, visibleScopes: grant.visibleScopes)
        .authorize(scope: scope, requiring: .view)
    } catch { throw ClairPushError.unauthorized }
    return grant
  }

  /// A count only, for H10 structured diagnostics. Never exposes a device
  /// identity, token, or scope. `records` is otherwise only ever touched
  /// while isolated to `authority` (every mutating method above runs inside
  /// `authority.withPushAdmission`), so this read joins the same isolation
  /// domain instead of racing those mutations from an arbitrary caller task.
  public func registrationCount() async -> Int {
    await authority.withPushAdmission { _ in self.records.count }
  }

  public var description: String { "ClairDaemonPushRegistry(<protected>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension ClairPairingAuthority {
  fileprivate func withPushAdmission<T: Sendable>(
    _ body: @Sendable (isolated ClairPairingAuthority) throws -> T
  ) rethrows -> T {
    try body(self)
  }
}

private func pushHostReference(_ host: ClairHostIdentity) -> UUID {
  pushReference([Data(host.hostID.rawValue.utf8), Data(host.fingerprint.rawValue.utf8)])
}

private func pushScopeBytes(_ scope: ResourceScope) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(scope)
}

private func pushReference(_ parts: [Data]) -> UUID {
  var hasher = SHA256()
  for part in parts {
    var length = UInt64(part.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
    hasher.update(data: part)
  }
  let bytes = Array(hasher.finalize().prefix(16))
  return UUID(
    uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
  )
}

import ClairV2Shared
import ClairV2Transport
import Foundation

/// The user-facing connection states for the small host-management surface.
/// These deliberately distinguish trust failures from reachability failures.
public enum ClairMobileHostConnectionState: String, Equatable, Sendable {
  case offline
  case pairing
  case connected
  case reconnecting
  case expired
  case fingerprintChanged
  case revoked
  case failed
}

public struct ClairMobileHostRecord: Equatable, Identifiable, Sendable {
  public let id: ClairHostID
  public let fingerprint: ClairHostFingerprint
  public let endpoint: ClairTransportEndpoint
  public let deviceID: ClairDeviceID?
  public let displayName: String?
  public let scopes: [ResourceScope]
  public let connection: ClairMobileHostConnectionState
  public let credentialExpiresAt: Date?

  public init(
    id: ClairHostID,
    fingerprint: ClairHostFingerprint,
    endpoint: ClairTransportEndpoint,
    deviceID: ClairDeviceID? = nil,
    displayName: String? = nil,
    scopes: [ResourceScope] = [],
    connection: ClairMobileHostConnectionState = .offline,
    credentialExpiresAt: Date? = nil
  ) {
    self.id = id
    self.fingerprint = fingerprint
    self.endpoint = endpoint
    self.deviceID = deviceID
    self.displayName = displayName
    self.scopes = scopes
    self.connection = connection
    self.credentialExpiresAt = credentialExpiresAt
  }
}

public struct ClairMobilePairingPresentation: Equatable, Sendable {
  public enum State: String, Equatable, Sendable {
    case ready
    case expired
    case fingerprintChanged
  }

  public let hostID: ClairHostID
  public let fingerprint: ClairHostFingerprint
  public let expiresAt: Date
  public private(set) var state: State

  public init(link: ClairPairingLink, now: Date = Date()) {
    hostID = link.hostID
    fingerprint = link.hostFingerprint
    expiresAt = link.expiresAt
    state = link.isExpired(at: now) ? .expired : .ready
  }

  public func validating(presentation: ClairHostPresentation) -> Self {
    guard presentation.hostID == hostID, presentation.fingerprint == fingerprint else {
      var copy = self
      copy.state = .fingerprintChanged
      return copy
    }
    return self
  }
}

/// Redacted, value-type state used by the SwiftUI host list. Credentials,
/// private keys, pairing secrets, and authenticated handles never enter this
/// state.
public struct ClairMobileHostManagementState: Equatable, Sendable {
  public private(set) var hosts: [ClairMobileHostRecord]
  public private(set) var pairing: ClairMobilePairingPresentation?

  public init(hosts: [ClairMobileHostRecord] = []) {
    self.hosts = hosts
  }

  public mutating func presentPairing(_ link: ClairPairingLink, now: Date = Date()) {
    pairing = ClairMobilePairingPresentation(link: link, now: now)
  }

  public mutating func clearPairing() {
    pairing = nil
  }

  /// Removes local trust after the user revokes this device. The remote
  /// authority's revoke RPC is intentionally outside N03's transport seam.
  public mutating func markRevoked(hostID: ClairHostID) {
    hosts = hosts.map { record in
      guard record.id == hostID else { return record }
      return ClairMobileHostRecord(
        id: record.id,
        fingerprint: record.fingerprint,
        endpoint: record.endpoint,
        deviceID: record.deviceID,
        displayName: record.displayName,
        scopes: record.scopes,
        connection: .revoked,
        credentialExpiresAt: record.credentialExpiresAt
      )
    }
  }

  public mutating func update(
    identity: ClairStoredDeviceIdentity?,
    clientState: ClairMobileClientState,
    now: Date = Date()
  ) {
    guard let identity else {
      hosts = hosts.map { record in
        ClairMobileHostRecord(
          id: record.id,
          fingerprint: record.fingerprint,
          endpoint: record.endpoint,
          deviceID: record.deviceID,
          displayName: record.displayName,
          scopes: record.scopes,
          connection: .offline,
          credentialExpiresAt: record.credentialExpiresAt
        )
      }
      return
    }

    let status: ClairMobileHostConnectionState
    switch clientState {
    case .pairing:
      status = .pairing
    case .authenticated:
      status = .connected
    case .reconnecting:
      status = .reconnecting
    case .failed(let error):
      switch error {
      case .credentialExpired:
        status = .expired
      case .deviceRevoked:
        status = .revoked
      case .hostIdentityMismatch:
        status = .fingerprintChanged
      default:
        status = .failed
      }
    case .disconnected, .connecting:
      status = .offline
    }

    let record = ClairMobileHostRecord(
      id: identity.hostIdentity.hostID,
      fingerprint: identity.hostIdentity.fingerprint,
      endpoint: identity.endpoint,
      deviceID: identity.credential.grant.deviceID,
      displayName: identity.credential.grant.displayName,
      scopes: identity.credential.grant.visibleScopes,
      connection: identity.credential.grant.isRevoked
        ? .revoked
        : identity.credential.grant.isTokenExpired(at: now) ? .expired : status,
      credentialExpiresAt: identity.credential.grant.tokenExpiresAt
    )
    hosts = [record]
  }
}

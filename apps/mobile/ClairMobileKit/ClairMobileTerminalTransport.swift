import ClairShared
import ClairTerminal
import ClairTransport
import Foundation

/// A mobile-local mirror of the daemon-only `ClairTerminalAttachment`
/// (`ClairDaemonKit`'s `ClairTerminalBoundary.swift`). Deliberate
/// duplication, not an import: the mobile app must never link host-only
/// `ClairDaemonKit` code, the same rule `ClairMobilePushRegistrationSnapshot`
/// (`ClairMobileReconnect.swift`) documents and follows for H09's daemon
/// push-registration snapshot.
public struct ClairMobileTerminalAttachment: Equatable, Sendable {
  public let id: UUID
  public let scope: ResourceScope
  public let generation: UInt64
  public let cursor: ClairTerminalCursor
  public let size: ClairTerminalSize
  /// The journal epoch this attach observed (`ClairTerminalStreamSnapshot.epoch`),
  /// carried so a concrete transport adapter can frame `input()` calls
  /// (`ClairTerminalInputRequest` requires it) without a separate round
  /// trip. Not used by `ClairMobileTerminalSession` itself.
  public let epoch: SessionEpoch

  public init(
    id: UUID, scope: ResourceScope, generation: UInt64, cursor: ClairTerminalCursor,
    size: ClairTerminalSize, epoch: SessionEpoch
  ) {
    self.id = id
    self.scope = scope
    self.generation = generation
    self.cursor = cursor
    self.epoch = epoch
    self.size = size
  }
}

/// Transport-neutral seam for T05's remote terminal session attach, mirroring
/// `ClairMobileSessionVerifying`/`ClairMobileAgentTransport`'s role for
/// their own domains: the production Network.framework/TLS adapter backed by
/// T04's `ClairTerminalBoundary` is a later integration boundary (see
/// `ClairNetworkTLSMobileTransportBoundary`, which is itself still
/// `.unavailable` in this codebase -- no mobile domain has a live socket
/// adapter yet, only transport-neutral protocols tested via in-process
/// fakes). This protocol's five operations mirror `ClairTerminalBoundary`'s
/// `attach`/`read`/`acknowledge`/`input`/`detach` one-for-one so a concrete
/// adapter is a thin forwarder, not a redesign.
public protocol ClairMobileTerminalTransport: Sendable {
  func attach(
    scope: ResourceScope, generation: UInt64, cursor: ClairTerminalCursor?,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairMobileTerminalAttachment

  func read(
    _ attachment: ClairMobileTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairTerminalFrame?

  func acknowledge(
    _ attachment: ClairMobileTerminalAttachment, cursor: ClairTerminalCursor,
    on connection: ClairAuthenticatedConnection
  ) async throws

  func input(
    _ bytes: Data, attachment: ClairMobileTerminalAttachment,
    on connection: ClairAuthenticatedConnection
  ) async throws

  func detach(
    _ attachment: ClairMobileTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws
}

/// Explicit "not yet wired" boundary, mirroring
/// `ClairMobileUnavailableSessionVerifying`/`ClairMobileUnavailablePushRegistering`.
/// Every operation fails closed with `ClairMobileTransportBoundaryError.unavailable`
/// instead of silently no-op-ing.
public struct ClairMobileUnavailableTerminalTransport: ClairMobileTerminalTransport {
  public init() {}

  public func attach(
    scope: ResourceScope, generation: UInt64, cursor: ClairTerminalCursor?,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairMobileTerminalAttachment {
    throw ClairMobileTransportBoundaryError.unavailable
  }

  public func read(
    _ attachment: ClairMobileTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairTerminalFrame? {
    throw ClairMobileTransportBoundaryError.unavailable
  }

  public func acknowledge(
    _ attachment: ClairMobileTerminalAttachment, cursor: ClairTerminalCursor,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    throw ClairMobileTransportBoundaryError.unavailable
  }

  public func input(
    _ bytes: Data, attachment: ClairMobileTerminalAttachment,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    throw ClairMobileTransportBoundaryError.unavailable
  }

  public func detach(
    _ attachment: ClairMobileTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws {
    throw ClairMobileTransportBoundaryError.unavailable
  }
}

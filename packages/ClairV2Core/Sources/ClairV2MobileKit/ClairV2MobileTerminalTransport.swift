import ClairV2Shared
import ClairV2Terminal
import ClairV2Transport
import Foundation

/// A mobile-local mirror of the daemon-only `ClairV2TerminalAttachment`
/// (`ClairV2DaemonKit`'s `ClairV2TerminalBoundary.swift`). Deliberate
/// duplication, not an import: the mobile app must never link host-only
/// `ClairV2DaemonKit` code, the same rule `ClairV2MobilePushRegistrationSnapshot`
/// (`ClairV2MobileReconnect.swift`) documents and follows for H09's daemon
/// push-registration snapshot.
public struct ClairV2MobileTerminalAttachment: Equatable, Sendable {
  public let id: UUID
  public let scope: ResourceScope
  public let generation: UInt64
  public let cursor: ClairV2TerminalCursor
  public let size: ClairV2TerminalSize
  /// The journal epoch this attach observed (`ClairV2TerminalStreamSnapshot.epoch`),
  /// carried so a concrete transport adapter can frame `input()` calls
  /// (`ClairV2TerminalInputRequest` requires it) without a separate round
  /// trip. Not used by `ClairV2MobileTerminalSession` itself.
  public let epoch: SessionEpoch

  public init(
    id: UUID, scope: ResourceScope, generation: UInt64, cursor: ClairV2TerminalCursor,
    size: ClairV2TerminalSize, epoch: SessionEpoch
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
/// `ClairV2MobileSessionVerifying`/`ClairV2MobileAgentTransport`'s role for
/// their own domains: the production Network.framework/TLS adapter backed by
/// T04's `ClairV2TerminalBoundary` is a later integration boundary (see
/// `ClairNetworkTLSMobileTransportBoundary`, which is itself still
/// `.unavailable` in this codebase -- no mobile domain has a live socket
/// adapter yet, only transport-neutral protocols tested via in-process
/// fakes). This protocol's five operations mirror `ClairV2TerminalBoundary`'s
/// `attach`/`read`/`acknowledge`/`input`/`detach` one-for-one so a concrete
/// adapter is a thin forwarder, not a redesign.
public protocol ClairV2MobileTerminalTransport: Sendable {
  func attach(
    scope: ResourceScope, generation: UInt64, cursor: ClairV2TerminalCursor?,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2MobileTerminalAttachment

  func read(
    _ attachment: ClairV2MobileTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2TerminalFrame?

  func acknowledge(
    _ attachment: ClairV2MobileTerminalAttachment, cursor: ClairV2TerminalCursor,
    on connection: ClairAuthenticatedConnection
  ) async throws

  func input(
    _ bytes: Data, attachment: ClairV2MobileTerminalAttachment,
    on connection: ClairAuthenticatedConnection
  ) async throws

  func detach(
    _ attachment: ClairV2MobileTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws
}

/// Explicit "not yet wired" boundary, mirroring
/// `ClairV2MobileUnavailableSessionVerifying`/`ClairV2MobileUnavailablePushRegistering`.
/// Every operation fails closed with `ClairMobileTransportBoundaryError.unavailable`
/// instead of silently no-op-ing.
public struct ClairV2MobileUnavailableTerminalTransport: ClairV2MobileTerminalTransport {
  public init() {}

  public func attach(
    scope: ResourceScope, generation: UInt64, cursor: ClairV2TerminalCursor?,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2MobileTerminalAttachment {
    throw ClairMobileTransportBoundaryError.unavailable
  }

  public func read(
    _ attachment: ClairV2MobileTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2TerminalFrame? {
    throw ClairMobileTransportBoundaryError.unavailable
  }

  public func acknowledge(
    _ attachment: ClairV2MobileTerminalAttachment, cursor: ClairV2TerminalCursor,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    throw ClairMobileTransportBoundaryError.unavailable
  }

  public func input(
    _ bytes: Data, attachment: ClairV2MobileTerminalAttachment,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    throw ClairMobileTransportBoundaryError.unavailable
  }

  public func detach(
    _ attachment: ClairV2MobileTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws {
    throw ClairMobileTransportBoundaryError.unavailable
  }
}

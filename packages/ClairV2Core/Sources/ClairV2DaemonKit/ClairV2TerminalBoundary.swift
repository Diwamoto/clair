import ClairV2Agent
import ClairV2Shared
import ClairV2Terminal
import ClairV2Transport
import CryptoKit
import Foundation

/// Control metadata for a separately carried binary input frame. The digest
/// binds it to the operation ledger without retaining raw bytes in that ledger.
public struct ClairV2TerminalInputMetadata: Codable, Sendable {
  public let epoch: SessionEpoch
  public let processGeneration: UInt64
  public let byteCount: Int
  public let digest: String
}

public struct ClairV2TerminalInputRequest: Sendable, CustomStringConvertible {
  public let operation: OperationRequest<ClairV2TerminalInputMetadata>
  public let bytes: Data
  public var description: String { "TerminalInput(<redacted>)" }

  public init(
    operationID: OperationID, scope: ResourceScope, epoch: SessionEpoch,
    processGeneration: UInt64, bytes: Data
  ) throws {
    guard scope.sessionID != nil, processGeneration > 0, !bytes.isEmpty,
      bytes.count <= ClairV2TerminalFrame.maximumPayloadBytes
    else { throw ClairV2TerminalError.invalidOperation }
    self.bytes = bytes
    self.operation = OperationRequest(
      operationID: operationID, scope: scope, kind: .terminalInput,
      capability: .writeTerminal,
      payload: ClairV2TerminalInputMetadata(
        epoch: epoch,
        processGeneration: processGeneration, byteCount: bytes.count,
        digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
  }
}

public struct ClairV2TerminalInputResult: Equatable, Sendable {
  public let receipt: OperationReceipt
  public let outcome: ClairV2TerminalCommitOutcome
}

public struct ClairV2TerminalAttachment: Equatable, Sendable {
  public let id: UUID
  public let scope: ResourceScope
  public let generation: UInt64
  public let cursor: ClairV2TerminalCursor
}

/// Only the trusted local desktop composition can request this token. Mobile
/// viewport changes are deliberately absent from the authenticated API.
public struct ClairV2TerminalResizeOwner: Equatable, Sendable {
  let token: UUID
  let scope: ResourceScope
  let generation: UInt64
}

public struct ClairV2TerminalAttachmentState: Equatable, Sendable {
  public let attachment: ClairV2TerminalAttachment
  public let stream: ClairV2TerminalStreamSnapshot
  public let size: ClairV2TerminalSize
}

/// Daemon-only ownership and raw operation boundary. The authority turn comes
/// before this lock; nothing inside the lock awaits or calls the authority.
public final class ClairV2TerminalBoundary: @unchecked Sendable {
  private struct Subscriber {
    let device: ClairDeviceID
    let subscriberID: UUID
    let connectionID: ClairConnectionID
    let attachment: ClairV2TerminalAttachment
    var cursor: ClairV2TerminalCursor
    var offered: ClairV2TerminalFrame?
  }
  private struct Session {
    let scope: ResourceScope
    let generation: UInt64
    let process: any ClairV2TerminalProcess
    var ledger: OperationLedger
    var results: [OperationID: ClairV2TerminalInputResult] = [:]
    var subscribers: [UUID: Subscriber] = [:]
    var owner: ClairV2TerminalResizeOwner?
    var active = true
  }
  private let authority: ClairPairingAuthority
  private let lock = NSLock()
  private let maximumSessions: Int
  private let maximumSubscribers: Int
  private let maximumOperations: Int
  private var sessions: [SessionID: Session] = [:]

  public init(
    authority: ClairPairingAuthority, maximumSessions: Int = 64,
    maximumSubscribers: Int = 32, maximumOperations: Int = 4096
  ) throws {
    guard (1...256).contains(maximumSessions), (1...256).contains(maximumSubscribers),
      (1...OperationLedger.maximumCapacity).contains(maximumOperations)
    else { throw ClairV2TerminalError.invalidLimits }
    self.authority = authority
    self.maximumSessions = maximumSessions
    self.maximumSubscribers = maximumSubscribers
    self.maximumOperations = maximumOperations
  }

  public func install(snapshot: ClairV2AgentSessionSnapshot, process: any ClairV2TerminalProcess)
    throws
  {
    try lock.withLock {
      let id = snapshot.identity.sessionID
      guard snapshot.lifecycle == .running, !process.terminalJournal.snapshot().isClosed else {
        throw ClairV2TerminalError.staleSession
      }
      if let old = sessions[id] {
        if old.generation == snapshot.processGeneration, old.scope == snapshot.identity.sessionScope
        {
          return
        }
        guard old.scope == snapshot.identity.sessionScope,
          old.generation < snapshot.processGeneration
        else {
          throw ClairV2TerminalError.staleSession
        }
      } else if sessions.count >= maximumSessions {
        throw ClairV2TerminalError.capacity
      }
      sessions[id] = Session(
        scope: snapshot.identity.sessionScope, generation: snapshot.processGeneration,
        process: process, ledger: try OperationLedger(capacity: maximumOperations))
    }
  }

  public func invalidate(snapshot: ClairV2AgentSessionSnapshot) {
    lock.withLock {
      guard let current = sessions[snapshot.identity.sessionID],
        current.generation == snapshot.processGeneration
      else { return }
      sessions[snapshot.identity.sessionID]?.active = false
      sessions[snapshot.identity.sessionID]?.owner = nil
    }
  }

  public func attach(
    scope: ResourceScope, generation: UInt64, subscriberID: UUID,
    cursor: ClairV2TerminalCursor? = nil, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2TerminalAttachmentState {
    try await authority.readAuthorized(scope: scope, on: connection) { [self] in
      try lock.withLock {
        guard let id = scope.sessionID, var session = sessions[id], session.scope == scope,
          session.generation == generation
        else { throw ClairV2TerminalError.staleSession }
        let state = session.process.terminalJournal.snapshot()
        let start = cursor ?? ClairV2TerminalCursor(epoch: state.epoch, offset: state.retainedStart)
        _ = try session.process.terminalJournal.read(from: start, maximumBytes: 1)
        // Reconnect replaces this device's named subscriber, without launching
        // a process and without stealing another viewer's cursor.
        session.subscribers = session.subscribers.filter {
          !($0.value.device == connection.deviceID && $0.value.subscriberID == subscriberID)
        }
        guard session.subscribers.count < maximumSubscribers else {
          throw ClairV2TerminalError.capacity
        }
        let attachment = ClairV2TerminalAttachment(
          id: UUID(), scope: scope, generation: generation, cursor: start)
        session.subscribers[attachment.id] = Subscriber(
          device: connection.deviceID, subscriberID: subscriberID,
          connectionID: connection.connectionID, attachment: attachment, cursor: start)
        sessions[id] = session
        return ClairV2TerminalAttachmentState(
          attachment: attachment, stream: state, size: session.process.terminalSize)
      }
    }
  }

  public func read(
    _ attachment: ClairV2TerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2TerminalFrame? {
    try await authority.readAuthorized(scope: attachment.scope, on: connection) { [self] in
      try lock.withLock {
        let (id, session, subscriber) = try lookup(attachment, connection: connection)
        // Retain one bounded offered frame until acknowledgment. Retransmission
        // is byte-identical even if the journal advances past it meanwhile.
        if let offered = subscriber.offered { return offered }
        let frame = try session.process.terminalJournal.read(from: subscriber.cursor)
        sessions[id]?.subscribers[attachment.id]?.offered = frame
        return frame
      }
    }
  }

  public func acknowledge(
    _ attachment: ClairV2TerminalAttachment, cursor: ClairV2TerminalCursor,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    try await authority.readAuthorized(scope: attachment.scope, on: connection) { [self] in
      try lock.withLock {
        let (id, _, subscriber) = try lookup(attachment, connection: connection)
        if subscriber.cursor == cursor { return }
        guard let offered = subscriber.offered, offered.nextCursor == cursor else {
          throw ClairV2TerminalError.invalidCursor
        }
        sessions[id]?.subscribers[attachment.id]?.cursor = cursor
        sessions[id]?.subscribers[attachment.id]?.offered = nil
      }
    }
  }

  public func detach(
    _ attachment: ClairV2TerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws {
    try await authority.readAuthorized(scope: attachment.scope, on: connection) { [self] in
      try lock.withLock {
        let (id, _, _) = try lookup(attachment, connection: connection)
        sessions[id]?.subscribers.removeValue(forKey: attachment.id)
      }
    }
  }

  public func snapshot(
    _ attachment: ClairV2TerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2TerminalStreamSnapshot {
    try await authority.readAuthorized(scope: attachment.scope, on: connection) { [self] in
      try lock.withLock {
        let (_, session, _) = try lookup(attachment, connection: connection)
        return session.process.terminalJournal.snapshot()
      }
    }
  }

  public func input(
    _ request: ClairV2TerminalInputRequest, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2TerminalInputResult {
    try await authority.commitAuthorizedOperation(request.operation, on: connection) { [self] in
      try commit(request)
    }
  }

  /// Trusted local composition uses the same FIFO and dedupe window. Geometry
  /// ownership never grants or removes input permission. Remote transports
  /// must use input(_:on:) with their authenticated connection.
  public func localInput(_ request: ClairV2TerminalInputRequest)
    throws -> ClairV2TerminalInputResult
  {
    try commit(request)
  }

  public func claimDesktopResizeOwner(scope: ResourceScope, generation: UInt64) throws
    -> ClairV2TerminalResizeOwner
  {
    try lock.withLock {
      guard let id = scope.sessionID, let session = sessions[id], session.scope == scope,
        session.generation == generation, session.active, session.owner == nil
      else { throw ClairV2TerminalError.resizeDenied }
      let owner = ClairV2TerminalResizeOwner(token: UUID(), scope: scope, generation: generation)
      sessions[id]?.owner = owner
      return owner
    }
  }

  public func resize(_ size: ClairV2TerminalSize, owner: ClairV2TerminalResizeOwner) throws {
    try lock.withLock {
      try validateOwner(owner)
      try sessions[owner.scope.sessionID!]!.process.resizeTerminal(size)
    }
  }

  public func releaseDesktopResizeOwner(_ owner: ClairV2TerminalResizeOwner) throws {
    try lock.withLock {
      try validateOwner(owner)
      sessions[owner.scope.sessionID!]?.owner = nil
    }
  }

  private func commit(_ request: ClairV2TerminalInputRequest) throws -> ClairV2TerminalInputResult {
    try lock.withLock { try commitLocked(request) }
  }

  private func commitLocked(_ request: ClairV2TerminalInputRequest) throws
    -> ClairV2TerminalInputResult
  {
    let op = request.operation
    guard let id = op.scope.sessionID, var session = sessions[id], session.scope == op.scope,
      session.generation == op.payload.processGeneration,
      session.process.terminalJournal.epoch == op.payload.epoch
    else { throw ClairV2TerminalError.staleSession }
    var ledger = session.ledger
    let receipt: OperationReceipt
    do { receipt = try ledger.register(op) } catch {
      throw ClairV2TerminalError.conflictingOperation
    }
    if receipt.disposition == .duplicate, let old = session.results[op.operationID] {
      return ClairV2TerminalInputResult(receipt: receipt, outcome: old.outcome)
    }
    guard session.results.count < maximumOperations else {
      throw ClairV2TerminalError.operationCapacity
    }
    guard session.active else { throw ClairV2TerminalError.closed }
    let outcome = session.process.enqueueTerminalInput(request.bytes)
    let result = ClairV2TerminalInputResult(receipt: receipt, outcome: outcome)
    session.ledger = ledger
    session.results[op.operationID] = result
    sessions[id] = session
    return result
  }

  private func validateOwner(_ owner: ClairV2TerminalResizeOwner) throws {
    guard let id = owner.scope.sessionID, let session = sessions[id], session.owner == owner,
      session.active, session.generation == owner.generation
    else { throw ClairV2TerminalError.resizeDenied }
  }

  private func lookup(
    _ attachment: ClairV2TerminalAttachment, connection: ClairAuthenticatedConnection
  ) throws -> (SessionID, Session, Subscriber) {
    guard let id = attachment.scope.sessionID, let session = sessions[id],
      session.scope == attachment.scope,
      session.generation == attachment.generation,
      let subscriber = session.subscribers[attachment.id],
      subscriber.attachment == attachment, subscriber.device == connection.deviceID,
      subscriber.connectionID == connection.connectionID
    else { throw ClairV2TerminalError.staleSession }
    return (id, session, subscriber)
  }
}

/// H06 lifecycle commands can target a raw process. Semantic prompt/approval
/// effects remain unavailable: no undocumented provider text protocol is added.
struct ClairV2RawAgentEndpoint: ClairV2AgentCommandEndpoint {
  let snapshot: ClairV2AgentSessionSnapshot
  let process: any ClairV2TerminalProcess
  func commit(_ effect: ClairV2AgentCommandEffect) -> ClairV2AgentCommandOutcome {
    guard effect.identity == snapshot.identity,
      effect.payload.processGeneration == snapshot.processGeneration,
      effect.payload.epoch.value == snapshot.processGeneration
    else { return .rejected }
    let signal: Int32
    switch effect.payload.action {
    case .interrupt: signal = 2
    case .stop: signal = 15
    case .prompt, .approve, .deny: return .rejected
    }
    switch process.commitTerminalSignal(signal) {
    case .queued: return .committed
    case .rejected: return .rejected
    case .indeterminate: return .indeterminate
    }
  }
}

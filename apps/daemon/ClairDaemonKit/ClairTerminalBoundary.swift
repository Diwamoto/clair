import ClairAgent
import ClairShared
import ClairTerminal
import ClairTransport
import CryptoKit
import Foundation

/// Control metadata for a separately carried binary input frame. The digest
/// binds it to the operation ledger without retaining raw bytes in that ledger.
public struct ClairTerminalInputMetadata: Codable, Sendable {
  public let epoch: SessionEpoch
  public let processGeneration: UInt64
  public let byteCount: Int
  public let digest: String
}

public struct ClairTerminalInputRequest: Sendable, CustomStringConvertible {
  public let operation: OperationRequest<ClairTerminalInputMetadata>
  public let bytes: Data
  public var description: String { "TerminalInput(<redacted>)" }

  public init(
    operationID: OperationID, scope: ResourceScope, epoch: SessionEpoch,
    processGeneration: UInt64, bytes: Data
  ) throws {
    guard scope.sessionID != nil, processGeneration > 0, !bytes.isEmpty,
      bytes.count <= ClairTerminalFrame.maximumPayloadBytes
    else { throw ClairTerminalError.invalidOperation }
    self.bytes = bytes
    self.operation = OperationRequest(
      operationID: operationID, scope: scope, kind: .terminalInput,
      capability: .writeTerminal,
      payload: ClairTerminalInputMetadata(
        epoch: epoch,
        processGeneration: processGeneration, byteCount: bytes.count,
        digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
  }
}

public struct ClairTerminalInputResult: Equatable, Sendable {
  public let receipt: OperationReceipt
  public let outcome: ClairTerminalCommitOutcome
}

public struct ClairTerminalAttachment: Equatable, Sendable {
  public let id: UUID
  public let scope: ResourceScope
  public let generation: UInt64
  public let cursor: ClairTerminalCursor
}

/// Only the trusted local desktop composition can request this token. Mobile
/// viewport changes are deliberately absent from the authenticated API.
public struct ClairTerminalResizeOwner: Equatable, Sendable {
  let token: UUID
  let scope: ResourceScope
  let generation: UInt64
}

public struct ClairTerminalAttachmentState: Equatable, Sendable {
  public let attachment: ClairTerminalAttachment
  public let stream: ClairTerminalStreamSnapshot
  public let size: ClairTerminalSize
}

/// Daemon-only ownership and raw operation boundary. The authority turn comes
/// before this lock; nothing inside the lock awaits or calls the authority.
public final class ClairTerminalBoundary: @unchecked Sendable {
  private struct Subscriber {
    let subscriberID: UUID
    let connection: ClairAuthenticatedConnection
    let attachment: ClairTerminalAttachment
    var cursor: ClairTerminalCursor
    var offered: ClairTerminalFrame?
  }
  private struct Session {
    let scope: ResourceScope
    let generation: UInt64
    let process: any ClairTerminalProcess
    var ledger: OperationLedger
    var results: [OperationID: ClairTerminalInputResult] = [:]
    var subscribers: [UUID: Subscriber] = [:]
    var owner: ClairTerminalResizeOwner?
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
    else { throw ClairTerminalError.invalidLimits }
    self.authority = authority
    self.maximumSessions = maximumSessions
    self.maximumSubscribers = maximumSubscribers
    self.maximumOperations = maximumOperations
  }

  public func install(snapshot: ClairAgentSessionSnapshot, process: any ClairTerminalProcess)
    throws
  {
    guard snapshot.lifecycle == .running else { throw ClairTerminalError.staleSession }
    try install(
      sessionID: snapshot.identity.sessionID, scope: snapshot.identity.sessionScope,
      generation: snapshot.processGeneration, process: process)
  }

  /// T09: a daemon-owned shell has no agent snapshot, but it goes through this same
  /// boundary (journal, FIFO, dedupe, resize owner) as every other session.
  public func install(
    sessionID id: SessionID, scope: ResourceScope, generation: UInt64,
    process: any ClairTerminalProcess
  ) throws {
    try lock.withLock {
      guard !process.terminalJournal.snapshot().isClosed else {
        throw ClairTerminalError.staleSession
      }
      if let old = sessions[id] {
        if old.generation == generation, old.scope == scope { return }
        guard old.scope == scope, old.generation < generation else {
          throw ClairTerminalError.staleSession
        }
      } else if sessions.count >= maximumSessions {
        throw ClairTerminalError.capacity
      }
      sessions[id] = Session(
        scope: scope, generation: generation,
        process: process, ledger: try OperationLedger(capacity: maximumOperations))
    }
  }

  public func invalidate(sessionID id: SessionID, generation: UInt64) {
    lock.withLock {
      guard let current = sessions[id], current.generation == generation else { return }
      sessions[id]?.active = false
      sessions[id]?.owner = nil
    }
  }

  public func invalidate(snapshot: ClairAgentSessionSnapshot) {
    invalidate(sessionID: snapshot.identity.sessionID, generation: snapshot.processGeneration)
  }

  public func attach(
    scope: ResourceScope, generation: UInt64, subscriberID: UUID,
    cursor: ClairTerminalCursor? = nil, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairTerminalAttachmentState {
    await pruneInactiveSubscribers()
    return try await authority.readAuthorized(scope: scope, on: connection) { [self] in
      try lock.withLock {
        guard let id = scope.sessionID, var session = sessions[id], session.scope == scope,
          session.generation == generation
        else { throw ClairTerminalError.staleSession }
        let state = session.process.terminalJournal.snapshot()
        let start = cursor ?? ClairTerminalCursor(epoch: state.epoch, offset: state.retainedStart)
        _ = try session.process.terminalJournal.read(from: start, maximumBytes: 1)
        // Reconnect replaces this device's named subscriber, without launching
        // a process and without stealing another viewer's cursor.
        session.subscribers = session.subscribers.filter {
          !($0.value.connection.deviceID == connection.deviceID
            && $0.value.subscriberID == subscriberID)
        }
        guard session.subscribers.count < maximumSubscribers else {
          throw ClairTerminalError.capacity
        }
        let attachment = ClairTerminalAttachment(
          id: UUID(), scope: scope, generation: generation, cursor: start)
        session.subscribers[attachment.id] = Subscriber(
          subscriberID: subscriberID, connection: connection, attachment: attachment,
          cursor: start)
        sessions[id] = session
        return ClairTerminalAttachmentState(
          attachment: attachment, stream: state, size: session.process.terminalSize)
      }
    }
  }

  public func read(
    _ attachment: ClairTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairTerminalFrame? {
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
    _ attachment: ClairTerminalAttachment, cursor: ClairTerminalCursor,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    try await authority.readAuthorized(scope: attachment.scope, on: connection) { [self] in
      try lock.withLock {
        let (id, _, subscriber) = try lookup(attachment, connection: connection)
        if subscriber.cursor == cursor { return }
        guard let offered = subscriber.offered, offered.nextCursor == cursor else {
          throw ClairTerminalError.invalidCursor
        }
        sessions[id]?.subscribers[attachment.id]?.cursor = cursor
        sessions[id]?.subscribers[attachment.id]?.offered = nil
      }
    }
  }

  public func detach(
    _ attachment: ClairTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws {
    try await authority.readAuthorized(scope: attachment.scope, on: connection) { [self] in
      try lock.withLock {
        let (id, _, _) = try lookup(attachment, connection: connection)
        sessions[id]?.subscribers.removeValue(forKey: attachment.id)
      }
    }
  }

  /// N10: the live sessions this connection may read, with the exact process
  /// generation `attach` requires. Sessions outside the device scope are omitted.
  public func attachableSessions(
    on connection: ClairAuthenticatedConnection
  ) async -> [ClairRemoteTerminalSession] {
    let live = lock.withLock {
      sessions.values
        .filter { $0.active && !$0.process.terminalJournal.snapshot().isClosed }
        .map { ClairRemoteTerminalSession(scope: $0.scope, generation: $0.generation) }
    }
    var visible: [ClairRemoteTerminalSession] = []
    for session in live
    where (try? await authority.authorizeRead(scope: session.scope, on: connection)) != nil {
      visible.append(session)
    }
    return visible.sorted {
      ($0.scope.sessionID?.description ?? "") < ($1.scope.sessionID?.description ?? "")
    }
  }

  public func snapshot(
    _ attachment: ClairTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairTerminalStreamSnapshot {
    try await authority.readAuthorized(scope: attachment.scope, on: connection) { [self] in
      try lock.withLock {
        let (_, session, _) = try lookup(attachment, connection: connection)
        return session.process.terminalJournal.snapshot()
      }
    }
  }

  public func input(
    _ request: ClairTerminalInputRequest, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairTerminalInputResult {
    try await authority.commitAuthorizedOperation(request.operation, on: connection) { [self] in
      try commit(request)
    }
  }

  /// Trusted local composition uses the same FIFO and dedupe window. Geometry
  /// ownership never grants or removes input permission. Remote transports
  /// must use input(_:on:) with their authenticated connection.
  public func localInput(_ request: ClairTerminalInputRequest)
    throws -> ClairTerminalInputResult
  {
    try commit(request)
  }

  /// T09: the local socket is synchronous and never retries, so it needs no dedupe record. Skipping
  /// the ledger keeps a long-lived shell from exhausting the per-session operation window one
  /// keystroke at a time; ordering against remote input is still the single lock below.
  public func localWrite(scope: ResourceScope, generation: UInt64, bytes: Data) throws
    -> ClairTerminalCommitOutcome
  {
    try lock.withLock {
      guard let id = scope.sessionID, let session = sessions[id], session.scope == scope,
        session.generation == generation
      else { throw ClairTerminalError.staleSession }
      guard session.active else { throw ClairTerminalError.closed }
      return session.process.enqueueTerminalInput(bytes)
    }
  }

  /// Drops a session for good (its journal is released). `invalidate` only fences it, which
  /// leaves the slot counted against `maximumSessions`.
  public func remove(sessionID id: SessionID, generation: UInt64) {
    lock.withLock {
      guard sessions[id]?.generation == generation else { return }
      sessions.removeValue(forKey: id)
    }
  }

  public func claimDesktopResizeOwner(scope: ResourceScope, generation: UInt64) throws
    -> ClairTerminalResizeOwner
  {
    try lock.withLock {
      guard let id = scope.sessionID, let session = sessions[id], session.scope == scope,
        session.generation == generation, session.active, session.owner == nil
      else { throw ClairTerminalError.resizeDenied }
      let owner = ClairTerminalResizeOwner(token: UUID(), scope: scope, generation: generation)
      sessions[id]?.owner = owner
      return owner
    }
  }

  public func resize(_ size: ClairTerminalSize, owner: ClairTerminalResizeOwner) throws {
    try lock.withLock {
      try validateOwner(owner)
      try sessions[owner.scope.sessionID!]!.process.resizeTerminal(size)
    }
  }

  public func releaseDesktopResizeOwner(_ owner: ClairTerminalResizeOwner) throws {
    try lock.withLock {
      try validateOwner(owner)
      sessions[owner.scope.sessionID!]?.owner = nil
    }
  }

  private func commit(_ request: ClairTerminalInputRequest) throws -> ClairTerminalInputResult {
    try lock.withLock { try commitLocked(request) }
  }

  private func commitLocked(_ request: ClairTerminalInputRequest) throws
    -> ClairTerminalInputResult
  {
    let op = request.operation
    guard let id = op.scope.sessionID, var session = sessions[id], session.scope == op.scope,
      session.generation == op.payload.processGeneration,
      session.process.terminalJournal.epoch == op.payload.epoch
    else { throw ClairTerminalError.staleSession }
    var ledger = session.ledger
    let receipt: OperationReceipt
    do { receipt = try ledger.register(op) } catch {
      throw ClairTerminalError.conflictingOperation
    }
    if receipt.disposition == .duplicate, let old = session.results[op.operationID] {
      return ClairTerminalInputResult(receipt: receipt, outcome: old.outcome)
    }
    guard session.results.count < maximumOperations else {
      throw ClairTerminalError.operationCapacity
    }
    guard session.active else { throw ClairTerminalError.closed }
    let outcome = session.process.enqueueTerminalInput(request.bytes)
    let result = ClairTerminalInputResult(receipt: receipt, outcome: outcome)
    session.ledger = ledger
    session.results[op.operationID] = result
    sessions[id] = session
    return result
  }

  private func validateOwner(_ owner: ClairTerminalResizeOwner) throws {
    guard let id = owner.scope.sessionID, let session = sessions[id], session.owner == owner,
      session.active, session.generation == owner.generation
    else { throw ClairTerminalError.resizeDenied }
  }

  private func lookup(
    _ attachment: ClairTerminalAttachment, connection: ClairAuthenticatedConnection
  ) throws -> (SessionID, Session, Subscriber) {
    guard let id = attachment.scope.sessionID, let session = sessions[id],
      session.scope == attachment.scope,
      session.generation == attachment.generation,
      let subscriber = session.subscribers[attachment.id],
      subscriber.attachment == attachment, subscriber.connection.deviceID == connection.deviceID,
      subscriber.connection.connectionID == connection.connectionID
    else { throw ClairTerminalError.staleSession }
    return (id, session, subscriber)
  }

  private func pruneInactiveSubscribers() async {
    let candidates = lock.withLock {
      sessions.values.flatMap { session in
        session.subscribers.values.map(\.connection)
      }
    }
    var inactiveConnectionIDs: Set<ClairConnectionID> = []
    for candidate in candidates {
      if !(await authority.isConnectionActive(candidate)) {
        inactiveConnectionIDs.insert(candidate.connectionID)
      }
    }
    guard !inactiveConnectionIDs.isEmpty else { return }
    lock.withLock {
      for id in sessions.keys {
        guard var session = sessions[id] else { continue }
        session.subscribers = session.subscribers.filter {
          !inactiveConnectionIDs.contains($0.value.connection.connectionID)
        }
        sessions[id] = session
      }
    }
  }
}

/// H06 lifecycle commands can target a raw process. Semantic prompt/approval
/// effects remain unavailable: no undocumented provider text protocol is added.
struct ClairRawAgentEndpoint: ClairAgentCommandEndpoint {
  let snapshot: ClairAgentSessionSnapshot
  let process: any ClairTerminalProcess
  func commit(_ effect: ClairAgentCommandEffect) -> ClairAgentCommandOutcome {
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

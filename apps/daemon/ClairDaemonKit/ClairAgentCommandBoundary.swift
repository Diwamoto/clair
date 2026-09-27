import ClairAgent
import ClairShared
import ClairTransport
import CryptoKit
import Foundation

public struct ClairAgentCommandLimits: Sendable {
  public let maximumSessions: Int
  public let maximumOperations: Int
  public let maximumPendingApprovals: Int
  public let maximumAuditEntries: Int

  public static let standard = try! Self()

  public init(
    maximumSessions: Int = 64, maximumOperations: Int = 256,
    maximumPendingApprovals: Int = 32, maximumAuditEntries: Int = 256
  ) throws {
    guard (1...256).contains(maximumSessions),
      (1...OperationLedger.maximumCapacity).contains(maximumOperations),
      (1...256).contains(maximumPendingApprovals),
      (1...4096).contains(maximumAuditEntries)
    else { throw ClairAgentCommandError.invalidLimits }
    self.maximumSessions = maximumSessions
    self.maximumOperations = maximumOperations
    self.maximumPendingApprovals = maximumPendingApprovals
    self.maximumAuditEntries = maximumAuditEntries
  }
}

public struct ClairAgentCommandResult: Codable, Equatable, Sendable {
  public let receipt: OperationReceipt
  public let outcome: ClairAgentCommandOutcome
}

/// Bounded diagnostic metadata only. Even typed IDs are hashed because a peer
/// can put private text in an otherwise syntactically valid ID.
public struct ClairAgentCommandAudit: Codable, Equatable, Sendable {
  public let operationDigest: String
  public let deviceDigest: String
  public let scopeDigest: String
  public let kind: ClairAgentCommandKind
  public let generation: UInt64
  public let outcome: ClairAgentCommandOutcome?
  public let rejection: ClairAgentCommandError?
  public let isDuplicate: Bool
}

/// One host-owned boundary, retained for the lifetime of its in-memory operation
/// window. Host composition installs H04 snapshots/endpoints and feeds H05
/// events here; peers can only submit authenticated commands.
public final class ClairAgentCommandBoundary: Sendable {
  private let authority: ClairPairingAuthority
  private let state: CommandState

  public init(
    authority: ClairPairingAuthority, limits: ClairAgentCommandLimits = .standard
  ) throws {
    self.authority = authority
    self.state = try CommandState(limits: limits)
  }

  public func install(
    snapshot: ClairAgentSessionSnapshot, epoch: SessionEpoch,
    startingRevision: Revision = .zero, endpoint: any ClairAgentCommandEndpoint
  ) throws {
    try state.install(
      snapshot: snapshot, epoch: epoch, startingRevision: startingRevision, endpoint: endpoint
    )
  }

  /// Call on H04 exit/detach before discarding an endpoint. Old callbacks cannot
  /// invalidate a replacement process generation.
  public func invalidate(identity: ClairAgentSessionIdentity, processGeneration: UInt64) {
    state.invalidate(identity: identity, processGeneration: processGeneration)
  }

  /// Removes an attachment that never became usable by a client. This is
  /// intentionally separate from `invalidate`: normal terminal sessions keep
  /// their fenced record for stale-command rejection, while an H10 attach
  /// rollback must return the bounded session slot to the boundary.
  public func uninstall(
    identity: ClairAgentSessionIdentity,
    processGeneration: UInt64
  ) {
    state.uninstall(identity: identity, processGeneration: processGeneration)
  }

  public func ingest(_ event: ClairAgentNormalizedEvent) throws {
    try state.ingest(event)
  }

  public func execute(
    _ command: ClairAgentCommand, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairAgentCommandResult {
    do {
      try Self.validate(command)
      let ticket = try await authority.authorizeForDispatch(command, on: connection)
      return try await commit(ticket, on: connection)
    } catch {
      let safe = Self.safeError(error)
      state.record(command, connection: connection, rejection: safe)
      throw safe
    }
  }

  /// Separate ticket entry is useful when a transport has already performed
  /// H03 admission. A duplicate authorization receipt never implies an effect.
  public func dispatch(
    _ ticket: ClairAuthorizationTicket<ClairAgentCommandPayload>,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairAgentCommandResult {
    do {
      try Self.validate(ticket.operation)
      return try await commit(ticket, on: connection)
    } catch {
      let safe = Self.safeError(error)
      state.record(ticket.operation, connection: connection, rejection: safe)
      throw safe
    }
  }

  public func auditSnapshot() -> [ClairAgentCommandAudit] { state.auditSnapshot() }

  private func commit(
    _ ticket: ClairAuthorizationTicket<ClairAgentCommandPayload>,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairAgentCommandResult {
    try await authority.commitDispatch(ticket, on: connection) { [state] in
      try state.commit(ticket.operation, connection: connection)
    }
  }

  private static func validate(_ command: ClairAgentCommand) throws {
    try command.payload.action.validate()
    guard command.scope.sessionID != nil,
      command.kind == command.payload.action.kind.operationKind,
      command.capability == command.payload.action.kind.capability
    else { throw ClairAgentCommandError.invalidCommand }
    if let reference = command.payload.action.approval {
      guard command.baseRevision == reference.revision else {
        throw ClairAgentCommandError.staleApproval
      }
    }
    // Bound both direct callers and wire-originated commands before H03 retains
    // their canonical fingerprint. Wire adapters must also use bounded frames.
    guard try ProtocolCodec.encode(command).count <= FrameLimits.defaultMaximumPayloadBytes else {
      throw ClairAgentCommandError.invalidCommand
    }
  }

  private static func safeError(_ error: any Error) -> ClairAgentCommandError {
    if let error = error as? ClairAgentCommandError { return error }
    if case .operationIDReuse = error as? ProtocolError { return .conflictingOperation }
    return .authorizationDenied
  }
}

/// The authority is always acquired before this lock; host event/lifecycle
/// methods acquire only this lock. Nothing under the lock awaits or calls back
/// into the authority. This closes both security and session-state TOCTOU gaps.
private final class CommandState: @unchecked Sendable {
  private struct Session {
    let identity: ClairAgentSessionIdentity
    let generation: UInt64
    let epoch: SessionEpoch
    let endpoint: any ClairAgentCommandEndpoint
    var replay: ReplayState
    var pending: [String: ClairAgentApprovalReference] = [:]
    var active = true
  }

  private struct EventDigest: Codable, Sendable {
    let digest: String
  }

  private let lock = NSLock()
  private let limits: ClairAgentCommandLimits
  private var sessions: [SessionID: Session] = [:]
  private var ledger: OperationLedger
  private var results: [OperationID: ClairAgentCommandResult] = [:]
  private var audit: [ClairAgentCommandAudit] = []

  init(limits: ClairAgentCommandLimits) throws {
    self.limits = limits
    self.ledger = try OperationLedger(capacity: limits.maximumOperations)
  }

  func install(
    snapshot: ClairAgentSessionSnapshot, epoch: SessionEpoch, startingRevision: Revision,
    endpoint: any ClairAgentCommandEndpoint
  ) throws {
    try lock.withLock {
      let id = snapshot.identity.sessionID
      guard snapshot.lifecycle == .running, snapshot.processGeneration > 0 else {
        throw ClairAgentCommandError.staleSession
      }
      if let old = sessions[id] {
        guard old.identity.sessionScope == snapshot.identity.sessionScope,
          snapshot.processGeneration >= old.generation, epoch > old.epoch,
          snapshot.processGeneration > old.generation || old.identity == snapshot.identity
        else { throw ClairAgentCommandError.staleSession }
      } else if sessions.count >= limits.maximumSessions {
        throw ClairAgentCommandError.sessionCapacity
      }
      sessions[id] = Session(
        identity: snapshot.identity, generation: snapshot.processGeneration,
        epoch: epoch, endpoint: endpoint,
        replay: try ReplayState(
          cursor: ReplayCursor(
            scope: snapshot.identity.sessionScope, epoch: epoch, revision: startingRevision
          )
        )
      )
    }
  }

  func invalidate(identity: ClairAgentSessionIdentity, processGeneration: UInt64) {
    lock.withLock {
      guard var session = sessions[identity.sessionID], session.identity == identity,
        session.generation == processGeneration
      else { return }
      session.active = false
      session.pending.removeAll()
      sessions[identity.sessionID] = session
    }
  }

  func uninstall(identity: ClairAgentSessionIdentity, processGeneration: UInt64) {
    lock.withLock {
      guard let session = sessions[identity.sessionID], session.identity == identity,
        session.generation == processGeneration
      else { return }
      sessions.removeValue(forKey: identity.sessionID)
    }
  }

  func ingest(_ event: ClairAgentNormalizedEvent) throws {
    try lock.withLock {
      guard let id = event.scope.sessionID, var session = sessions[id] else {
        throw ClairAgentCommandError.staleSession
      }
      // An event from a previous attachment or another scope must not fence the
      // live attachment. Events in its own stream that break ordering do fence.
      guard event.scope == session.identity.sessionScope, event.epoch == session.epoch else {
        throw ClairAgentCommandError.invalidEventStream
      }
      guard session.active else { throw ClairAgentCommandError.staleSession }
      do {
        guard event.kind.rawValue == "agent.\(event.payload.kind.rawValue)" else {
          throw ClairAgentCommandError.invalidEventStream
        }
        let encoded = try ProtocolCodec.encode(event)
        guard encoded.count <= FrameLimits.defaultMaximumPayloadBytes else {
          throw ClairAgentCommandError.invalidEventStream
        }
        let projection = try EventEnvelope(
          eventID: event.eventID, kind: event.kind, scope: event.scope,
          epoch: event.epoch, revision: event.revision, operationID: event.operationID,
          payload: EventDigest(digest: digest(encoded))
        )
        guard try session.replay.apply(projection) == .applied else { return }
        switch event.payload {
        case .attention(let attention):
          guard let revision = event.revision else {
            throw ClairAgentCommandError.invalidEventStream
          }
          guard let requestID = attention.requestID else {
            if attention.kind == .approval && attention.status == .pending {
              throw ClairAgentCommandError.invalidEventStream
            }
            // An uncorrelated attention cannot identify a single pending
            // request. Invalidate the entire executable approval window.
            session.pending.removeAll()
            break
          }
          guard attention.kind == .approval else {
            // A provider may reuse a request identity while changing the
            // attention family. That is a replacement, not an approval, so
            // revoke the old executable reference before ignoring the event.
            session.pending.removeValue(forKey: requestID)
            break
          }
          let reference = try ClairAgentApprovalReference(
            requestID: requestID, eventID: event.eventID, revision: revision
          )
          if attention.status == .pending {
            guard
              session.pending[requestID] != nil
                || session.pending.count < limits.maximumPendingApprovals
            else { throw ClairAgentCommandError.approvalCapacity }
            session.pending[requestID] = reference
          } else {
            if session.pending.removeValue(forKey: requestID) == nil {
              // An uncorrelated resolution cannot safely identify which
              // pending request was answered. Fail closed for the whole
              // approval window instead of leaving an old approval executable.
              session.pending.removeAll()
            }
          }
        case .completion:
          session.pending.removeAll()
        default: break
        }
        sessions[id] = session
      } catch {
        session.active = false
        session.pending.removeAll()
        sessions[id] = session
        if let error = error as? ClairAgentCommandError { throw error }
        throw ClairAgentCommandError.invalidEventStream
      }
    }
  }

  func commit(
    _ command: ClairAgentCommand, connection: ClairAuthenticatedConnection
  ) throws -> ClairAgentCommandResult {
    try lock.withLock {
      // Trial registration preserves the B03 fingerprint/equality rules, while
      // refusing new IDs at capacity instead of silently evicting old effects.
      var candidate = ledger
      let receipt = try candidate.register(command)
      if receipt.disposition == .duplicate, let previous = results[command.operationID] {
        let result = ClairAgentCommandResult(receipt: receipt, outcome: previous.outcome)
        appendAudit(command, connection: connection, result: result)
        return result
      }
      guard results.count < limits.maximumOperations else {
        throw ClairAgentCommandError.operationCapacity
      }
      guard let id = command.scope.sessionID, var session = sessions[id] else {
        throw ClairAgentCommandError.staleSession
      }
      guard session.identity.sessionScope == command.scope else {
        throw ClairAgentCommandError.scopeMismatch
      }
      guard session.active, session.generation == command.payload.processGeneration,
        session.epoch == command.payload.epoch
      else { throw ClairAgentCommandError.staleSession }
      if let approval = command.payload.action.approval {
        guard session.pending[approval.requestID] == approval else {
          throw ClairAgentCommandError.staleApproval
        }
      } else if let baseRevision = command.baseRevision,
        baseRevision != session.replay.cursor.revision
      {
        throw ClairAgentCommandError.staleSession
      }

      // No throwing/suspending work remains after calling the endpoint. Store
      // every outcome, including rejection and uncertainty, exactly once.
      let outcome = session.endpoint.commit(
        ClairAgentCommandEffect(
          identity: session.identity, operationID: command.operationID, payload: command.payload
        )
      )
      ledger = candidate
      let result = ClairAgentCommandResult(receipt: receipt, outcome: outcome)
      results[command.operationID] = result
      if outcome != .rejected {
        if let reference = command.payload.action.approval {
          session.pending.removeValue(forKey: reference.requestID)
        }
        switch command.payload.action {
        case .interrupt: session.pending.removeAll()
        case .stop:
          session.pending.removeAll()
          session.active = false
        default: break
        }
      }
      sessions[id] = session
      appendAudit(command, connection: connection, result: result)
      return result
    }
  }

  func record(
    _ command: ClairAgentCommand, connection: ClairAuthenticatedConnection,
    rejection: ClairAgentCommandError
  ) {
    lock.withLock { appendAudit(command, connection: connection, rejection: rejection) }
  }

  func auditSnapshot() -> [ClairAgentCommandAudit] { lock.withLock { audit } }

  private func appendAudit(
    _ command: ClairAgentCommand, connection: ClairAuthenticatedConnection,
    result: ClairAgentCommandResult? = nil, rejection: ClairAgentCommandError? = nil
  ) {
    audit.append(
      ClairAgentCommandAudit(
        operationDigest: digest(Data(command.operationID.rawValue.utf8)),
        deviceDigest: digest(Data(connection.deviceID.rawValue.utf8)),
        scopeDigest: digest((try? ProtocolCodec.encode(command.scope)) ?? Data()),
        kind: command.payload.action.kind, generation: connection.generation,
        outcome: result?.outcome, rejection: rejection,
        isDuplicate: result?.receipt.disposition == .duplicate
      )
    )
    if audit.count > limits.maximumAuditEntries { audit.removeFirst() }
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

import ClairV2Agent
import ClairV2Shared
import ClairV2Transport
import CryptoKit
import Foundation

public struct ClairV2AgentCommandLimits: Sendable {
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
    else { throw ClairV2AgentCommandError.invalidLimits }
    self.maximumSessions = maximumSessions
    self.maximumOperations = maximumOperations
    self.maximumPendingApprovals = maximumPendingApprovals
    self.maximumAuditEntries = maximumAuditEntries
  }
}

public struct ClairV2AgentCommandResult: Codable, Equatable, Sendable {
  public let receipt: OperationReceipt
  public let outcome: ClairV2AgentCommandOutcome
}

/// Bounded diagnostic metadata only. Even typed IDs are hashed because a peer
/// can put private text in an otherwise syntactically valid ID.
public struct ClairV2AgentCommandAudit: Codable, Equatable, Sendable {
  public let operationDigest: String
  public let deviceDigest: String
  public let scopeDigest: String
  public let kind: ClairV2AgentCommandKind
  public let generation: UInt64
  public let outcome: ClairV2AgentCommandOutcome?
  public let rejection: ClairV2AgentCommandError?
  public let isDuplicate: Bool
}

/// One host-owned boundary, retained for the lifetime of its in-memory operation
/// window. Host composition installs H04 snapshots/endpoints and feeds H05
/// events here; peers can only submit authenticated commands.
public final class ClairV2AgentCommandBoundary: Sendable {
  private let authority: ClairPairingAuthority
  private let state: CommandState

  public init(
    authority: ClairPairingAuthority, limits: ClairV2AgentCommandLimits = .standard
  ) throws {
    self.authority = authority
    self.state = try CommandState(limits: limits)
  }

  public func install(
    snapshot: ClairV2AgentSessionSnapshot, epoch: SessionEpoch,
    startingRevision: Revision = .zero, endpoint: any ClairV2AgentCommandEndpoint
  ) throws {
    try state.install(
      snapshot: snapshot, epoch: epoch, startingRevision: startingRevision, endpoint: endpoint
    )
  }

  /// Call on H04 exit/detach before discarding an endpoint. Old callbacks cannot
  /// invalidate a replacement process generation.
  public func invalidate(identity: ClairV2AgentSessionIdentity, processGeneration: UInt64) {
    state.invalidate(identity: identity, processGeneration: processGeneration)
  }

  public func ingest(_ event: ClairV2AgentNormalizedEvent) throws {
    try state.ingest(event)
  }

  public func execute(
    _ command: ClairV2AgentCommand, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2AgentCommandResult {
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
    _ ticket: ClairAuthorizationTicket<ClairV2AgentCommandPayload>,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2AgentCommandResult {
    do {
      try Self.validate(ticket.operation)
      return try await commit(ticket, on: connection)
    } catch {
      let safe = Self.safeError(error)
      state.record(ticket.operation, connection: connection, rejection: safe)
      throw safe
    }
  }

  public func auditSnapshot() -> [ClairV2AgentCommandAudit] { state.auditSnapshot() }

  private func commit(
    _ ticket: ClairAuthorizationTicket<ClairV2AgentCommandPayload>,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2AgentCommandResult {
    try await authority.commitDispatch(ticket, on: connection) { [state] in
      try state.commit(ticket.operation, connection: connection)
    }
  }

  private static func validate(_ command: ClairV2AgentCommand) throws {
    try command.payload.action.validate()
    guard command.scope.sessionID != nil,
      command.kind == command.payload.action.kind.operationKind,
      command.capability == command.payload.action.kind.capability
    else { throw ClairV2AgentCommandError.invalidCommand }
    if let reference = command.payload.action.approval {
      guard command.baseRevision == reference.revision else {
        throw ClairV2AgentCommandError.staleApproval
      }
    }
    // Bound both direct callers and wire-originated commands before H03 retains
    // their canonical fingerprint. Wire adapters must also use bounded frames.
    guard try ProtocolCodec.encode(command).count <= FrameLimits.defaultMaximumPayloadBytes else {
      throw ClairV2AgentCommandError.invalidCommand
    }
  }

  private static func safeError(_ error: any Error) -> ClairV2AgentCommandError {
    if let error = error as? ClairV2AgentCommandError { return error }
    if case .operationIDReuse = error as? ProtocolError { return .conflictingOperation }
    return .authorizationDenied
  }
}

/// The authority is always acquired before this lock; host event/lifecycle
/// methods acquire only this lock. Nothing under the lock awaits or calls back
/// into the authority. This closes both security and session-state TOCTOU gaps.
private final class CommandState: @unchecked Sendable {
  private struct Session {
    let identity: ClairV2AgentSessionIdentity
    let generation: UInt64
    let epoch: SessionEpoch
    let endpoint: any ClairV2AgentCommandEndpoint
    var replay: ReplayState
    var pending: [String: ClairV2AgentApprovalReference] = [:]
    var active = true
  }

  private struct EventDigest: Codable, Sendable {
    let digest: String
  }

  private let lock = NSLock()
  private let limits: ClairV2AgentCommandLimits
  private var sessions: [SessionID: Session] = [:]
  private var ledger: OperationLedger
  private var results: [OperationID: ClairV2AgentCommandResult] = [:]
  private var audit: [ClairV2AgentCommandAudit] = []

  init(limits: ClairV2AgentCommandLimits) throws {
    self.limits = limits
    self.ledger = try OperationLedger(capacity: limits.maximumOperations)
  }

  func install(
    snapshot: ClairV2AgentSessionSnapshot, epoch: SessionEpoch, startingRevision: Revision,
    endpoint: any ClairV2AgentCommandEndpoint
  ) throws {
    try lock.withLock {
      let id = snapshot.identity.sessionID
      guard snapshot.lifecycle == .running, snapshot.processGeneration > 0 else {
        throw ClairV2AgentCommandError.staleSession
      }
      if let old = sessions[id] {
        guard old.identity.sessionScope == snapshot.identity.sessionScope,
          snapshot.processGeneration >= old.generation, epoch > old.epoch,
          snapshot.processGeneration > old.generation || old.identity == snapshot.identity
        else { throw ClairV2AgentCommandError.staleSession }
      } else if sessions.count >= limits.maximumSessions {
        throw ClairV2AgentCommandError.sessionCapacity
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

  func invalidate(identity: ClairV2AgentSessionIdentity, processGeneration: UInt64) {
    lock.withLock {
      guard var session = sessions[identity.sessionID], session.identity == identity,
        session.generation == processGeneration
      else { return }
      session.active = false
      session.pending.removeAll()
      sessions[identity.sessionID] = session
    }
  }

  func ingest(_ event: ClairV2AgentNormalizedEvent) throws {
    try lock.withLock {
      guard let id = event.scope.sessionID, var session = sessions[id] else {
        throw ClairV2AgentCommandError.staleSession
      }
      // An event from a previous attachment or another scope must not fence the
      // live attachment. Events in its own stream that break ordering do fence.
      guard event.scope == session.identity.sessionScope, event.epoch == session.epoch else {
        throw ClairV2AgentCommandError.invalidEventStream
      }
      guard session.active else { throw ClairV2AgentCommandError.staleSession }
      do {
        guard event.kind.rawValue == "agent.\(event.payload.kind.rawValue)" else {
          throw ClairV2AgentCommandError.invalidEventStream
        }
        let encoded = try ProtocolCodec.encode(event)
        guard encoded.count <= FrameLimits.defaultMaximumPayloadBytes else {
          throw ClairV2AgentCommandError.invalidEventStream
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
            throw ClairV2AgentCommandError.invalidEventStream
          }
          guard let requestID = attention.requestID else {
            if attention.kind == .approval && attention.status == .pending {
              throw ClairV2AgentCommandError.invalidEventStream
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
          let reference = try ClairV2AgentApprovalReference(
            requestID: requestID, eventID: event.eventID, revision: revision
          )
          if attention.status == .pending {
            guard
              session.pending[requestID] != nil
                || session.pending.count < limits.maximumPendingApprovals
            else { throw ClairV2AgentCommandError.approvalCapacity }
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
        if let error = error as? ClairV2AgentCommandError { throw error }
        throw ClairV2AgentCommandError.invalidEventStream
      }
    }
  }

  func commit(
    _ command: ClairV2AgentCommand, connection: ClairAuthenticatedConnection
  ) throws -> ClairV2AgentCommandResult {
    try lock.withLock {
      // Trial registration preserves the B03 fingerprint/equality rules, while
      // refusing new IDs at capacity instead of silently evicting old effects.
      var candidate = ledger
      let receipt = try candidate.register(command)
      if receipt.disposition == .duplicate, let previous = results[command.operationID] {
        let result = ClairV2AgentCommandResult(receipt: receipt, outcome: previous.outcome)
        appendAudit(command, connection: connection, result: result)
        return result
      }
      guard results.count < limits.maximumOperations else {
        throw ClairV2AgentCommandError.operationCapacity
      }
      guard let id = command.scope.sessionID, var session = sessions[id] else {
        throw ClairV2AgentCommandError.staleSession
      }
      guard session.identity.sessionScope == command.scope else {
        throw ClairV2AgentCommandError.scopeMismatch
      }
      guard session.active, session.generation == command.payload.processGeneration,
        session.epoch == command.payload.epoch
      else { throw ClairV2AgentCommandError.staleSession }
      if let approval = command.payload.action.approval {
        guard session.pending[approval.requestID] == approval else {
          throw ClairV2AgentCommandError.staleApproval
        }
      } else if let baseRevision = command.baseRevision,
        baseRevision != session.replay.cursor.revision
      {
        throw ClairV2AgentCommandError.staleSession
      }

      // No throwing/suspending work remains after calling the endpoint. Store
      // every outcome, including rejection and uncertainty, exactly once.
      let outcome = session.endpoint.commit(
        ClairV2AgentCommandEffect(
          identity: session.identity, operationID: command.operationID, payload: command.payload
        )
      )
      ledger = candidate
      let result = ClairV2AgentCommandResult(receipt: receipt, outcome: outcome)
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
    _ command: ClairV2AgentCommand, connection: ClairAuthenticatedConnection,
    rejection: ClairV2AgentCommandError
  ) {
    lock.withLock { appendAudit(command, connection: connection, rejection: rejection) }
  }

  func auditSnapshot() -> [ClairV2AgentCommandAudit] { lock.withLock { audit } }

  private func appendAudit(
    _ command: ClairV2AgentCommand, connection: ClairAuthenticatedConnection,
    result: ClairV2AgentCommandResult? = nil, rejection: ClairV2AgentCommandError? = nil
  ) {
    audit.append(
      ClairV2AgentCommandAudit(
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

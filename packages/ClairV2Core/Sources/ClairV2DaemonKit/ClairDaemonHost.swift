import ClairV2Agent
import ClairV2Push
import ClairV2Shared
import ClairV2Transport
import ClairV2Workspace
import Foundation

/// Daemon-wide resource bounds that are not already covered by an existing
/// per-module `*Limits` type. H02/H03/H05/H06/H07/H08 each bound their own
/// state, and `ClairDaemonPushRegistry` (H09) already takes its own bounded
/// `capacity`. Two real host-level resources are not bounded anywhere else:
///
/// - `ClairV2AgentRuntime` (H04) has no cap at all on the number of
///   concurrently spawned provider processes: every launched session is a
///   real OS process, file descriptor set, and process group.
/// - H08's `ClairV2SessionJournalLimits.maximumSubscribersPerSession` bounds
///   subscribers *within one session*, but nothing bounds the total number
///   of subscriber attachments *across every session the daemon journals at
///   once*.
///
/// Both are aggregate, cross-project resources that a single daemon process
/// shares, so `ClairDaemonHost` enforces them itself before forwarding a
/// request into the corresponding H04/H08 module, rather than adding a new
/// limits type to either module.
public struct ClairDaemonHostLimits: Codable, Equatable, Sendable {
  public static let defaultMaximumTotalAgentSessions = 32
  public static let maximumMaximumTotalAgentSessions = 256
  public static let defaultMaximumTotalJournalSubscribers = 512
  public static let maximumMaximumTotalJournalSubscribers = 4_096

  public let maximumTotalAgentSessions: Int
  public let maximumTotalJournalSubscribers: Int

  public static let standard = try! Self()

  public init(
    maximumTotalAgentSessions: Int = Self.defaultMaximumTotalAgentSessions,
    maximumTotalJournalSubscribers: Int = Self.defaultMaximumTotalJournalSubscribers
  ) throws {
    guard (1...Self.maximumMaximumTotalAgentSessions).contains(maximumTotalAgentSessions),
      (1...Self.maximumMaximumTotalJournalSubscribers).contains(maximumTotalJournalSubscribers)
    else { throw ClairDaemonHostError.invalidLimits }
    self.maximumTotalAgentSessions = maximumTotalAgentSessions
    self.maximumTotalJournalSubscribers = maximumTotalJournalSubscribers
  }

  private enum CodingKeys: String, CodingKey {
    case maximumTotalAgentSessions = "maximum_total_agent_sessions"
    case maximumTotalJournalSubscribers = "maximum_total_journal_subscribers"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumTotalAgentSessions: container.decode(Int.self, forKey: .maximumTotalAgentSessions),
      maximumTotalJournalSubscribers: container.decode(
        Int.self, forKey: .maximumTotalJournalSubscribers)
    )
  }
}

public enum ClairDaemonHostError: Error, Equatable, LocalizedError, Sendable {
  case invalidLimits
  case unauthorized
  case agentSessionCapacityExceeded
  case journalSubscriberCapacityExceeded
  case agentCleanupPending

  public var errorDescription: String? {
    switch self {
    case .invalidLimits:
      "The Clair daemon host resource limits are invalid."
    case .unauthorized:
      "The connection is not authorized for the requested scope or capability."
    case .agentSessionCapacityExceeded:
      "The daemon has reached its bounded total concurrent agent session capacity."
    case .journalSubscriberCapacityExceeded:
      "The daemon has reached its bounded total concurrent journal subscriber capacity."
    case .agentCleanupPending:
      "The agent process cleanup is still pending and the session remains fenced."
    }
  }
}

/// Typed, per-lifecycle-state counts only. This exists so `ClairDaemonHost`
/// can report daemon-wide agent session composition without exposing any
/// session identity, scope, or content.
public struct ClairDaemonAgentSessionCounts: Codable, Equatable, Sendable {
  public let starting: Int
  public let running: Int
  public let stopping: Int
  public let upgrading: Int
  public let cleanupPending: Int
  public let stopped: Int
  public let exited: Int
  public let failed: Int

  public init(
    starting: Int = 0,
    running: Int = 0,
    stopping: Int = 0,
    upgrading: Int = 0,
    cleanupPending: Int = 0,
    stopped: Int = 0,
    exited: Int = 0,
    failed: Int = 0
  ) {
    self.starting = starting
    self.running = running
    self.stopping = stopping
    self.upgrading = upgrading
    self.cleanupPending = cleanupPending
    self.stopped = stopped
    self.exited = exited
    self.failed = failed
  }

  private enum CodingKeys: String, CodingKey {
    case starting
    case running
    case stopping
    case upgrading
    case cleanupPending = "cleanup_pending"
    case stopped
    case exited
    case failed
  }

  init(tallying sessions: [ClairV2AgentSessionSnapshot]) {
    var tally: [ClairV2AgentLifecycleState: Int] = [:]
    for session in sessions {
      tally[session.lifecycle, default: 0] += 1
    }
    self.init(
      starting: tally[.starting] ?? 0,
      running: tally[.running] ?? 0,
      stopping: tally[.stopping] ?? 0,
      upgrading: tally[.upgrading] ?? 0,
      cleanupPending: tally[.cleanupPending] ?? 0,
      stopped: tally[.stopped] ?? 0,
      exited: tally[.exited] ?? 0,
      failed: tally[.failed] ?? 0
    )
  }
}

/// A structured, redacted point-in-time view of one `ClairDaemonHost`. Every
/// field is a typed identifier, enum, or count: no prompt text, terminal
/// byte, credential, file content, or file path is ever represented here.
/// This is the H10 "structured diagnostics" surface referenced by the P0-B
/// gate: it is safe to log or return to an operator without itself becoming
/// a new content-leak channel, matching the redaction precedent already set
/// by H03/H05/H06/H09's own audit/diagnostic types.
public struct ClairDaemonDiagnosticsSnapshot: Codable, Equatable, Sendable {
  public let instanceID: UUID
  public let pairedDeviceCount: Int
  public let activeConnectionCount: Int
  public let agentSessionCounts: ClairDaemonAgentSessionCounts
  public let journalOpenSessionCount: Int
  public let journalSubscriberCount: Int
  public let pushRegistrationCount: Int

  public init(
    instanceID: UUID,
    pairedDeviceCount: Int,
    activeConnectionCount: Int,
    agentSessionCounts: ClairDaemonAgentSessionCounts,
    journalOpenSessionCount: Int,
    journalSubscriberCount: Int,
    pushRegistrationCount: Int
  ) {
    self.instanceID = instanceID
    self.pairedDeviceCount = pairedDeviceCount
    self.activeConnectionCount = activeConnectionCount
    self.agentSessionCounts = agentSessionCounts
    self.journalOpenSessionCount = journalOpenSessionCount
    self.journalSubscriberCount = journalSubscriberCount
    self.pushRegistrationCount = pushRegistrationCount
  }

  private enum CodingKeys: String, CodingKey {
    case instanceID = "instance_id"
    case pairedDeviceCount = "paired_device_count"
    case activeConnectionCount = "active_connection_count"
    case agentSessionCounts = "agent_session_counts"
    case journalOpenSessionCount = "journal_open_session_count"
    case journalSubscriberCount = "journal_subscriber_count"
    case pushRegistrationCount = "push_registration_count"
  }
}

/// The H10 integration/composition root. This is the object a real
/// `ClairDaemon` process would own for its lifetime: it wires the H02
/// workspace catalog, the H03 pairing authority, the H04 provider runtime,
/// the H06 scoped command boundary, the H08 session journal, and the H09
/// push registry into one coherent unit, and adds the two daemon-wide
/// resource bounds and the structured diagnostics surface described above.
///
/// Crash recovery: every piece composed here is in-memory only (no prior
/// H01-H09 task introduced disk persistence). `ClairDaemonHost` does not
/// invent one either. A fresh `ClairDaemonHost` after a real daemon restart
/// therefore starts every subsystem empty, which is by construction
/// fail-closed rather than silently stale:
///
/// - H03's `ClairPairingAuthority` starts with no grants, so a device
///   token from before the restart is rejected as unauthorized rather than
///   accepted or partially trusted.
/// - H04's `ClairV2AgentRuntime` starts with no sessions, so a pre-restart
///   `SessionID` is reported as unknown/stale rather than presented as
///   still running.
/// - H06's `ClairV2AgentCommandBoundary` and H08's `ClairV2SessionJournal`
///   start with no installed/open sessions, so a pre-restart approval
///   reference or subscriber cursor is rejected (`staleSession`,
///   `unknownSession`) rather than replayed from nothing or silently
///   dropped.
/// - H09's `ClairDaemonPushRegistry` starts with no registrations, so a
///   pending wake delivery to a pre-restart device requires the client to
///   register again (`registrationRequired`) rather than believing it is
///   still subscribed.
///
/// What this does *not* provide, and what would require disk or Keychain
/// persistence that no accepted plan/ADR authorizes for H10, is a *seamless*
/// reconnect across a restart (an already-paired device staying paired, or
/// an in-flight session resuming its exact prior journal position without
/// an explicit resync). That remains an explicit external boundary: see the
/// H10 worker report for the full statement of this limitation.
public actor ClairDaemonHost {
  public let instanceID = UUID()
  public let workspace: ClairV2WorkspaceRuntime
  public let authority: ClairPairingAuthority
  public let agentRuntime: ClairV2AgentRuntime
  public let commandBoundary: ClairV2AgentCommandBoundary
  public let journal: ClairV2SessionJournal
  public let pushRegistry: ClairDaemonPushRegistry
  public let limits: ClairDaemonHostLimits

  private var openJournalSessions: Set<SessionID> = []
  private var journalProcessGenerations: [SessionID: UInt64] = [:]
  private var subscriberKeys: Set<SubscriberKey> = []

  /// Race-free admission bookkeeping for the daemon-wide agent-session cap
  /// (Finding #2). `reservedAgentSessionSlots` is the actor-local source of
  /// truth for how many slots are currently spoken for; it is checked and
  /// incremented in one synchronous (no-`await`) step in
  /// `reserveAgentSessionSlot()`, so two concurrent `startSession`/
  /// `resumeSession` calls can never both observe capacity and both admit a
  /// session, unlike re-deriving the count from `agentRuntime.allSessions()`
  /// after an `await`. A slot starts as an anonymous reservation token
  /// (`Set<UUID>`) because the real `SessionID` is not known until after the
  /// awaited `agentRuntime.start`/`resume` call returns; once it is known and
  /// the resulting session is live (`.starting`/`.running`), the token is
  /// additionally indexed by `SessionID` in `agentSessionSlotsBySessionID` so
  /// `stopSession`/`reapExitedSessions` can release it later by session
  /// identity. A slot that never reaches `.starting`/`.running` (immediate
  /// launch failure, or the awaited call throwing) is released immediately
  /// instead of being indexed.
  private var reservedAgentSessionSlots: Set<UUID> = []
  private var agentSessionSlotsBySessionID: [SessionID: UUID] = [:]

  private struct SubscriberKey: Hashable {
    let sessionID: SessionID?
    let subscriberID: ClairV2JournalSubscriberID
  }

  public init(
    workspace: ClairV2WorkspaceRuntime,
    authority: ClairPairingAuthority,
    agentRuntime: ClairV2AgentRuntime,
    pushRelay: any ClairPushSending,
    limits: ClairDaemonHostLimits = .standard,
    commandLimits: ClairV2AgentCommandLimits = .standard,
    journalLimits: ClairV2SessionJournalLimits = .standard,
    pushClock: any ClairPushClock = ClairSystemPushClock(),
    pushCapacity: Int = 1024
  ) throws {
    self.workspace = workspace
    self.authority = authority
    self.agentRuntime = agentRuntime
    self.limits = limits
    // The command boundary and push registry are constructed from the same
    // `authority` instance passed in above (never a caller-supplied one) so
    // that authorization state can never drift between H06/H09 and the rest
    // of the host.
    self.commandBoundary = try ClairV2AgentCommandBoundary(
      authority: authority, limits: commandLimits
    )
    self.journal = ClairV2SessionJournal(limits: journalLimits)
    self.pushRegistry = try ClairDaemonPushRegistry(
      authority: authority, relay: pushRelay, clock: pushClock, capacity: pushCapacity
    )
    Task { [weak self, agentRuntime] in
      await agentRuntime.setLifecycleObserver { [weak self] _ in
        Task { [weak self] in
          _ = await self?.reapExitedSessions()
        }
      }
    }
  }

  // MARK: - G1 step 2: project/worktree/session browsing (H02)

  /// Returns the H02 catalog filtered to the projects the connection's H03
  /// grant can currently view. A project the grant cannot view is omitted
  /// rather than surfaced with an authorization error, matching read-scoping
  /// semantics elsewhere in the daemon.
  public func catalog(
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2WorkspaceCatalog {
    do {
      // Validate the connection even if this workspace has no projects; the
      // per-project loop below cannot provide that guarantee for an empty
      // catalog.
      try await authority.validateConnection(connection)
    } catch {
      throw ClairDaemonHostError.unauthorized
    }
    let full = try workspace.catalog()
    var visible: [ClairV2ProjectCatalogEntry] = []
    for project in full.projects {
      let scope = try ResourceScope(projectID: project.id)
      do {
        // The real H03 path: this enforces token expiry and per-connection
        // scope restriction (see `ClairV2Transport.authorizeRead`), not just
        // grant revocation/generation, before a project is ever listed.
        try await authority.authorizeRead(scope: scope, on: connection)
      } catch ProtocolError.scopeDenied, ProtocolError.capabilityDenied {
        // This one project is outside the grant's visible scopes or
        // capabilities: omit it, matching read-scoping semantics elsewhere
        // in the daemon (a project the grant cannot view is left out rather
        // than surfaced as an authorization error).
        continue
      } catch ClairTransportError.protocolFailure(.scopeDenied) {
        // This one project is outside *this connection's* narrower scope
        // (H03 `authorizeConnectionScope`), even though the device grant
        // covers it: also omit it rather than fail the whole catalog.
        continue
      } catch {
        // Any other failure (connection closed, device revoked, generation
        // mismatch, expired token) means the connection itself is not
        // currently authorized at all, independent of any one project.
        throw ClairDaemonHostError.unauthorized
      }
      visible.append(project)
    }
    return ClairV2WorkspaceCatalog(projects: visible, isTruncated: full.isTruncated)
  }

  // MARK: - G1 step 6: changed files and diff (H07)

  public func diff(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    path: ClairV2WorkspacePath,
    basis: ClairV2GitDiffBasis = .workingTree,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2GitDiff {
    let scope =
      try worktreeID.map { try ResourceScope(projectID: projectID, worktreeID: $0) }
      ?? ResourceScope(projectID: projectID)
    try await requireReadAccess(scope: scope, on: connection)
    return try workspace.gitDiff(
      projectID: projectID, worktreeID: worktreeID, path: path, basis: basis)
  }

  public func changedFiles(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2ChangedFileSummary {
    let scope =
      try worktreeID.map { try ResourceScope(projectID: projectID, worktreeID: $0) }
      ?? ResourceScope(projectID: projectID)
    try await requireReadAccess(scope: scope, on: connection)
    return try workspace.changedFileSummary(projectID: projectID, worktreeID: worktreeID)
  }

  // MARK: - G1 step 3: OpenCode session start/resume (H04) + attach (H06/H08)

  /// Starts a new provider session, enforcing the daemon-wide agent session
  /// cap before ever creating a process, then attaches the resulting running
  /// session to the H06 command boundary and opens its H08 journal entry.
  public func startSession(
    providerID: ClairV2ProviderID,
    target: ClairV2AgentTarget,
    sessionID: SessionID? = nil,
    endpoint: any ClairV2AgentCommandEndpoint,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2AgentSessionSnapshot {
    try await requireCapability(.spawnSession, scope: target.resourceScope, on: connection)
    let resolvedSessionID = sessionID ?? makeSessionID()
    let sessionAlreadyExists =
      (try? await agentRuntime.session(sessionID: resolvedSessionID)) != nil
    let slot = try reserveAgentSessionSlot()
    let snapshot: ClairV2AgentSessionSnapshot
    do {
      snapshot = try await agentRuntime.start(
        providerID: providerID, target: target, sessionID: resolvedSessionID
      )
    } catch {
      if sessionAlreadyExists {
        releaseAgentSessionSlot(slot)
      } else {
        await reconcileFailedStartSlot(slot, sessionID: resolvedSessionID)
      }
      throw error
    }
    resolveAgentSessionSlot(slot, for: snapshot)
    do {
      try attach(snapshot: snapshot, endpoint: endpoint)
    } catch {
      await rollbackFailedAttachment(snapshot)
      throw error
    }
    return snapshot
  }

  /// Resumes an existing (previously stopped/exited) session. The session
  /// must already exist in H04's own bookkeeping; this never fabricates one.
  public func resumeSession(
    sessionID: SessionID,
    endpoint: any ClairV2AgentCommandEndpoint,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2AgentSessionSnapshot {
    // Check the capability before looking up the requested session so a
    // view-only connection cannot use the staleSession/sessionNotFound split
    // as a session-existence oracle.
    try await requireCapability(.spawnSession, on: connection)
    let existing: ClairV2AgentSessionSnapshot
    do {
      existing = try await agentRuntime.session(sessionID: sessionID)
    } catch {
      // A caller that is spawn-capable but outside the session's scope must
      // not learn whether this opaque identifier exists in H04. Normalize
      // lookup failures to the same denial used by the scoped authorization
      // below, including stale/nonexistent IDs.
      throw ClairDaemonHostError.unauthorized
    }
    try await requireCapability(
      .spawnSession, scope: existing.identity.sessionScope, on: connection
    )
    let slot = try reserveAgentSessionSlot()
    let snapshot: ClairV2AgentSessionSnapshot
    do {
      snapshot = try await agentRuntime.resume(sessionID: sessionID)
    } catch {
      releaseAgentSessionSlot(slot)
      throw error
    }
    resolveAgentSessionSlot(slot, for: snapshot)
    do {
      try attach(snapshot: snapshot, endpoint: endpoint)
    } catch {
      await rollbackFailedAttachment(snapshot)
      throw error
    }
    return snapshot
  }

  /// Checks and reserves one daemon-wide agent-session slot in a single
  /// synchronous (no `await`) actor-isolated step. Because this method never
  /// suspends, two concurrent `startSession`/`resumeSession` calls cannot
  /// both observe available capacity and both reserve a slot: an actor only
  /// yields to another call at an `await`, and there is none between the
  /// capacity check and the reservation insert here. This replaces the
  /// former `admitNewAgentSession()`, which re-derived the live count from
  /// `await agentRuntime.allSessions()` — a real cross-actor suspension point
  /// that let concurrent callers race past the same stale count (Finding
  /// #2).
  private func reserveAgentSessionSlot() throws -> UUID {
    guard reservedAgentSessionSlots.count < limits.maximumTotalAgentSessions else {
      throw ClairDaemonHostError.agentSessionCapacityExceeded
    }
    let slot = UUID()
    reservedAgentSessionSlots.insert(slot)
    return slot
  }

  /// Releases a reservation outright: used when the awaited H04 call itself
  /// threw (no session was ever created) or when it returned a snapshot that
  /// never reached `.starting`/`.running` (H04 already reports a terminal
  /// snapshot on its own in that case; see `attach`).
  private func releaseAgentSessionSlot(_ slot: UUID) {
    reservedAgentSessionSlots.remove(slot)
  }

  /// Converts a pending reservation into a durable one indexed by the real
  /// `SessionID` once H04 has returned a live snapshot, so a later
  /// `stopSession`/`reapExitedSessions` transition can find and release it by
  /// session identity. A snapshot that is not `.starting`/`.running` releases
  /// the slot immediately instead: there is no live process occupying it.
  private func resolveAgentSessionSlot(
    _ slot: UUID, for snapshot: ClairV2AgentSessionSnapshot
  ) {
    guard snapshot.lifecycle == .starting || snapshot.lifecycle == .running else {
      releaseAgentSessionSlot(slot)
      return
    }
    if let previous = agentSessionSlotsBySessionID.updateValue(
      slot, forKey: snapshot.identity.sessionID
    ) {
      reservedAgentSessionSlots.remove(previous)
    }
  }

  /// Releases a slot previously resolved to a live session, once that
  /// session has left `.starting`/`.running` for good (explicit stop, or a
  /// crash-recovery transition detected by `reapExitedSessions`). A no-op if
  /// the session never held a slot (e.g. it was never admitted through
  /// `startSession`/`resumeSession`).
  private func releaseAgentSessionSlot(for sessionID: SessionID) {
    guard let slot = agentSessionSlotsBySessionID.removeValue(forKey: sessionID) else { return }
    reservedAgentSessionSlots.remove(slot)
  }

  /// Rolls back a running H04 session when H06/H08 cannot attach it. The
  /// process is stopped before the reservation is released; if H04 cannot
  /// prove cleanup, its `.cleanupPending` state and the host slot remain
  /// visible so a later retry cannot over-admit a live process.
  private func rollbackFailedAttachment(
    _ snapshot: ClairV2AgentSessionSnapshot
  ) async {
    let identity = snapshot.identity
    commandBoundary.invalidate(
      identity: identity, processGeneration: snapshot.processGeneration
    )
    commandBoundary.uninstall(
      identity: identity, processGeneration: snapshot.processGeneration
    )
    journal.close(
      identity: identity, processGeneration: snapshot.processGeneration
    )
    openJournalSessions.remove(identity.sessionID)
    removeSubscriberKeys(for: identity.sessionID)

    guard let stopped = try? await agentRuntime.stop(sessionID: identity.sessionID) else {
      return
    }
    if isTerminal(stopped.lifecycle) {
      releaseAgentSessionSlot(for: identity.sessionID)
    }
  }

  private func attach(
    snapshot: ClairV2AgentSessionSnapshot, endpoint: any ClairV2AgentCommandEndpoint
  ) throws {
    // A session that failed to reach `.running` (immediate exit, launch
    // failure) is never installed into H06/H08: there is no live process
    // generation for either module to authorize commands or append events
    // against, and H04 already reports the terminal snapshot on its own.
    guard snapshot.lifecycle == .running else { return }
    let epoch = try SessionEpoch(snapshot.processGeneration)
    if journalProcessGenerations[snapshot.identity.sessionID] != snapshot.processGeneration {
      removeSubscriberKeys(for: snapshot.identity.sessionID)
    }
    try journal.open(
      identity: snapshot.identity,
      epoch: epoch,
      processGeneration: snapshot.processGeneration
    )
    openJournalSessions.insert(snapshot.identity.sessionID)
    journalProcessGenerations[snapshot.identity.sessionID] = snapshot.processGeneration
    try commandBoundary.install(
      snapshot: snapshot, epoch: epoch, endpoint: endpoint
    )
  }

  // MARK: - G1 steps 4-5: prompt, approval/interrupt (H06) fed by H05 events

  public func execute(
    _ command: ClairV2AgentCommand, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2AgentCommandResult {
    try await commandBoundary.execute(command, on: connection)
  }

  /// Executes a `.stop` command through H06, then performs the real H04
  /// process termination and closes the H08 journal entry once the boundary
  /// confirms the effect was committed. `.stop` is the one command action
  /// with an unambiguous, already-existing H04 method to call
  /// (`agentRuntime.stop(sessionID:)`); H10 wires exactly that connection so
  /// an explicit client stop tears down the real process instead of only
  /// updating H06's bookkeeping.
  @discardableResult
  public func stopSession(
    _ command: ClairV2AgentCommand, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2AgentCommandResult {
    let result = try await commandBoundary.execute(command, on: connection)
    guard command.payload.action == .stop,
      result.outcome == .committed,
      let sessionID = command.scope.sessionID
    else {
      return result
    }
    do {
      let snapshot = try await agentRuntime.stop(sessionID: sessionID)
      commandBoundary.invalidate(
        identity: snapshot.identity, processGeneration: snapshot.processGeneration
      )
      _ = try? journal.updateLifecycle(
        identity: snapshot.identity,
        processGeneration: snapshot.processGeneration,
        lifecycle: snapshot.lifecycle
      )
      if isTerminal(snapshot.lifecycle) {
        commandBoundary.uninstall(
          identity: snapshot.identity, processGeneration: snapshot.processGeneration
        )
        journal.close(
          identity: snapshot.identity, processGeneration: snapshot.processGeneration
        )
        journalProcessGenerations.removeValue(forKey: sessionID)
        openJournalSessions.remove(sessionID)
        removeSubscriberKeys(for: sessionID)
        releaseAgentSessionSlot(for: sessionID)
      }
    } catch {
      // H06 already fenced the committed stop effect. If H04 cannot prove
      // process cleanup, preserve its opaque handle, lifecycle, journal entry,
      // and daemon-wide slot, then return a typed failure instead of reporting
      // a successful stop that left a provider alive.
      if let snapshot = try? await agentRuntime.session(sessionID: sessionID) {
        commandBoundary.invalidate(
          identity: snapshot.identity, processGeneration: snapshot.processGeneration
        )
        _ = try? journal.updateLifecycle(
          identity: snapshot.identity,
          processGeneration: snapshot.processGeneration,
          lifecycle: snapshot.lifecycle
        )
      }
      throw ClairDaemonHostError.agentCleanupPending
    }
    return result
  }

  /// Feeds one normalized H05 event into both the H06 command boundary
  /// (approval/attention/completion bookkeeping) and the H08 journal
  /// (durable-within-process replay log), so a single provider event stream
  /// keeps both in agreement. Ingestion order matters for neither module's
  /// own correctness (each independently applies the same pure
  /// `ReplayState.apply`), but journaling second means a subscriber can
  /// never observe an event the command boundary would still reject.
  public func ingest(_ event: ClairV2AgentNormalizedEvent) throws {
    try commandBoundary.ingest(event)
    _ = try journal.append(event)
  }

  // MARK: - Crash-recovery propagation: H04 exit -> H06/H08 fail-closed

  /// Polls H04 for sessions whose lifecycle has left `.starting`/`.running`
  /// since the last call and propagates the transition into H06 (fail-closed
  /// invalidation of any still-pending approval so a stale approval can
  /// never execute against a dead process generation) and H08 (a typed
  /// lifecycle snapshot instead of silently leaving subscribers attached to
  /// a journal entry that looks live). H04 has no lifecycle-change broadcast
  /// of its own; the daemon composition layer is responsible for noticing
  /// the transition. Call this after any H04-mutating operation (`stop`,
  /// `resume`, `restart`) and periodically while sessions are running, so
  /// H06/H08 never disagree with H04 for longer than one poll interval.
  @discardableResult
  public func reapExitedSessions() async -> [ClairV2AgentSessionSnapshot] {
    let sessions = await agentRuntime.allSessions()
    var transitioned: [ClairV2AgentSessionSnapshot] = []
    for snapshot in sessions {
      let id = snapshot.identity.sessionID
      let cleanupPending = snapshot.lifecycle == .cleanupPending
      guard isTerminal(snapshot.lifecycle) || cleanupPending else { continue }
      let wasAttached = openJournalSessions.contains(id)
      // Also release a daemon-wide agent-session cap slot (Finding #2) for a
      // session that reserved one but never reached `attach`'s `.running`
      // requirement (it stayed `.starting` until it failed/exited): such a
      // session is not in `openJournalSessions` and would otherwise never be
      // reaped, permanently leaking its slot.
      let heldSlot = agentSessionSlotsBySessionID[id] != nil
      guard wasAttached || heldSlot else { continue }
      if wasAttached {
        commandBoundary.invalidate(
          identity: snapshot.identity, processGeneration: snapshot.processGeneration
        )
        _ = try? journal.updateLifecycle(
          identity: snapshot.identity,
          processGeneration: snapshot.processGeneration,
          lifecycle: snapshot.lifecycle
        )
        if isTerminal(snapshot.lifecycle) {
          commandBoundary.uninstall(
            identity: snapshot.identity, processGeneration: snapshot.processGeneration
          )
          journal.close(
            identity: snapshot.identity, processGeneration: snapshot.processGeneration
          )
          openJournalSessions.remove(id)
          journalProcessGenerations.removeValue(forKey: id)
        }
      }
      if isTerminal(snapshot.lifecycle) {
        removeSubscriberKeys(for: id)
        releaseAgentSessionSlot(for: id)
        transitioned.append(snapshot)
      }
    }
    return transitioned
  }

  // MARK: - G1 steps 4/7: journal replay/resync (H08)

  public func subscribeJournal(
    _ subscriberID: ClairV2JournalSubscriberID,
    cursor: ReplayCursor,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2SessionJournalCatchUp {
    try await requireReadAccess(scope: cursor.scope, on: connection)
    let key = SubscriberKey(sessionID: cursor.scope.sessionID, subscriberID: subscriberID)
    if !subscriberKeys.contains(key), subscriberKeys.count >= limits.maximumTotalJournalSubscribers
    {
      throw ClairDaemonHostError.journalSubscriberCapacityExceeded
    }
    let result = try journal.subscribe(subscriberID, cursor: cursor)
    subscriberKeys.insert(key)
    return result
  }

  public func acknowledgeJournal(
    _ subscriberID: ClairV2JournalSubscriberID,
    scope: ResourceScope,
    upTo revision: Revision,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    try await requireReadAccess(scope: scope, on: connection)
    try journal.acknowledge(subscriberID, scope: scope, upTo: revision)
  }

  public func detachJournal(
    _ subscriberID: ClairV2JournalSubscriberID,
    scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    try await requireReadAccess(scope: scope, on: connection)
    journal.detach(subscriberID, scope: scope)
    subscriberKeys.remove(SubscriberKey(sessionID: scope.sessionID, subscriberID: subscriberID))
  }

  // MARK: - G1 step 7: push wake events (H09)

  public func registerPush(
    token: ClairPushDeviceToken,
    generation: UInt64,
    environment: ClairPushEnvironment,
    scope: ResourceScope,
    ttl: UInt64 = ClairPushBounds.maximumRegistrationTTL,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairPushRegistrationSnapshot {
    try await pushRegistry.register(
      token: token, generation: generation, environment: environment, scope: scope, ttl: ttl,
      on: connection
    )
  }

  public func sendPush(
    _ event: ClairDaemonPushEvent,
    to device: ClairDeviceID,
    environment: ClairPushEnvironment
  ) async throws -> ClairPushDeliveryResult {
    try await pushRegistry.send(event, to: device, environment: environment)
  }

  // MARK: - H10 structured diagnostics

  public func diagnostics() async -> ClairDaemonDiagnosticsSnapshot {
    let sessions = await agentRuntime.allSessions()
    let grants = await authority.allGrants()
    // `activeConnectionCount` is the real number of currently-open H03
    // connections (Finding #3): it is independent of `pairedDeviceCount` and
    // must be able to differ from it in both directions (a paired device
    // with zero open connections; one device holding multiple simultaneous
    // connections), unlike re-deriving it from grant revocation status.
    let activeConnectionCount = await authority.activeConnectionCount()
    return ClairDaemonDiagnosticsSnapshot(
      instanceID: instanceID,
      pairedDeviceCount: grants.filter { !$0.isRevoked }.count,
      activeConnectionCount: activeConnectionCount,
      agentSessionCounts: ClairDaemonAgentSessionCounts(tallying: sessions),
      journalOpenSessionCount: openJournalSessions.count,
      journalSubscriberCount: subscriberKeys.count,
      pushRegistrationCount: await pushRegistry.registrationCount()
    )
  }

  // MARK: - Authorization helpers

  /// Both helpers below are thin wrappers over the single real H03
  /// authorization path (`ClairPairingAuthority.authorize(scope:requiring:on:)`,
  /// which `authorizeRead` itself also just calls with `.view`). Neither
  /// re-derives grant validity, token expiry, or connection-scope
  /// containment locally: there is exactly one authorization implementation,
  /// in H03, and every capability check here goes through it.
  private func requireReadAccess(
    scope: ResourceScope, on connection: ClairAuthenticatedConnection
  ) async throws {
    do {
      try await authority.authorizeRead(scope: scope, on: connection)
    } catch {
      throw ClairDaemonHostError.unauthorized
    }
  }

  private func requireCapability(
    _ capability: Capability, scope: ResourceScope, on connection: ClairAuthenticatedConnection
  ) async throws {
    do {
      try await authority.authorize(scope: scope, requiring: capability, on: connection)
    } catch {
      throw ClairDaemonHostError.unauthorized
    }
  }

  private func requireCapability(
    _ capability: Capability, on connection: ClairAuthenticatedConnection
  ) async throws {
    do {
      try await authority.authorize(capability: capability, on: connection)
    } catch {
      throw ClairDaemonHostError.unauthorized
    }
  }

  private func removeSubscriberKeys(for sessionID: SessionID) {
    subscriberKeys = subscriberKeys.filter { $0.sessionID != sessionID }
  }

  private func reconcileFailedStartSlot(_ slot: UUID, sessionID: SessionID) async {
    guard let snapshot = try? await agentRuntime.session(sessionID: sessionID),
      holdsAgentSessionSlot(snapshot.lifecycle)
    else {
      releaseAgentSessionSlot(slot)
      return
    }
    if let previous = agentSessionSlotsBySessionID.updateValue(slot, forKey: sessionID) {
      reservedAgentSessionSlots.remove(previous)
    }
  }

  private func holdsAgentSessionSlot(_ lifecycle: ClairV2AgentLifecycleState) -> Bool {
    switch lifecycle {
    case .starting, .running, .stopping, .upgrading, .cleanupPending:
      true
    case .stopped, .exited, .failed:
      false
    }
  }

  private func isTerminal(_ lifecycle: ClairV2AgentLifecycleState) -> Bool {
    switch lifecycle {
    case .stopped, .exited, .failed:
      true
    case .starting, .running, .stopping, .upgrading, .cleanupPending:
      false
    }
  }

  /// Stops the composed provider runtime before the H01 daemon lifecycle is
  /// allowed to finish. The following reap synchronizes H06/H08 state and the
  /// daemon-wide slot/subscriber accounting with H04's terminal snapshots.
  public func shutdown() async {
    await agentRuntime.shutdown()
    await agentRuntime.setLifecycleObserver(nil)
    _ = await reapExitedSessions()
  }

  private func makeSessionID() -> SessionID {
    while true {
      if let sessionID = try? SessionID(UUID().uuidString.lowercased()) {
        return sessionID
      }
    }
  }
}

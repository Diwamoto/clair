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
  private var subscriberKeys: Set<SubscriberKey> = []

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
  }

  // MARK: - G1 step 2: project/worktree/session browsing (H02)

  /// Returns the H02 catalog filtered to the projects the connection's H03
  /// grant can currently view. A project the grant cannot view is omitted
  /// rather than surfaced with an authorization error, matching read-scoping
  /// semantics elsewhere in the daemon.
  public func catalog(
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2WorkspaceCatalog {
    let full = try workspace.catalog()
    guard let grant = await authority.grant(for: connection.deviceID),
      !grant.isRevoked, grant.generation == connection.generation,
      await authority.isConnectionActive(connection)
    else { throw ClairDaemonHostError.unauthorized }
    let boundary = try AccessBoundary(
      capabilities: grant.capabilities, visibleScopes: grant.visibleScopes
    )
    let visible = try full.projects.filter { project in
      let scope = try ResourceScope(projectID: project.id)
      return (try? boundary.authorize(scope: scope, requiring: .view)) != nil
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
    try await admitNewAgentSession()
    let snapshot = try await agentRuntime.start(
      providerID: providerID, target: target, sessionID: sessionID
    )
    try attach(snapshot: snapshot, endpoint: endpoint)
    return snapshot
  }

  /// Resumes an existing (previously stopped/exited) session. The session
  /// must already exist in H04's own bookkeeping; this never fabricates one.
  public func resumeSession(
    sessionID: SessionID,
    endpoint: any ClairV2AgentCommandEndpoint,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2AgentSessionSnapshot {
    let existing = try await agentRuntime.session(sessionID: sessionID)
    try await requireCapability(
      .spawnSession, scope: existing.identity.sessionScope, on: connection
    )
    try await admitNewAgentSession()
    let snapshot = try await agentRuntime.resume(sessionID: sessionID)
    try attach(snapshot: snapshot, endpoint: endpoint)
    return snapshot
  }

  private func admitNewAgentSession() async throws {
    let liveCount = await agentRuntime.allSessions()
      .filter { $0.lifecycle == .starting || $0.lifecycle == .running }
      .count
    guard liveCount < limits.maximumTotalAgentSessions else {
      throw ClairDaemonHostError.agentSessionCapacityExceeded
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
    try journal.open(
      identity: snapshot.identity,
      epoch: epoch,
      processGeneration: snapshot.processGeneration
    )
    openJournalSessions.insert(snapshot.identity.sessionID)
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
    if result.outcome == .committed, let sessionID = command.scope.sessionID {
      let snapshot = try? await agentRuntime.stop(sessionID: sessionID)
      if let snapshot {
        commandBoundary.invalidate(
          identity: snapshot.identity, processGeneration: snapshot.processGeneration
        )
        _ = try? journal.updateLifecycle(
          identity: snapshot.identity,
          processGeneration: snapshot.processGeneration,
          lifecycle: snapshot.lifecycle
        )
        openJournalSessions.remove(sessionID)
      }
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
      guard openJournalSessions.contains(id) else { continue }
      guard snapshot.lifecycle != .starting, snapshot.lifecycle != .running else { continue }
      commandBoundary.invalidate(
        identity: snapshot.identity, processGeneration: snapshot.processGeneration
      )
      _ = try? journal.updateLifecycle(
        identity: snapshot.identity,
        processGeneration: snapshot.processGeneration,
        lifecycle: snapshot.lifecycle
      )
      openJournalSessions.remove(id)
      transitioned.append(snapshot)
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
    return ClairDaemonDiagnosticsSnapshot(
      instanceID: instanceID,
      pairedDeviceCount: grants.filter { !$0.isRevoked }.count,
      activeConnectionCount: grants.reduce(0) { $0 + ($1.isRevoked ? 0 : 1) },
      agentSessionCounts: ClairDaemonAgentSessionCounts(tallying: sessions),
      journalOpenSessionCount: openJournalSessions.count,
      journalSubscriberCount: subscriberKeys.count,
      pushRegistrationCount: await pushRegistry.registrationCount()
    )
  }

  // MARK: - Authorization helpers

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
    guard let grant = await authority.grant(for: connection.deviceID),
      !grant.isRevoked, grant.generation == connection.generation,
      await authority.isConnectionActive(connection)
    else { throw ClairDaemonHostError.unauthorized }
    do {
      try AccessBoundary(capabilities: grant.capabilities, visibleScopes: grant.visibleScopes)
        .authorize(scope: scope, requiring: capability)
    } catch {
      throw ClairDaemonHostError.unauthorized
    }
  }
}

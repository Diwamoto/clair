import ClairAgent
import ClairShared
import Foundation

/// Errors raised by the H08 session journal. Every failure is typed so that a
/// subscriber cursor the journal cannot serve exactly is never silently
/// treated as "already caught up" or quietly skipped.
public enum ClairSessionJournalError: Error, Equatable, LocalizedError, Sendable {
  case invalidLimits
  case invalidSubscriberID
  case unknownSession
  case sessionCapacity
  case staleGeneration(expected: UInt64, actual: UInt64)
  case journalFaulted
  case unknownSubscriber
  case subscriberCapacity
  case invalidCursor
  case invalidAcknowledgement

  public var errorDescription: String? {
    switch self {
    case .invalidLimits:
      "The session journal limits are invalid."
    case .invalidSubscriberID:
      "The subscriber identifier is empty, too long, or contains control characters."
    case .unknownSession:
      "No journal is open for the requested session, scope, or generation."
    case .sessionCapacity:
      "The session journal has reached its bounded session capacity."
    case .staleGeneration(let expected, let actual):
      "Session generation \(actual) is not newer than the current generation \(expected)."
    case .journalFaulted:
      "The session journal observed a stream discontinuity and must be reopened."
    case .unknownSubscriber:
      "No subscriber is attached with the given identifier."
    case .subscriberCapacity:
      "The session journal has reached its bounded subscriber capacity."
    case .invalidCursor:
      "The subscriber cursor references a revision this journal generation never produced."
    case .invalidAcknowledgement:
      "The subscriber acknowledged a revision it was never delivered."
    }
  }
}

/// A stable identity for one attached reader of a session journal (typically
/// one mobile/native connection). It is intentionally opaque wire text, not a
/// device or connection identity, so the journal never needs to know about
/// transport/pairing concerns.
public struct ClairJournalSubscriberID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard !rawValue.isEmpty,
      rawValue.utf8.count <= 256,
      rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    else { throw ClairSessionJournalError.invalidSubscriberID }
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Bounds for one journal instance. Every bound is a hard, finite retention
/// window: the journal never grows without limit and never blocks on a slow
/// subscriber, so a subscriber that falls behind the window is asked to
/// resync explicitly instead of stalling ingestion for everyone else.
public struct ClairSessionJournalLimits: Codable, Equatable, Sendable {
  public static let defaultEventRetention = 512
  public static let maximumEventRetention = 4_096
  public static let defaultMaximumSessions = 64
  public static let maximumMaximumSessions = 256
  public static let defaultMaximumSubscribersPerSession = 16
  public static let maximumMaximumSubscribersPerSession = 128

  public let eventRetention: Int
  public let maximumSessions: Int
  public let maximumSubscribersPerSession: Int

  public static let standard = try! Self()

  public init(
    eventRetention: Int = Self.defaultEventRetention,
    maximumSessions: Int = Self.defaultMaximumSessions,
    maximumSubscribersPerSession: Int = Self.defaultMaximumSubscribersPerSession
  ) throws {
    guard (1...Self.maximumEventRetention).contains(eventRetention),
      (1...Self.maximumMaximumSessions).contains(maximumSessions),
      (1...Self.maximumMaximumSubscribersPerSession).contains(maximumSubscribersPerSession)
    else { throw ClairSessionJournalError.invalidLimits }
    self.eventRetention = eventRetention
    self.maximumSessions = maximumSessions
    self.maximumSubscribersPerSession = maximumSubscribersPerSession
  }

  private enum CodingKeys: String, CodingKey {
    case eventRetention = "event_retention"
    case maximumSessions = "maximum_sessions"
    case maximumSubscribersPerSession = "maximum_subscribers_per_session"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      eventRetention: container.decode(Int.self, forKey: .eventRetention),
      maximumSessions: container.decode(Int.self, forKey: .maximumSessions),
      maximumSubscribersPerSession: container.decode(
        Int.self, forKey: .maximumSubscribersPerSession)
    )
  }
}

/// A caller-observable checkpoint of one journal generation. It never carries
/// provider/application content: it is exactly enough for a subscriber to
/// adopt a fresh, valid cursor after a resync, and for a caller to confirm
/// which process generation and lifecycle state produced it.
public struct ClairSessionRevisionSnapshot: Codable, Equatable, Sendable {
  public let identity: ClairAgentSessionIdentity
  public let epoch: SessionEpoch
  public let processGeneration: UInt64
  public let lifecycle: ClairAgentLifecycleState
  public let revision: Revision
  public let oldestRetainedRevision: Revision
  public let generatedAt: Date

  public init(
    identity: ClairAgentSessionIdentity,
    epoch: SessionEpoch,
    processGeneration: UInt64,
    lifecycle: ClairAgentLifecycleState,
    revision: Revision,
    oldestRetainedRevision: Revision,
    generatedAt: Date
  ) {
    self.identity = identity
    self.epoch = epoch
    self.processGeneration = processGeneration
    self.lifecycle = lifecycle
    self.revision = revision
    self.oldestRetainedRevision = oldestRetainedRevision
    self.generatedAt = generatedAt
  }

  /// The cursor a subscriber should adopt to resume tailing from exactly this
  /// checkpoint (no replay, no gap).
  public var cursor: ReplayCursor {
    get throws {
      try ReplayCursor(scope: identity.sessionScope, epoch: epoch, revision: revision)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case identity
    case epoch
    case processGeneration = "process_generation"
    case lifecycle
    case revision
    case oldestRetainedRevision = "oldest_retained_revision"
    case generatedAt = "generated_at"
  }
}

/// The result of a subscriber attaching or reattaching with a cursor. A gap
/// or an epoch/generation change never produces an empty/successful replay by
/// accident: it is always a distinct, explicit `.resyncRequired` case.
public enum ClairSessionJournalCatchUp: Equatable, Sendable {
  /// The subscriber's cursor already equals the journal head; nothing to
  /// replay.
  case upToDate(ClairSessionRevisionSnapshot)
  /// Events strictly after the subscriber's cursor, in revision order, that
  /// the journal can serve from its retained window.
  case replay(events: [ClairAgentNormalizedEvent], snapshot: ClairSessionRevisionSnapshot)
  /// The cursor cannot be resumed (compacted out of the retention window, or
  /// from a fenced/older epoch). The subscriber must discard its cursor and
  /// adopt `snapshot.cursor`.
  case resyncRequired(ClairSessionRevisionSnapshot)
}

/// The outcome of ingesting one normalized event into the journal.
public struct ClairSessionJournalAppendResult: Equatable, Sendable {
  public let disposition: ReplayDisposition
  public let revision: Revision

  public init(disposition: ReplayDisposition, revision: Revision) {
    self.disposition = disposition
    self.revision = revision
  }
}

/// The H08 session journal: a bounded, per-session log of H05 normalized
/// events with named subscriber cursors, explicit gap/resync, on-demand
/// revision snapshots, and idempotent event ingestion and acknowledgement.
///
/// This is deliberately independent of `ClairAgentCommandBoundary`'s
/// private per-session `ReplayState` (H06): that state exists only to gate
/// command authorization (pending approvals, staleness), while this journal
/// exists to fan out the same normalized stream to zero or more reconnecting
/// readers (mobile/native clients) with a durable-within-process retention
/// window. Both apply the identical `ReplayState.apply` semantics to the same
/// event, which is safe because it is a pure function of the event and the
/// existing cursor: the two independent applications cannot disagree.
///
/// There is no on-disk persistence layer in the daemon yet (H01-H07 keep
/// all session state in memory). A daemon restart therefore always starts
/// this journal empty. A subscriber cursor from before the restart is neither
/// silently accepted nor silently replayed from nothing: `subscribe` reports
/// `ClairSessionJournalError.unknownSession` (no entry exists for that
/// session) so the caller can surface an explicit "session no longer running"
/// state rather than believe it is caught up. Durable crash recovery across a
/// daemon restart is H10's later integration scope.
public final class ClairSessionJournal: Sendable {
  private let limits: ClairSessionJournalLimits
  private let state: JournalState

  public init(limits: ClairSessionJournalLimits = .standard) {
    self.limits = limits
    self.state = JournalState(limits: limits)
  }

  /// Opens (or idempotently reopens) the journal for a session generation.
  /// Reopening with a strictly newer `processGeneration` and `epoch` starts a
  /// fresh, disjoint revision space; every subscriber already attached under
  /// the previous generation is implicitly fenced and will observe
  /// `.resyncRequired` on its next `subscribe` call.
  @discardableResult
  public func open(
    identity: ClairAgentSessionIdentity,
    epoch: SessionEpoch,
    processGeneration: UInt64,
    lifecycle: ClairAgentLifecycleState = .running,
    startingRevision: Revision = .zero
  ) throws -> ClairSessionRevisionSnapshot {
    try state.open(
      identity: identity, epoch: epoch, processGeneration: processGeneration,
      lifecycle: lifecycle, startingRevision: startingRevision
    )
  }

  /// Records a lifecycle transition (for example H04 reporting `.exited` or
  /// `.failed`) without appending an event. Subscribers observe this only
  /// through the returned/queried snapshot, never as a silent state change.
  @discardableResult
  public func updateLifecycle(
    identity: ClairAgentSessionIdentity,
    processGeneration: UInt64,
    lifecycle: ClairAgentLifecycleState
  ) throws -> ClairSessionRevisionSnapshot {
    try state.updateLifecycle(
      identity: identity, processGeneration: processGeneration, lifecycle: lifecycle
    )
  }

  /// Ingests one normalized H05 event. A duplicate (identical) event is
  /// idempotent and returns `.duplicate` without growing the retained window;
  /// a gap, regression, or conflicting reuse is a typed failure that faults
  /// the journal generation rather than silently accepting a broken index.
  @discardableResult
  public func append(
    _ event: ClairAgentNormalizedEvent
  ) throws -> ClairSessionJournalAppendResult {
    try state.append(event)
  }

  /// Attaches (or reattaches, after a network switch or app relaunch) a
  /// subscriber at `cursor`. Safe to call repeatedly with the same
  /// unacknowledged cursor: the result is a deterministic function of journal
  /// state, so a retried call after a dropped response reproduces the same
  /// batch instead of skipping or duplicating events.
  public func subscribe(
    _ subscriberID: ClairJournalSubscriberID,
    cursor: ReplayCursor
  ) throws -> ClairSessionJournalCatchUp {
    try state.subscribe(subscriberID, cursor: cursor)
  }

  /// Idempotently advances a subscriber's confirmed position. Re-acknowledging
  /// an already-confirmed (or older) revision is a safe no-op; acknowledging a
  /// revision that was never delivered to this subscriber is rejected.
  public func acknowledge(
    _ subscriberID: ClairJournalSubscriberID,
    scope: ResourceScope,
    upTo revision: Revision
  ) throws {
    try state.acknowledge(subscriberID, scope: scope, upTo: revision)
  }

  /// Detaches a subscriber. Safe to call for an unknown session/subscriber.
  public func detach(_ subscriberID: ClairJournalSubscriberID, scope: ResourceScope) {
    state.detach(subscriberID, scope: scope)
  }

  /// Closes the journal entry for an exact identity/generation. A later
  /// `subscribe` for that session then observes `.unknownSession` rather than
  /// stale data.
  public func close(identity: ClairAgentSessionIdentity, processGeneration: UInt64) {
    state.close(identity: identity, processGeneration: processGeneration)
  }

  /// Returns the current revision snapshot without attaching a subscriber.
  public func snapshot(scope: ResourceScope) throws -> ClairSessionRevisionSnapshot {
    try state.snapshot(scope: scope)
  }
}

/// Every mutation is a single synchronous critical section under `lock`. No
/// call awaits or invokes back into caller-supplied code while holding it, so
/// this cannot deadlock or reenter regardless of how the daemon schedules
/// H04/H05 ingestion versus subscriber RPCs.
private final class JournalState: @unchecked Sendable {
  fileprivate struct SubscriberState {
    var lastDeliveredRevision: Revision
    var lastAcknowledgedRevision: Revision
    var attachedAt: Date
  }

  fileprivate struct SessionEntry {
    var identity: ClairAgentSessionIdentity
    var processGeneration: UInt64
    var lifecycle: ClairAgentLifecycleState
    var epoch: SessionEpoch
    var replay: ReplayState
    var buffer: [ClairAgentNormalizedEvent] = []
    var subscribers: [ClairJournalSubscriberID: SubscriberState] = [:]
    var faulted = false
  }

  private let lock = NSLock()
  private let limits: ClairSessionJournalLimits
  private var sessions: [SessionID: SessionEntry] = [:]

  init(limits: ClairSessionJournalLimits) {
    self.limits = limits
  }

  func open(
    identity: ClairAgentSessionIdentity,
    epoch: SessionEpoch,
    processGeneration: UInt64,
    lifecycle: ClairAgentLifecycleState,
    startingRevision: Revision
  ) throws -> ClairSessionRevisionSnapshot {
    try lock.withLock {
      let id = identity.sessionID
      if let existing = sessions[id] {
        guard existing.identity == identity else {
          throw ClairSessionJournalError.staleGeneration(
            expected: existing.processGeneration, actual: processGeneration)
        }
        if existing.processGeneration == processGeneration, existing.epoch == epoch,
          !existing.faulted
        {
          // Idempotent reopen of the same live generation: return the current
          // snapshot instead of resetting history out from under attached
          // subscribers (for example a duplicate H04 install callback).
          return makeSnapshot(existing)
        }
        guard processGeneration > existing.processGeneration, epoch > existing.epoch else {
          throw ClairSessionJournalError.staleGeneration(
            expected: existing.processGeneration, actual: processGeneration)
        }
        // A strictly newer generation/epoch starts a fresh, disjoint revision
        // space. Subscribers attached under the old entry are fenced by this
        // replacement; their next `subscribe` call observes the epoch
        // mismatch below and returns `.resyncRequired`, never silence.
      } else if sessions.count >= limits.maximumSessions {
        throw ClairSessionJournalError.sessionCapacity
      }
      let entry = SessionEntry(
        identity: identity,
        processGeneration: processGeneration,
        lifecycle: lifecycle,
        epoch: epoch,
        replay: try ReplayState(
          cursor: ReplayCursor(
            scope: identity.sessionScope, epoch: epoch, revision: startingRevision
          ),
          // ReplayState's own event-identity dedupe window must never be
          // narrower than the buffer we actually retain: otherwise a
          // legitimate retry of an old-but-still-buffered event falls out of
          // ReplayState's fingerprint memory first, is misread as a
          // regression, and faults the journal for every subscriber even
          // though nothing was actually lost or reordered.
          maximumEventHistory: limits.eventRetention
        )
      )
      sessions[id] = entry
      return makeSnapshot(entry)
    }
  }

  func updateLifecycle(
    identity: ClairAgentSessionIdentity,
    processGeneration: UInt64,
    lifecycle: ClairAgentLifecycleState
  ) throws -> ClairSessionRevisionSnapshot {
    try lock.withLock {
      guard var entry = sessions[identity.sessionID], entry.identity == identity,
        entry.processGeneration == processGeneration
      else { throw ClairSessionJournalError.unknownSession }
      entry.lifecycle = lifecycle
      sessions[identity.sessionID] = entry
      return makeSnapshot(entry)
    }
  }

  func append(
    _ event: ClairAgentNormalizedEvent
  ) throws -> ClairSessionJournalAppendResult {
    try lock.withLock {
      guard let id = event.scope.sessionID, var entry = sessions[id] else {
        throw ClairSessionJournalError.unknownSession
      }
      guard !entry.faulted else { throw ClairSessionJournalError.journalFaulted }
      guard event.scope == entry.identity.sessionScope, event.epoch == entry.epoch else {
        // An event from a fenced/foreign generation must never silently
        // extend the live journal, even though `ReplayState.apply` would
        // also reject the scope mismatch on its own.
        throw ClairSessionJournalError.unknownSession
      }
      do {
        let disposition = try entry.replay.apply(event)
        if disposition == .applied {
          entry.buffer.append(event)
          if entry.buffer.count > limits.eventRetention {
            entry.buffer.removeFirst()
          }
        }
        let revision = entry.replay.cursor.revision
        sessions[id] = entry
        return ClairSessionJournalAppendResult(disposition: disposition, revision: revision)
      } catch {
        // A gap, regression, or conflicting reuse means the retained window
        // can no longer be trusted as a contiguous tail. Fault the whole
        // generation rather than silently continuing to serve subscribers
        // from a broken index; recovery is a fresh `open` with a new
        // generation/epoch, mirroring H06's fail-closed session handling.
        entry.faulted = true
        sessions[id] = entry
        throw error
      }
    }
  }

  func subscribe(
    _ subscriberID: ClairJournalSubscriberID,
    cursor: ReplayCursor
  ) throws -> ClairSessionJournalCatchUp {
    try lock.withLock {
      guard let id = cursor.scope.sessionID, var entry = sessions[id] else {
        throw ClairSessionJournalError.unknownSession
      }
      guard !entry.faulted else { throw ClairSessionJournalError.journalFaulted }
      guard
        entry.subscribers[subscriberID] != nil
          || entry.subscribers.count < limits.maximumSubscribersPerSession
      else { throw ClairSessionJournalError.subscriberCapacity }

      let head = entry.replay.cursor.revision
      let snapshot = makeSnapshot(entry)

      guard cursor.scope == entry.identity.sessionScope, cursor.epoch == entry.epoch else {
        // A different epoch (fenced/older generation, or a daemon restart
        // that relaunched the provider process) cannot be resumed from. The
        // subscriber must discard its cursor and adopt the fresh snapshot.
        attach(&entry, subscriberID: subscriberID, delivered: head, acknowledged: head)
        sessions[id] = entry
        return .resyncRequired(snapshot)
      }

      guard cursor.revision <= head else {
        // The subscriber claims a revision this epoch never produced. Resync
        // cannot repair a revision higher than any the journal ever emitted;
        // this is reported as a hard error, not treated as caught up.
        throw ClairSessionJournalError.invalidCursor
      }

      if cursor.revision == head {
        attach(&entry, subscriberID: subscriberID, delivered: head, acknowledged: head)
        sessions[id] = entry
        return .upToDate(snapshot)
      }

      guard let oldest = entry.buffer.first?.revision, oldest.value <= cursor.revision.value + 1
      else {
        // The needed tail has already left the bounded retention window (a
        // slow subscriber, or a long disconnect/network switch). Report the
        // gap explicitly as a resync instead of serving a partial/empty
        // replay that would look like "already caught up".
        attach(&entry, subscriberID: subscriberID, delivered: head, acknowledged: head)
        sessions[id] = entry
        return .resyncRequired(snapshot)
      }

      // Every event retained in `buffer` was accepted by `ReplayState.apply`,
      // which requires a non-nil revision; the fallback is unreachable.
      let toReplay = entry.buffer.filter { ($0.revision ?? .zero) > cursor.revision }
      attach(&entry, subscriberID: subscriberID, delivered: head, acknowledged: cursor.revision)
      sessions[id] = entry
      return .replay(events: toReplay, snapshot: snapshot)
    }
  }

  func acknowledge(
    _ subscriberID: ClairJournalSubscriberID,
    scope: ResourceScope,
    upTo revision: Revision
  ) throws {
    try lock.withLock {
      guard let id = scope.sessionID, var entry = sessions[id],
        entry.identity.sessionScope == scope
      else { throw ClairSessionJournalError.unknownSession }
      guard var subscriber = entry.subscribers[subscriberID] else {
        throw ClairSessionJournalError.unknownSubscriber
      }
      // Idempotent: re-acknowledging an already-confirmed (or older) revision
      // is a safe no-op so a retried ack after a network switch cannot error
      // or regress state that already advanced.
      guard revision > subscriber.lastAcknowledgedRevision else { return }
      guard revision <= subscriber.lastDeliveredRevision else {
        // A subscriber cannot legitimately confirm receipt of a revision the
        // journal never delivered to it.
        throw ClairSessionJournalError.invalidAcknowledgement
      }
      subscriber.lastAcknowledgedRevision = revision
      entry.subscribers[subscriberID] = subscriber
      sessions[id] = entry
    }
  }

  func detach(_ subscriberID: ClairJournalSubscriberID, scope: ResourceScope) {
    lock.withLock {
      guard let id = scope.sessionID, var entry = sessions[id] else { return }
      entry.subscribers.removeValue(forKey: subscriberID)
      sessions[id] = entry
    }
  }

  func close(identity: ClairAgentSessionIdentity, processGeneration: UInt64) {
    lock.withLock {
      guard let entry = sessions[identity.sessionID], entry.identity == identity,
        entry.processGeneration == processGeneration
      else { return }
      sessions.removeValue(forKey: identity.sessionID)
    }
  }

  func snapshot(scope: ResourceScope) throws -> ClairSessionRevisionSnapshot {
    try lock.withLock {
      guard let id = scope.sessionID, let entry = sessions[id],
        entry.identity.sessionScope == scope
      else { throw ClairSessionJournalError.unknownSession }
      return makeSnapshot(entry)
    }
  }

  private func attach(
    _ entry: inout SessionEntry,
    subscriberID: ClairJournalSubscriberID,
    delivered: Revision,
    acknowledged: Revision
  ) {
    entry.subscribers[subscriberID] = SubscriberState(
      lastDeliveredRevision: delivered, lastAcknowledgedRevision: acknowledged,
      attachedAt: Date()
    )
  }

  private func makeSnapshot(_ entry: SessionEntry) -> ClairSessionRevisionSnapshot {
    ClairSessionRevisionSnapshot(
      identity: entry.identity,
      epoch: entry.epoch,
      processGeneration: entry.processGeneration,
      lifecycle: entry.lifecycle,
      revision: entry.replay.cursor.revision,
      oldestRetainedRevision: entry.buffer.first?.revision ?? entry.replay.cursor.revision,
      generatedAt: Date()
    )
  }
}

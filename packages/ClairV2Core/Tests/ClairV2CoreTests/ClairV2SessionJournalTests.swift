import Foundation
import Testing

@testable import ClairV2Agent
@testable import ClairV2DaemonKit
@testable import ClairV2Shared

private struct H08Fixture {
  let identity: ClairV2AgentSessionIdentity
  let epoch: SessionEpoch

  static func make(
    project: String = "project-h08", worktree: String? = "worktree-h08",
    session: String = "session-h08"
  ) throws -> Self {
    let identity = try ClairV2AgentSessionIdentity(
      provider: ClairV2ProviderIdentity(
        providerID: .openCode, version: ClairV2ProviderVersion("h08")),
      projectID: ProjectID(project), worktreeID: worktree.map { try WorktreeID($0) },
      sessionID: SessionID(session)
    )
    return Self(identity: identity, epoch: try SessionEpoch(1))
  }

  func event(
    revision: UInt64, epoch: SessionEpoch? = nil, eventID: String? = nil,
    text: String = "delta"
  ) throws -> ClairV2AgentNormalizedEvent {
    let payload = ClairV2AgentEventPayload.conversation(
      ClairV2AgentConversationEvent(role: .assistant, text: text)
    )
    return try EventEnvelope(
      eventID: EventID(eventID ?? "event-\(revision)"), kind: payload.kind.wireKind,
      scope: identity.sessionScope, epoch: epoch ?? self.epoch, revision: Revision(revision),
      payload: payload
    )
  }

  func cursor(revision: UInt64, epoch: SessionEpoch? = nil) throws -> ReplayCursor {
    try ReplayCursor(
      scope: identity.sessionScope, epoch: epoch ?? self.epoch, revision: Revision(revision))
  }
}

private func h08Reject(
  _ expected: ClairV2SessionJournalError, _ body: () throws -> Void
) {
  do {
    try body()
    Issue.record("Expected rejection: \(expected)")
  } catch let error as ClairV2SessionJournalError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected error type: \(type(of: error))")
  }
}

@Suite
struct H08SessionJournalTests {
  @Test
  func h08OpenReturnsInitialSnapshotAtStartingRevision() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    let snapshot = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    #expect(snapshot.revision == .zero)
    #expect(snapshot.oldestRetainedRevision == .zero)
    #expect(snapshot.epoch == f.epoch)
    #expect(snapshot.processGeneration == 1)
    #expect(snapshot.lifecycle == .running)
  }

  @Test
  func h08ReopenSameGenerationIsIdempotent() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    _ = try journal.append(try f.event(revision: 1))
    // A duplicate install callback for the same live generation must not
    // reset the journal's history.
    let snapshot = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    #expect(snapshot.revision == Revision(1))
  }

  @Test
  func h08ReopenWithoutNewerGenerationOrEpochIsRejected() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 2)
    h08Reject(.staleGeneration(expected: 2, actual: 1)) {
      _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    }
    h08Reject(.staleGeneration(expected: 2, actual: 3)) {
      // Newer generation but the same epoch must also be rejected: epoch and
      // generation must advance together to open a fresh revision space.
      _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 3)
    }
  }

  @Test
  func h08AppendAdvancesHeadAndReturnsAppliedDisposition() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    let result = try journal.append(try f.event(revision: 1))
    #expect(result.disposition == .applied)
    #expect(result.revision == Revision(1))
  }

  @Test
  func h08DuplicateAppendIsIdempotentAndDoesNotDuplicateRevision() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    let event = try f.event(revision: 1)
    let first = try journal.append(event)
    let second = try journal.append(event)
    #expect(first.disposition == .applied)
    #expect(second.disposition == .duplicate)
    #expect(second.revision == first.revision)
    let snapshot = try journal.snapshot(scope: f.identity.sessionScope)
    #expect(snapshot.revision == Revision(1))
  }

  @Test
  func h08GapAppendFaultsTheJournalInsteadOfSilentlySkipping() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    _ = try journal.append(try f.event(revision: 1))
    #expect(throws: ProtocolError.self) {
      // Revision 3 skips 2: this must never be silently accepted as the new
      // head.
      _ = try journal.append(try f.event(revision: 3))
    }
    // The journal generation is now faulted: further appends and subscribes
    // fail closed rather than silently resuming from a broken index.
    h08Reject(.journalFaulted) {
      _ = try journal.append(try f.event(revision: 2, eventID: "event-2-retry"))
    }
    h08Reject(.journalFaulted) {
      _ = try journal.subscribe(
        try ClairV2JournalSubscriberID("sub"), cursor: try f.cursor(revision: 0))
    }
  }

  @Test
  func h08RetryOfOldEventWithinRetentionButBeyondReplayHistoryIsDuplicateNotFault() throws {
    // Regression test for a D5 review finding: `ReplayState`'s own
    // event-identity dedupe window (`ReplayState.defaultEventHistory`, 256
    // entries) used to be narrower than the journal's actual retained event
    // buffer (`ClairV2SessionJournalLimits.defaultEventRetention`, 512
    // entries). A legitimate retry of an event still inside the journal's
    // buffer but already evicted from that narrower internal window was
    // misread as `replayRegression`, faulting the whole session generation
    // and starving every subscriber, including unrelated ones. `open` now
    // sizes `ReplayState`'s history to match the journal's own retention.
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    let firstEvent = try f.event(revision: 1)
    let firstAppend = try journal.append(firstEvent)
    #expect(firstAppend.disposition == .applied)

    // Push revision 1 out of ReplayState's narrower default fingerprint
    // window while it is still well inside the journal's larger default
    // retention buffer.
    let overflowCount = ReplayState.defaultEventHistory + 50
    for revision in 2...(overflowCount + 1) {
      _ = try journal.append(try f.event(revision: UInt64(revision)))
    }
    let snapshotBeforeRetry = try journal.snapshot(scope: f.identity.sessionScope)
    #expect(snapshotBeforeRetry.oldestRetainedRevision == Revision(1))
    #expect(snapshotBeforeRetry.revision == Revision(UInt64(overflowCount + 1)))

    // A legitimate retry of the exact same, byte-identical, already-applied
    // event must be reported as a duplicate, never misread as a regression.
    let retry = try journal.append(firstEvent)
    #expect(retry.disposition == .duplicate)
    #expect(retry.revision == snapshotBeforeRetry.revision)

    // An unrelated, brand-new subscriber must never be starved by another
    // client's retry: the journal generation must still be fully usable.
    let outcome = try journal.subscribe(
      try ClairV2JournalSubscriberID("innocent-bystander"), cursor: try f.cursor(revision: 0))
    guard case .replay(let events, _) = outcome else {
      Issue.record("Expected replay for an unaffected new subscriber, got \(outcome)")
      return
    }
    #expect(events.count == overflowCount + 1)
  }

  @Test
  func h08SubscribeAtHeadReturnsUpToDate() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    _ = try journal.append(try f.event(revision: 1))
    let outcome = try journal.subscribe(
      try ClairV2JournalSubscriberID("sub"), cursor: try f.cursor(revision: 1))
    guard case .upToDate(let snapshot) = outcome else {
      Issue.record("Expected upToDate, got \(outcome)")
      return
    }
    #expect(snapshot.revision == Revision(1))
  }

  @Test
  func h08SubscribeBehindHeadReplaysExactlyMissingEventsOnNetworkSwitch() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    for revision in 1...5 {
      _ = try journal.append(try f.event(revision: UInt64(revision)))
    }
    // Simulate a mobile client that attached at revision 2 (for example,
    // right before the network switched) and reconnects afterward.
    let outcome = try journal.subscribe(
      try ClairV2JournalSubscriberID("mobile-1"), cursor: try f.cursor(revision: 2))
    guard case .replay(let events, let snapshot) = outcome else {
      Issue.record("Expected replay, got \(outcome)")
      return
    }
    #expect(events.map { $0.revision } == [3, 4, 5].map { Revision(UInt64($0)) })
    #expect(snapshot.revision == Revision(5))
  }

  @Test
  func h08RepeatedSubscribeBeforeAcknowledgeIsIdempotent() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    for revision in 1...3 {
      _ = try journal.append(try f.event(revision: UInt64(revision)))
    }
    let subscriberID = try ClairV2JournalSubscriberID("mobile-retry")
    let first = try journal.subscribe(subscriberID, cursor: try f.cursor(revision: 0))
    // A retried RPC (the response to the first call was lost, so the client
    // resubmits the identical, still-unacknowledged cursor) must reproduce
    // the same batch rather than skip or duplicate events.
    let second = try journal.subscribe(subscriberID, cursor: try f.cursor(revision: 0))
    guard case .replay(let firstEvents, _) = first, case .replay(let secondEvents, _) = second
    else {
      Issue.record("Expected replay for both attempts")
      return
    }
    #expect(firstEvents == secondEvents)
  }

  @Test
  func h08SlowSubscriberBeyondRetentionWindowGetsExplicitResync() throws {
    let f = try H08Fixture.make()
    let limits = try ClairV2SessionJournalLimits(eventRetention: 4)
    let journal = ClairV2SessionJournal(limits: limits)
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    let subscriberID = try ClairV2JournalSubscriberID("slow-client")
    _ = try journal.append(try f.event(revision: 1))
    _ = try journal.subscribe(subscriberID, cursor: try f.cursor(revision: 0))
    // The subscriber never acknowledges and never resubscribes while many
    // more events arrive, pushing revision 1 out of the bounded retention
    // window.
    for revision in 2...10 {
      _ = try journal.append(try f.event(revision: UInt64(revision)))
    }
    let outcome = try journal.subscribe(subscriberID, cursor: try f.cursor(revision: 0))
    guard case .resyncRequired(let snapshot) = outcome else {
      Issue.record("Expected resyncRequired, got \(outcome)")
      return
    }
    #expect(snapshot.revision == Revision(10))
    #expect(snapshot.oldestRetainedRevision.value >= 7)
  }

  @Test
  func h08OutOfRangeCursorAheadOfHeadIsRejectedNotAcceptedAsCaughtUp() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    _ = try journal.append(try f.event(revision: 1))
    h08Reject(.invalidCursor) {
      _ = try journal.subscribe(
        try ClairV2JournalSubscriberID("ahead"), cursor: try f.cursor(revision: 99))
    }
  }

  @Test
  func h08DaemonRestartWithFreshJournalRejectsStaleCursorExplicitly() throws {
    let f = try H08Fixture.make()
    let beforeRestart = ClairV2SessionJournal()
    _ = try beforeRestart.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    _ = try beforeRestart.append(try f.event(revision: 1))
    let staleCursor = try f.cursor(revision: 1)

    // A daemon restart has no durable persistence layer yet (H10 owns crash
    // recovery); it always starts a fresh, empty journal instance. A
    // subscriber's pre-restart cursor must be reported as unresumable, never
    // silently treated as caught-up-with-nothing.
    let afterRestart = ClairV2SessionJournal()
    h08Reject(.unknownSession) {
      _ = try afterRestart.subscribe(
        try ClairV2JournalSubscriberID("survivor"), cursor: staleCursor)
    }
  }

  @Test
  func h08NewProcessGenerationFencesOldSubscriberIntoResync() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    _ = try journal.append(try f.event(revision: 1))
    let subscriberID = try ClairV2JournalSubscriberID("mobile-1")
    _ = try journal.subscribe(subscriberID, cursor: try f.cursor(revision: 1))

    // The daemon relaunches the OpenCode session (H04 abnormal-exit recovery)
    // with a new process generation and epoch, without a full daemon
    // restart.
    let newEpoch = try SessionEpoch(2)
    _ = try journal.open(
      identity: f.identity, epoch: newEpoch, processGeneration: 2, startingRevision: .zero)

    // The subscriber's old (generation 1) cursor can no longer be resumed:
    // it must observe an explicit resync into the new epoch, not silence.
    let outcome = try journal.subscribe(subscriberID, cursor: try f.cursor(revision: 1))
    guard case .resyncRequired(let snapshot) = outcome else {
      Issue.record("Expected resyncRequired, got \(outcome)")
      return
    }
    #expect(snapshot.epoch == newEpoch)
    #expect(snapshot.processGeneration == 2)
    #expect(snapshot.revision == .zero)
  }

  @Test
  func h08AcknowledgeIsIdempotentAndMonotonic() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    for revision in 1...3 {
      _ = try journal.append(try f.event(revision: UInt64(revision)))
    }
    let subscriberID = try ClairV2JournalSubscriberID("acker")
    _ = try journal.subscribe(subscriberID, cursor: try f.cursor(revision: 0))
    try journal.acknowledge(subscriberID, scope: f.identity.sessionScope, upTo: Revision(2))
    // Re-acknowledging an older revision is a safe no-op, not a regression or
    // an error (covers a retried ack after a network switch).
    try journal.acknowledge(subscriberID, scope: f.identity.sessionScope, upTo: Revision(1))
    try journal.acknowledge(subscriberID, scope: f.identity.sessionScope, upTo: Revision(2))
    try journal.acknowledge(subscriberID, scope: f.identity.sessionScope, upTo: Revision(3))
  }

  @Test
  func h08AcknowledgeRejectsARevisionNeverDelivered() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    _ = try journal.append(try f.event(revision: 1))
    let subscriberID = try ClairV2JournalSubscriberID("acker-2")
    _ = try journal.subscribe(subscriberID, cursor: try f.cursor(revision: 0))
    _ = try journal.append(try f.event(revision: 2))
    h08Reject(.invalidAcknowledgement) {
      // The subscriber was only delivered up to revision 1; it cannot
      // legitimately confirm revision 2 before resubscribing.
      try journal.acknowledge(subscriberID, scope: f.identity.sessionScope, upTo: Revision(2))
    }
  }

  @Test
  func h08AcknowledgeForUnknownSubscriberIsRejected() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    h08Reject(.unknownSubscriber) {
      try journal.acknowledge(
        try ClairV2JournalSubscriberID("never-subscribed"), scope: f.identity.sessionScope,
        upTo: .zero)
    }
  }

  @Test
  func h08SessionCapacityIsBounded() throws {
    let limits = try ClairV2SessionJournalLimits(maximumSessions: 1)
    let journal = ClairV2SessionJournal(limits: limits)
    let first = try H08Fixture.make(session: "session-a")
    let second = try H08Fixture.make(session: "session-b")
    _ = try journal.open(identity: first.identity, epoch: first.epoch, processGeneration: 1)
    h08Reject(.sessionCapacity) {
      _ = try journal.open(identity: second.identity, epoch: second.epoch, processGeneration: 1)
    }
  }

  @Test
  func h08SubscriberCapacityIsBoundedPerSession() throws {
    let f = try H08Fixture.make()
    let limits = try ClairV2SessionJournalLimits(maximumSubscribersPerSession: 1)
    let journal = ClairV2SessionJournal(limits: limits)
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    _ = try journal.subscribe(
      try ClairV2JournalSubscriberID("a"), cursor: try f.cursor(revision: 0))
    h08Reject(.subscriberCapacity) {
      _ = try journal.subscribe(
        try ClairV2JournalSubscriberID("b"), cursor: try f.cursor(revision: 0))
    }
    // Reattaching the same, already-registered subscriber never counts twice
    // against the capacity bound.
    _ = try journal.subscribe(
      try ClairV2JournalSubscriberID("a"), cursor: try f.cursor(revision: 0))
  }

  @Test
  func h08CloseThenSubscribeIsUnknownSession() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    journal.close(identity: f.identity, processGeneration: 1)
    h08Reject(.unknownSession) {
      _ = try journal.subscribe(
        try ClairV2JournalSubscriberID("late"), cursor: try f.cursor(revision: 0))
    }
  }

  @Test
  func h08UpdateLifecycleIsVisibleInSnapshotWithoutAnEvent() throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)
    let updated = try journal.updateLifecycle(
      identity: f.identity, processGeneration: 1, lifecycle: .failed)
    #expect(updated.lifecycle == .failed)
    let snapshot = try journal.snapshot(scope: f.identity.sessionScope)
    #expect(snapshot.lifecycle == .failed)
  }

  @Test
  func h08ConcurrentAppendAndSubscribeNeverCorruptTheJournal() async throws {
    let f = try H08Fixture.make()
    let journal = ClairV2SessionJournal()
    _ = try journal.open(identity: f.identity, epoch: f.epoch, processGeneration: 1)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for revision in 1...200 {
          _ = try journal.append(try f.event(revision: UInt64(revision)))
        }
      }
      for index in 0..<8 {
        group.addTask {
          let subscriberID = try ClairV2JournalSubscriberID("concurrent-\(index)")
          for _ in 0..<20 {
            _ = try? journal.subscribe(subscriberID, cursor: try f.cursor(revision: 0))
          }
        }
      }
      try await group.waitForAll()
    }
    let snapshot = try journal.snapshot(scope: f.identity.sessionScope)
    #expect(snapshot.revision == Revision(200))
  }
}

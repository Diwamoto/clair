import CryptoKit
import Dispatch
import Foundation
import Testing

@testable import ClairV2Agent
@testable import ClairV2DaemonKit
@testable import ClairV2Shared
@testable import ClairV2Transport

private final class H06Clock: ClairTransportClock, @unchecked Sendable {
  private let lock = NSLock()
  private var instant = Date(timeIntervalSince1970: 1_800_000_000)
  func now() -> Date { lock.withLock { instant } }
  func advance(_ seconds: TimeInterval) {
    lock.withLock { instant = instant.addingTimeInterval(seconds) }
  }
}

private final class H06Endpoint: ClairV2AgentCommandEndpoint, @unchecked Sendable {
  private let lock = NSLock()
  private var effects: [ClairV2AgentCommandEffect] = []
  let outcome: ClairV2AgentCommandOutcome
  let barrier: (@Sendable () -> Void)?

  init(
    outcome: ClairV2AgentCommandOutcome = .committed, barrier: (@Sendable () -> Void)? = nil
  ) {
    self.outcome = outcome
    self.barrier = barrier
  }

  func commit(_ effect: ClairV2AgentCommandEffect) -> ClairV2AgentCommandOutcome {
    barrier?()
    lock.withLock { effects.append(effect) }
    return outcome
  }

  var captured: [ClairV2AgentCommandEffect] { lock.withLock { effects } }
}

private struct H06Fixture: Sendable {
  let authority: ClairPairingAuthority
  let client: ClairNativeClientTransport
  let connection: ClairAuthenticatedConnection
  let clock: H06Clock
  let identity: ClairV2AgentSessionIdentity
  let epoch: SessionEpoch
  let endpoint: H06Endpoint
  let boundary: ClairV2AgentCommandBoundary

  static func make(
    worktree: String? = "worktree-h06",
    capabilities: [Capability] = [.view, .steerAgent, .approve, .signal, .terminate],
    limits: ClairV2AgentCommandLimits = .standard,
    endpoint: H06Endpoint = H06Endpoint(),
    exactConnectionScope: Bool = false,
    project: String = "project-h06"
  ) async throws -> Self {
    let identity = try ClairV2AgentSessionIdentity(
      provider: ClairV2ProviderIdentity(
        providerID: .openCode, version: ClairV2ProviderVersion("h06")),
      projectID: ProjectID(project), worktreeID: worktree.map { try WorktreeID($0) },
      sessionID: SessionID("session-h06")
    )
    let clock = H06Clock()
    let authority = try ClairPairingAuthority(
      hostID: ClairHostID("host-h06"), endpoint: ClairTransportEndpoint("wss://h06.example.test"),
      defaultVisibleScopes: [identity.scope], tokenLifetime: 60, clock: clock
    )
    let client = ClairNativeClientTransport(deviceKey: ClairDeviceKey())
    let link = try await authority.issuePairingLink(lifetime: 60)
    let paired = try await client.pair(
      using: link, with: authority, displayName: "H06 fixture", confirmHostFingerprint: true
    )
    _ = try await authority.updateGrant(
      deviceID: paired.credential.grant.deviceID, capabilities: CapabilitySet(capabilities),
      visibleScopes: [ResourceScope(projectID: identity.projectID)]
    )
    let connection = try await client.reconnect(
      to: authority.presentation(), using: authority,
      resourceScope: exactConnectionScope ? identity.sessionScope : nil
    )
    let epoch = try SessionEpoch(1)
    let boundary = try ClairV2AgentCommandBoundary(authority: authority, limits: limits)
    try boundary.install(snapshot: snapshot(identity), epoch: epoch, endpoint: endpoint)
    return Self(
      authority: authority, client: client, connection: connection, clock: clock,
      identity: identity, epoch: epoch, endpoint: endpoint, boundary: boundary
    )
  }

  static func snapshot(
    _ identity: ClairV2AgentSessionIdentity, generation: UInt64 = 1,
    lifecycle: ClairV2AgentLifecycleState = .running
  ) -> ClairV2AgentSessionSnapshot {
    ClairV2AgentSessionSnapshot(
      identity: identity, workingDirectoryURL: URL(fileURLWithPath: "/fixture-private-cwd"),
      lifecycle: lifecycle, processID: 123, processGeneration: generation,
      exit: nil, failure: nil, outputWasTruncated: false
    )
  }

  func command(
    _ id: String, action: ClairV2AgentCommandAction = .prompt("private prompt"),
    scope: ResourceScope? = nil, epoch: SessionEpoch? = nil, generation: UInt64 = 1,
    base: Revision? = nil, kind: OperationKind? = nil, capability: Capability? = nil
  ) throws -> ClairV2AgentCommand {
    try OperationRequest(
      operationID: OperationID(id), scope: scope ?? identity.sessionScope,
      kind: kind ?? action.kind.operationKind, baseRevision: base ?? action.approval?.revision,
      capability: capability ?? action.kind.capability,
      payload: ClairV2AgentCommandPayload(
        epoch: epoch ?? self.epoch, processGeneration: generation, action: action
      )
    )
  }

  func attention(
    revision: UInt64 = 1, request: String = "request",
    status: ClairV2AgentAttentionStatus = .pending,
    eventID: String? = nil, kind: ClairV2AgentAttentionKind = .approval
  ) throws -> ClairV2AgentNormalizedEvent {
    try event(
      .attention(
        ClairV2AgentAttentionEvent(kind: kind, requestID: h06Digest(request), status: status)
      ), revision: revision, eventID: eventID
    )
  }

  func event(
    _ payload: ClairV2AgentEventPayload, revision: UInt64, eventID: String? = nil
  ) throws -> ClairV2AgentNormalizedEvent {
    try EventEnvelope(
      eventID: EventID(eventID ?? "event-\(revision)"), kind: payload.kind.wireKind,
      scope: identity.sessionScope, epoch: epoch, revision: Revision(revision), payload: payload
    )
  }

  func pending(_ event: ClairV2AgentNormalizedEvent? = nil) throws -> ClairV2AgentApprovalReference
  {
    let event = try event ?? attention()
    try boundary.ingest(event)
    guard case .attention(let value) = event.payload, let revision = event.revision else {
      throw ClairV2AgentCommandError.invalidCommand
    }
    return try ClairV2AgentApprovalReference(
      requestID: value.requestID, eventID: event.eventID, revision: revision
    )
  }
}

private func h06Digest(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func h06Reject(
  _ expected: ClairV2AgentCommandError, _ body: () async throws -> Void
) async {
  do {
    try await body()
    Issue.record("Expected rejection: \(expected.rawValue)")
  } catch let error as ClairV2AgentCommandError {
    #expect(error == expected)
  } catch {
    Issue.record("Unexpected error type: \(type(of: error))")
  }
}

@Suite(.serialized)
struct H06CommandTests {
  @Test(arguments: ClairV2AgentCommandKind.allCases)
  func h06RoutesEachCommandWithExactlyOnceEffects(kind: ClairV2AgentCommandKind) async throws {
    for worktree in [nil, "worktree-h06"] {
      let f = try await H06Fixture.make(worktree: worktree)
      let reference = try f.pending()
      let action: ClairV2AgentCommandAction =
        switch kind {
        case .prompt: .prompt("日本語 👩🏽‍💻 prompt")
        case .approve: .approve(reference)
        case .deny: .deny(reference)
        case .interrupt: .interrupt
        case .stop: .stop
        }
      let command = try f.command("route", action: action)
      let first = try await f.boundary.execute(command, on: f.connection)
      let retry = try await f.boundary.execute(command, on: f.connection)
      #expect(first.outcome == .committed)
      #expect(first.receipt.disposition == .accepted)
      #expect(retry.receipt.disposition == .duplicate)
      #expect(first.receipt.arrivalSequence == retry.receipt.arrivalSequence)
      #expect(f.endpoint.captured.count == 1)
      let effect = try #require(f.endpoint.captured.first)
      #expect(effect.identity == f.identity)
      #expect(effect.payload.action == action)
      #expect(effect.payload.processGeneration == 1)
      #expect(effect.payload.epoch == f.epoch)
      #expect(command.capability == kind.capability)
    }
  }

  @Test
  func h06ConcurrentDuplicateAndDuplicateAuthorizationDispatchOnce() async throws {
    let f = try await H06Fixture.make()
    let command = try f.command("concurrent")
    _ = try await f.authority.authorizeForDispatch(command, on: f.connection)
    let duplicateTicket = try await f.authority.authorizeForDispatch(command, on: f.connection)
    #expect(duplicateTicket.receipt.disposition == .duplicate)
    let results = try await withThrowingTaskGroup(of: ClairV2AgentCommandResult.self) { group in
      for _ in 0..<20 {
        group.addTask { try await f.boundary.dispatch(duplicateTicket, on: f.connection) }
      }
      var results: [ClairV2AgentCommandResult] = []
      for try await result in group { results.append(result) }
      return results
    }
    #expect(results.filter { $0.receipt.disposition == .accepted }.count == 1)
    #expect(Set(results.map(\.receipt.arrivalSequence)).count == 1)
    #expect(f.endpoint.captured.count == 1)
  }

  @Test
  func h06ReconnectAndH03LedgerEvictionNeverRepeatAnEffect() async throws {
    let f = try await H06Fixture.make()
    let command = try f.command("retained")
    let first = try await f.boundary.execute(command, on: f.connection)
    // Evict the authorization receipt only, without exercising another effect.
    for index in 0...OperationLedger.defaultCapacity {
      _ = try await f.authority.authorize(f.command("authorization-\(index)"), on: f.connection)
    }
    let connection = try await f.client.reconnect(
      to: f.authority.presentation(), using: f.authority)
    let ticket = try await f.authority.authorizeForDispatch(command, on: connection)
    #expect(ticket.receipt.disposition == .accepted)
    let retry = try await f.boundary.dispatch(ticket, on: connection)
    #expect(retry.receipt.disposition == .duplicate)
    #expect(retry.receipt.arrivalSequence == first.receipt.arrivalSequence)
    #expect(f.endpoint.captured.count == 1)
  }

  @Test
  func h06ConflictingReuseInEveryBindingFieldIsRejected() async throws {
    let f = try await H06Fixture.make()
    _ = try await f.boundary.execute(f.command("conflict"), on: f.connection)
    let variants = try [
      f.command("conflict", action: .prompt("different secret")),
      f.command("conflict", action: .interrupt),
      f.command("conflict", epoch: SessionEpoch(2)),
      f.command("conflict", generation: 2),
      f.command("conflict", base: Revision(1)),
      f.command(
        "conflict",
        scope: ResourceScope(projectID: f.identity.projectID, sessionID: f.identity.sessionID)),
    ]
    for variant in variants {
      await h06Reject(.conflictingOperation) {
        _ = try await f.boundary.execute(variant, on: f.connection)
      }
    }
    #expect(f.endpoint.captured.count == 1)
  }

  @Test(arguments: [ClairV2AgentCommandOutcome.rejected, .indeterminate])
  func h06FailedOrUncertainOutcomesAreRetained(outcome: ClairV2AgentCommandOutcome) async throws {
    let f = try await H06Fixture.make(endpoint: H06Endpoint(outcome: outcome))
    let reference = try f.pending()
    let command = try f.command("uncertain", action: .approve(reference))
    let first = try await f.boundary.execute(command, on: f.connection)
    let retry = try await f.boundary.execute(command, on: f.connection)
    #expect(first.outcome == outcome)
    #expect(retry.outcome == outcome)
    #expect(retry.receipt.disposition == .duplicate)
    #expect(f.endpoint.captured.count == 1)
    if outcome == .indeterminate {
      await h06Reject(.staleApproval) {
        _ = try await f.boundary.execute(
          f.command("new-id", action: .deny(reference)), on: f.connection)
      }
      #expect(f.endpoint.captured.count == 1)
    }
  }

  @Test(arguments: ClairV2AgentCommandKind.allCases)
  func h06CapabilitiesAreAuthoritativeAndDefaultDeny(kind: ClairV2AgentCommandKind) async throws {
    let f = try await H06Fixture.make(capabilities: [.view])
    let reference = try f.pending()
    let action: ClairV2AgentCommandAction =
      switch kind {
      case .prompt: .prompt("secret")
      case .approve: .approve(reference)
      case .deny: .deny(reference)
      case .interrupt: .interrupt
      case .stop: .stop
      }
    await h06Reject(.authorizationDenied) {
      _ = try await f.boundary.execute(f.command("denied", action: action), on: f.connection)
    }
    await h06Reject(.invalidCommand) {
      _ = try await f.boundary.execute(
        f.command("spoof", action: action, capability: .view), on: f.connection)
    }
    await h06Reject(.invalidCommand) {
      _ = try await f.boundary.execute(
        f.command("unknown", action: action, kind: OperationKind("unknown.kind")), on: f.connection)
    }
    #expect(f.endpoint.captured.isEmpty)
  }

  @Test
  func h06ExactScopeAndPayloadBindingRejectWithoutEffects() async throws {
    let f = try await H06Fixture.make()
    let scopes = try [
      ResourceScope(projectID: ProjectID("other-project"), sessionID: f.identity.sessionID),
      ResourceScope(
        projectID: f.identity.projectID, worktreeID: WorktreeID("other-worktree"),
        sessionID: f.identity.sessionID),
      ResourceScope(projectID: f.identity.projectID, sessionID: f.identity.sessionID),
      ResourceScope(
        projectID: f.identity.projectID, worktreeID: f.identity.worktreeID,
        sessionID: SessionID("other-session")),
      f.identity.scope,
    ]
    let errors: [ClairV2AgentCommandError] = [
      .authorizationDenied, .scopeMismatch, .scopeMismatch, .staleSession, .invalidCommand,
    ]
    for (index, scope) in scopes.enumerated() {
      await h06Reject(errors[index]) {
        _ = try await f.boundary.execute(
          f.command("scope-\(index)", scope: scope), on: f.connection)
      }
    }
    await h06Reject(.invalidCommand) {
      _ = try await f.boundary.execute(
        f.command("mismatch", action: .stop, kind: .agentInput, capability: .steerAgent),
        on: f.connection)
    }
    let exact = try await H06Fixture.make(exactConnectionScope: true)
    await h06Reject(.authorizationDenied) {
      _ = try await exact.boundary.execute(
        exact.command("connection-scope", scope: scopes[1]), on: exact.connection)
    }
    #expect(f.endpoint.captured.isEmpty)
    #expect(exact.endpoint.captured.isEmpty)
  }

  @Test(arguments: ["close", "revoke", "generation", "expiry"])
  func h06TicketInvalidationBeforeCommitFailsClosed(reason: String) async throws {
    let f = try await H06Fixture.make()
    let command = try f.command("ticket-race")
    let ticket = try await f.authority.authorizeForDispatch(command, on: f.connection)
    switch reason {
    case "close": await f.authority.close(f.connection)
    case "revoke": _ = try await f.authority.revoke(deviceID: f.connection.deviceID)
    case "generation":
      _ = try await f.authority.updateGrant(
        deviceID: f.connection.deviceID, capabilities: .viewOnly, visibleScopes: [f.identity.scope])
    default: f.clock.advance(60)
    }
    await h06Reject(.authorizationDenied) {
      _ = try await f.boundary.dispatch(ticket, on: f.connection)
    }
    #expect(f.endpoint.captured.isEmpty)
  }

  @Test
  func h06ExpiredAuthorizationAndCachedResultsStillRequireLiveAuthority() async throws {
    let f = try await H06Fixture.make()
    f.clock.advance(59)
    let command = try f.command("expiry")
    _ = try await f.boundary.execute(command, on: f.connection)
    f.clock.advance(1)
    await h06Reject(.authorizationDenied) {
      _ = try await f.boundary.execute(command, on: f.connection)
    }
    #expect(f.endpoint.captured.count == 1)
  }

  @Test
  func h06ForgedConnectionAndTicketSubstitutionCannotCommit() async throws {
    let f = try await H06Fixture.make()
    let command = try f.command("connection")
    let ticket = try await f.authority.authorizeForDispatch(command, on: f.connection)
    let forged = ClairAuthenticatedConnection(info: f.connection.info)
    await h06Reject(.authorizationDenied) {
      _ = try await f.boundary.dispatch(ticket, on: forged)
    }
    let newConnection = try await f.client.reconnect(
      to: f.authority.presentation(), using: f.authority)
    await h06Reject(.authorizationDenied) {
      _ = try await f.boundary.dispatch(ticket, on: newConnection)
    }
    #expect(f.endpoint.captured.isEmpty)
  }

  @Test(arguments: ["close", "revoke", "generation"])
  func h06CommitLinearizesBeforeQueuedInvalidation(reason: String) async throws {
    let entered = AsyncStream<Void>.makeStream()
    let queued = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let endpoint = H06Endpoint {
      entered.continuation.yield(())
      // A test-only pause inside the synchronous effect proves the absence of
      // a reentrant authority gap. The deadline is solely a deadlock guard.
      #expect(release.wait(timeout: .now() + 10) == .success)
    }
    let f = try await H06Fixture.make(endpoint: endpoint)
    let task = Task { try await f.boundary.execute(f.command("linearized"), on: f.connection) }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    let invalidation = Task {
      queued.continuation.yield(())
      switch reason {
      case "close": await f.authority.close(f.connection)
      case "revoke": _ = try await f.authority.revoke(deviceID: f.connection.deviceID)
      default:
        _ = try await f.authority.updateGrant(
          deviceID: f.connection.deviceID, capabilities: .viewOnly,
          visibleScopes: [f.identity.scope])
      }
    }
    var queueIterator = queued.stream.makeAsyncIterator()
    _ = await queueIterator.next()
    release.signal()
    #expect(try await task.value.outcome == .committed)
    try await invalidation.value
    await h06Reject(.authorizationDenied) {
      _ = try await f.boundary.execute(f.command("after-invalidation"), on: f.connection)
    }
    #expect(endpoint.captured.count == 1)
  }

  @Test
  func h06StaleApprovalBindingsAreRejected() async throws {
    let f = try await H06Fixture.make()
    let reference = try f.pending()
    let wrongReferences = try [
      ClairV2AgentApprovalReference(
        requestID: h06Digest("other"), eventID: reference.eventID, revision: reference.revision),
      ClairV2AgentApprovalReference(
        requestID: reference.requestID, eventID: EventID("other"), revision: reference.revision),
      ClairV2AgentApprovalReference(
        requestID: reference.requestID, eventID: reference.eventID, revision: Revision(2)),
    ]
    for (index, reference) in wrongReferences.enumerated() {
      await h06Reject(.staleApproval) {
        _ = try await f.boundary.execute(
          f.command("stale-\(index)", action: .approve(reference)), on: f.connection)
      }
    }
    await h06Reject(.staleApproval) {
      _ = try await f.boundary.execute(
        f.command("base", action: .approve(reference), base: Revision(2)), on: f.connection)
    }
    await h06Reject(.staleSession) {
      _ = try await f.boundary.execute(
        f.command("epoch", action: .approve(reference), epoch: SessionEpoch(2)), on: f.connection)
    }
    #expect(f.endpoint.captured.isEmpty)
  }

  @Test(arguments: ["replacement", "resolved", "completion", "interrupt", "stop", "unknown"])
  func h06ApprovalInvalidationNeverReopensOldRequest(reason: String) async throws {
    let f = try await H06Fixture.make()
    let initialEvent = try f.attention()
    let reference = try f.pending(initialEvent)
    switch reason {
    case "replacement": _ = try f.pending(f.attention(revision: 2))
    case "resolved": try f.boundary.ingest(f.attention(revision: 2, status: .resolved))
    case "unknown": try f.boundary.ingest(f.attention(revision: 2, status: .unknown))
    case "completion":
      try f.boundary.ingest(f.event(.completion(.init(status: .succeeded)), revision: 2))
    case "interrupt":
      _ = try await f.boundary.execute(f.command("interrupt", action: .interrupt), on: f.connection)
    default: _ = try await f.boundary.execute(f.command("stop", action: .stop), on: f.connection)
    }
    if reason != "stop" { try f.boundary.ingest(initialEvent) }
    let before = f.endpoint.captured.count
    await h06Reject(reason == "stop" ? .staleSession : .staleApproval) {
      _ = try await f.boundary.execute(
        f.command("old-answer", action: .approve(reference)), on: f.connection)
    }
    #expect(f.endpoint.captured.count == before)
  }

  @Test
  func h06ConcurrentApprovalAndDenyHaveOneWinner() async throws {
    let f = try await H06Fixture.make()
    let reference = try f.pending()
    let commands = try [
      f.command("yes", action: .approve(reference)), f.command("no", action: .deny(reference)),
    ]
    let outcomes = await withTaskGroup(of: Bool.self) { group in
      for command in commands {
        group.addTask {
          do {
            _ = try await f.boundary.execute(command, on: f.connection)
            return true
          } catch {
            #expect(error as? ClairV2AgentCommandError == .staleApproval)
            return false
          }
        }
      }
      var results: [Bool] = []
      for await result in group { results.append(result) }
      return results
    }
    #expect(outcomes.filter { $0 }.count == 1)
    #expect(f.endpoint.captured.count == 1)
  }

  @Test
  func h06H05NormalizerSeparatesRequestedAndResolvedAttention() async throws {
    let f = try await H06Fixture.make()
    let events = try ClairV2OpenCodeStreamNormalizer.normalize(
      stdout: Data(
        (#"{"type":"permission.asked","event_id":"ask","permission_id":"private-provider-request"}"#
          + "\n"
          + #"{"type":"permission.replied","event_id":"reply","permission_id":"private-provider-request"}"#
          + "\n").utf8),
      identity: f.identity, epoch: f.epoch
    )
    #expect(events.count == 2)
    let reference = try f.pending(events[0])
    try f.boundary.ingest(events[1])
    await h06Reject(.staleApproval) {
      _ = try await f.boundary.execute(
        f.command("reply", action: .deny(reference)), on: f.connection)
    }
    let oldWire = Data(#"{"kind":"approval","request_id":"ignored"}"#.utf8)
    #expect(
      try JSONDecoder().decode(ClairV2AgentAttentionEvent.self, from: oldWire).status == .unknown)
    #expect(f.endpoint.captured.isEmpty)
  }

  @Test
  func h06UncorrelatedResolutionInvalidatesPendingApprovalWindow() async throws {
    let f = try await H06Fixture.make()
    let asked = try f.pending()
    var normalizer = ClairV2OpenCodeStreamNormalizer(
      identity: f.identity,
      epoch: f.epoch,
      startingRevision: Revision(1)
    )
    let response = try normalizer.append(
      Data((#"{"type":"permission.replied","event_id":"reply-without-id"}"# + "\n").utf8)
    )
    #expect(response.count == 1)
    try f.boundary.ingest(response[0])
    await h06Reject(.staleApproval) {
      _ = try await f.boundary.execute(
        f.command("uncorrelated-answer", action: .approve(asked)), on: f.connection)
    }
    #expect(f.endpoint.captured.isEmpty)
  }

  @Test
  func h06AttentionKindReplacementInvalidatesApproval() async throws {
    let f = try await H06Fixture.make()
    let reference = try f.pending()
    try f.boundary.ingest(f.attention(revision: 2, kind: .question))
    await h06Reject(.staleApproval) {
      _ = try await f.boundary.execute(
        f.command("kind-replacement", action: .approve(reference)), on: f.connection)
    }
    #expect(f.endpoint.captured.isEmpty)
  }

  @Test
  func h06LifecycleAndGenerationRacesFenceOldTickets() async throws {
    let f = try await H06Fixture.make()
    let reference = try f.pending()
    let ticket = try await f.authority.authorizeForDispatch(
      f.command("old", action: .approve(reference)), on: f.connection)
    f.boundary.invalidate(identity: f.identity, processGeneration: 1)
    await h06Reject(.staleSession) { _ = try await f.boundary.dispatch(ticket, on: f.connection) }
    let replacement = H06Endpoint()
    try f.boundary.install(
      snapshot: H06Fixture.snapshot(f.identity, generation: 2), epoch: SessionEpoch(2),
      endpoint: replacement)
    // A late H04 termination callback must not disable the new attachment.
    f.boundary.invalidate(identity: f.identity, processGeneration: 1)
    await h06Reject(.staleSession) { _ = try await f.boundary.dispatch(ticket, on: f.connection) }
    _ = try await f.boundary.execute(
      f.command("new", epoch: SessionEpoch(2), generation: 2), on: f.connection)
    #expect(f.endpoint.captured.isEmpty)
    #expect(replacement.captured.count == 1)
    #expect(throws: ClairV2AgentCommandError.staleSession) {
      try f.boundary.install(
        snapshot: H06Fixture.snapshot(f.identity), epoch: SessionEpoch(3), endpoint: f.endpoint)
    }
  }

  @Test(arguments: ["gap", "conflict", "kind", "bad-request"])
  func h06InvalidStreamFencesEffects(reason: String) async throws {
    let f = try await H06Fixture.make()
    let reference = try f.pending()
    let event: ClairV2AgentNormalizedEvent
    switch reason {
    case "gap": event = try f.attention(revision: 3)
    case "conflict": event = try f.attention(revision: 2, eventID: "event-1")
    case "bad-request":
      event = try f.event(
        .attention(.init(kind: .approval, requestID: "raw provider secret", status: .pending)),
        revision: 2)
    default:
      event = try EventEnvelope(
        eventID: EventID("kind"), kind: .attention, scope: f.identity.sessionScope,
        epoch: f.epoch, revision: Revision(2),
        payload: ClairV2AgentEventPayload.completion(.init(status: .failed)))
    }
    #expect(throws: (any Error).self) { try f.boundary.ingest(event) }
    await h06Reject(.staleSession) {
      _ = try await f.boundary.execute(
        f.command("fenced", action: .approve(reference)), on: f.connection)
    }
    #expect(f.endpoint.captured.isEmpty)
  }

  @Test
  func h06StaleAndWrongScopeEventsDoNotPoisonCurrentAttachment() async throws {
    let f = try await H06Fixture.make()
    let reference = try f.pending()
    for scope in [
      try ResourceScope(projectID: ProjectID("wrong"), sessionID: f.identity.sessionID),
      f.identity.sessionScope,
    ] {
      let event = try EventEnvelope(
        eventID: EventID("stale"), kind: EventKind("agent.attention"), scope: scope,
        epoch: SessionEpoch(99), revision: Revision(2),
        payload: ClairV2AgentEventPayload.attention(
          .init(kind: .approval, requestID: reference.requestID, status: .resolved))
      )
      #expect(throws: ClairV2AgentCommandError.invalidEventStream) { try f.boundary.ingest(event) }
    }
    _ = try await f.boundary.execute(
      f.command("still-pending", action: .approve(reference)), on: f.connection)
    #expect(f.endpoint.captured.count == 1)
  }

  @Test
  func h06BoundsKeepOperationsAndAuditFiniteWithoutReexecution() async throws {
    let f = try await H06Fixture.make(
      limits: ClairV2AgentCommandLimits(maximumOperations: 2, maximumAuditEntries: 3))
    let first = try f.command("first")
    _ = try await f.boundary.execute(first, on: f.connection)
    _ = try await f.boundary.execute(f.command("second"), on: f.connection)
    for index in 0..<6 {
      await h06Reject(.operationCapacity) {
        _ = try await f.boundary.execute(f.command("overflow-\(index)"), on: f.connection)
      }
    }
    let retry = try await f.boundary.execute(first, on: f.connection)
    #expect(retry.receipt.disposition == .duplicate)
    #expect(f.endpoint.captured.count == 2)
    #expect(f.boundary.auditSnapshot().count == 3)
  }

  @Test
  func h06PendingAndSessionLimitsFailClosed() async throws {
    let f = try await H06Fixture.make(
      limits: ClairV2AgentCommandLimits(maximumSessions: 1, maximumPendingApprovals: 1))
    _ = try f.pending()
    #expect(throws: ClairV2AgentCommandError.approvalCapacity) {
      try f.boundary.ingest(f.attention(revision: 2, request: "another"))
    }
    let another = try ClairV2AgentSessionIdentity(
      provider: f.identity.provider, projectID: f.identity.projectID, sessionID: SessionID("second")
    )
    #expect(throws: ClairV2AgentCommandError.sessionCapacity) {
      try f.boundary.install(
        snapshot: H06Fixture.snapshot(another), epoch: f.epoch, endpoint: f.endpoint)
    }
    await h06Reject(.staleSession) {
      _ = try await f.boundary.execute(f.command("fenced"), on: f.connection)
    }
    #expect(f.endpoint.captured.isEmpty)
    #expect(throws: ClairV2AgentCommandError.invalidLimits) {
      _ = try ClairV2AgentCommandLimits(maximumOperations: 0)
    }
    #expect(throws: ClairV2AgentCommandError.invalidLimits) {
      _ = try ClairV2AgentCommandLimits(maximumAuditEntries: 4097)
    }
  }

  @Test
  func h06PromptAndWireBoundsRejectBeforeAnyEffect() async throws {
    let f = try await H06Fixture.make()
    let maximum = String(repeating: "é", count: ClairV2AgentCommandAction.maximumPromptBytes / 2)
    _ = try await f.boundary.execute(f.command("max", action: .prompt(maximum)), on: f.connection)
    for invalid in [maximum + "é", " \n", "nul\0byte"] {
      #expect(throws: ClairV2AgentCommandError.invalidCommand) {
        _ = try f.command("invalid", action: .prompt(invalid))
      }
      let wire = try JSONSerialization.data(withJSONObject: ["kind": "prompt", "prompt": invalid])
      #expect(throws: ClairV2AgentCommandError.invalidCommand) {
        _ = try JSONDecoder().decode(ClairV2AgentCommandAction.self, from: wire)
      }
    }
    #expect(throws: ClairV2AgentCommandError.invalidCommand) {
      _ = try JSONDecoder().decode(
        ClairV2AgentCommandAction.self, from: Data(#"{"kind":"stop","prompt":"secret"}"#.utf8))
    }
    #expect(throws: ClairV2AgentCommandError.invalidCommand) {
      _ = try ClairV2AgentCommandPayload(epoch: f.epoch, processGeneration: 0, action: .stop)
    }
    #expect(throws: ClairV2AgentCommandError.invalidCommand) {
      _ = try ClairV2AgentApprovalReference(
        requestID: "raw-provider-secret", eventID: EventID("event"), revision: Revision(1))
    }
    let command = try f.command("roundtrip")
    let wire = try ClairNativeTransportCodec.encodeFrame(command)
    let decoded = try ClairNativeTransportCodec.decodeFrame(ClairV2AgentCommand.self, from: wire)
    #expect(decoded.payload == command.payload)
    #expect(f.endpoint.captured.count == 1)
  }

  @Test
  func h06AuditAndLedgerDoNotRetainPromptCredentialProviderOrRawIDs() async throws {
    let secret = "private-prompt-token-provider-payload"
    let f = try await H06Fixture.make(project: secret)
    let command = try f.command(secret, action: .prompt(secret))
    _ = try await f.boundary.execute(command, on: f.connection)
    let ticket = try await f.authority.authorizeForDispatch(command, on: f.connection)
    let audit = f.boundary.auditSnapshot()
    let encoded = try ProtocolCodec.encode(audit)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains(secret))
    #expect(!text.contains("opencode"))
    #expect(!text.contains("fixture-private-cwd"))
    #expect(audit[0].operationDigest.utf8.count == 64)
    #expect(audit[0].scopeDigest.utf8.count == 64)
    #expect(encoded.count < 1024)
    #expect(!String(describing: command.payload).contains(secret))
    #expect(!String(describing: command.payload.action).contains(secret))
    #expect(!String(describing: command).contains(secret))
    #expect(!String(reflecting: command).contains(secret))
    #expect(!String(describing: f.endpoint.captured[0]).contains(secret))
    #expect(!String(describing: ticket.operation.payload).contains(secret))
    var ledger = try OperationLedger()
    _ = try ledger.register(command)
    // B03 ledger storage is private; reflection verifies no canonical prompt
    // bytes are retained, without adding a production introspection endpoint.
    let children = Mirror(reflecting: ledger).children
    let values = try #require(
      children.first { $0.label == "fingerprints" }?.value as? [OperationID: Data])
    #expect(values[command.operationID]?.count == 32)
    #expect(
      !String(decoding: values[command.operationID] ?? Data(), as: UTF8.self).contains(secret))
  }
}

import CryptoKit
import Foundation
import Testing

@testable import ClairAgent
@testable import ClairDaemonKit
@testable import ClairMobileKit
@testable import ClairShared
@testable import ClairTransport

// MARK: - Shared fixtures

private func n05Digest(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// A trivial async gate used to hold a mock transport call open until the
/// test explicitly releases it, so two concurrent controller calls can be
/// proven to genuinely overlap.
private actor N05Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

/// A plain synchronous, lock-guarded flag. `ClairMobileConversationController
/// .setDispatchObserverForTesting` fires its callback synchronously from
/// inside actor-isolated code, so the observer cannot itself `await`; this
/// gives it something safe to flip instead.
private final class N05Signal: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false

  func set() { lock.withLock { flag = true } }
  func isSet() -> Bool { lock.withLock { flag } }
}

/// Polls (bounded, matching the codebase's existing race-test idiom in
/// `ClairMobileClientTests`) until `signal` is set, proving the duplicate
/// call genuinely reached the in-flight join point rather than racing real
/// scheduler timing with a fixed sleep.
private func n05WaitForJoin(_ signal: N05Signal) async {
  for _ in 0..<500 {
    if signal.isSet() { return }
    try? await Task.sleep(for: .milliseconds(1))
  }
}

/// A minimal `ClairMobileAgentTransport` double that counts dispatch calls
/// and can be held open by a gate. It never touches H03/H06 authorization, so
/// it isolates the controller's own in-flight de-duplication from the host's
/// exactly-once ledger.
private actor N05MockTransport: ClairMobileAgentTransport {
  private(set) var callCount = 0
  private(set) var capturedActions: [ClairAgentCommandAction] = []
  private let releaseGate: N05Gate?
  /// Opened the moment a dispatch call actually begins, so a test can prove
  /// two calls genuinely overlapped instead of racing to fire a second tap
  /// after the first has already finished.
  private let startedGate: N05Gate?
  var outcome: ClairAgentCommandOutcome
  var errorToThrow: ClairAgentCommandError?

  init(
    releaseGate: N05Gate? = nil,
    startedGate: N05Gate? = nil,
    outcome: ClairAgentCommandOutcome = .committed,
    errorToThrow: ClairAgentCommandError? = nil
  ) {
    self.releaseGate = releaseGate
    self.startedGate = startedGate
    self.outcome = outcome
    self.errorToThrow = errorToThrow
  }

  func dispatch(
    _ command: ClairAgentCommand,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairAgentCommandOutcome {
    callCount += 1
    capturedActions.append(command.payload.action)
    await startedGate?.open()
    await releaseGate?.wait()
    if let errorToThrow { throw errorToThrow }
    return outcome
  }
}

private final class N05Endpoint: ClairAgentCommandEndpoint, @unchecked Sendable {
  private let lock = NSLock()
  private var effects: [ClairAgentCommandEffect] = []
  let outcome: ClairAgentCommandOutcome

  init(outcome: ClairAgentCommandOutcome = .committed) {
    self.outcome = outcome
  }

  func commit(_ effect: ClairAgentCommandEffect) -> ClairAgentCommandOutcome {
    lock.withLock { effects.append(effect) }
    return outcome
  }

  var captured: [ClairAgentCommandEffect] { lock.withLock { effects } }
}

/// Bridges the mobile-facing `ClairMobileAgentTransport` seam directly to
/// the real H06 `ClairAgentCommandBoundary`, so N05's own tests can prove
/// genuine end-to-end behavior (authorization, exactly-once ledger, stale
/// approval fail-closing) rather than only exercising N05's own assumptions.
private struct N05BoundaryTransport: ClairMobileAgentTransport {
  let boundary: ClairAgentCommandBoundary

  func dispatch(
    _ command: ClairAgentCommand,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairAgentCommandOutcome {
    try await boundary.execute(command, on: connection).outcome
  }
}

private struct N05Fixture: Sendable {
  let authority: ClairPairingAuthority
  let connection: ClairAuthenticatedConnection
  let identity: ClairAgentSessionIdentity
  let epoch: SessionEpoch
  let endpoint: N05Endpoint
  let boundary: ClairAgentCommandBoundary

  static func make(
    endpoint: N05Endpoint = N05Endpoint(),
    capabilities: [Capability] = [.view, .steerAgent, .approve, .signal, .terminate]
  ) async throws -> Self {
    let identity = try ClairAgentSessionIdentity(
      provider: ClairProviderIdentity(
        providerID: .openCode, version: ClairProviderVersion("n05")),
      projectID: ProjectID("project-n05"), worktreeID: nil,
      sessionID: SessionID("session-n05")
    )
    let authority = try ClairPairingAuthority(
      hostID: ClairHostID("host-n05"),
      endpoint: ClairTransportEndpoint("wss://n05.example.test"),
      defaultVisibleScopes: [identity.scope]
    )
    let client = ClairNativeClientTransport(deviceKey: ClairDeviceKey())
    let link = try await authority.issuePairingLink(lifetime: 60)
    let paired = try await client.pair(
      using: link, with: authority, displayName: "N05 fixture", confirmHostFingerprint: true
    )
    _ = try await authority.updateGrant(
      deviceID: paired.credential.grant.deviceID,
      capabilities: CapabilitySet(capabilities),
      visibleScopes: [ResourceScope(projectID: identity.projectID)]
    )
    let connection = try await client.reconnect(to: authority.presentation(), using: authority)
    let epoch = try SessionEpoch(1)
    let boundary = try ClairAgentCommandBoundary(authority: authority)
    try boundary.install(snapshot: snapshot(identity), epoch: epoch, endpoint: endpoint)
    return Self(
      authority: authority, connection: connection, identity: identity, epoch: epoch,
      endpoint: endpoint, boundary: boundary
    )
  }

  static func snapshot(
    _ identity: ClairAgentSessionIdentity, generation: UInt64 = 1
  ) -> ClairAgentSessionSnapshot {
    ClairAgentSessionSnapshot(
      identity: identity, workingDirectoryURL: URL(fileURLWithPath: "/fixture-private-cwd"),
      lifecycle: .running, processID: 123, processGeneration: generation,
      exit: nil, failure: nil, outputWasTruncated: false
    )
  }

  var boundaryTransport: N05BoundaryTransport { N05BoundaryTransport(boundary: boundary) }

  func attachment(processGeneration: UInt64 = 1) throws
    -> ClairMobileConversationController
    .Attachment
  {
    try .init(
      identity: identity, epoch: epoch, processGeneration: processGeneration,
      connection: connection
    )
  }

  func event(
    _ payload: ClairAgentEventPayload, revision: UInt64, eventID: String? = nil
  ) throws -> ClairAgentNormalizedEvent {
    try EventEnvelope(
      eventID: EventID(eventID ?? "event-\(revision)"), kind: payload.kind.wireKind,
      scope: identity.sessionScope, epoch: epoch, revision: Revision(revision), payload: payload
    )
  }

  func attentionEvent(
    revision: UInt64, request: String = "request",
    status: ClairAgentAttentionStatus = .pending, eventID: String? = nil
  ) throws -> ClairAgentNormalizedEvent {
    try event(
      .attention(
        ClairAgentAttentionEvent(kind: .approval, requestID: n05Digest(request), status: status)
      ), revision: revision, eventID: eventID
    )
  }

  func conversationEvent(
    revision: UInt64, text: String = "hello", isDelta: Bool = true
  ) throws -> ClairAgentNormalizedEvent {
    try event(
      .conversation(ClairAgentConversationEvent(role: .assistant, text: text, isDelta: isDelta)),
      revision: revision
    )
  }
}

// MARK: - Duplicate / rapid-repeat tap safety

@Suite(.serialized)
struct N05DuplicateTapTests {
  @Test
  func duplicatePromptTapsJoinTheSameInFlightCommandInsteadOfDoubleDispatching() async throws {
    let f = try await N05Fixture.make()
    let started = N05Gate()
    let release = N05Gate()
    let joined = N05Signal()
    let transport = N05MockTransport(releaseGate: release, startedGate: started)
    let controller = ClairMobileConversationController(transport: transport)
    await controller.attach(try f.attachment())
    await controller.setDispatchObserverForTesting { key, didJoin in
      if key == "prompt", didJoin { joined.set() }
    }

    async let first = controller.submitPrompt("hello there")
    // Only fire the duplicate/rapid-repeat tap once the first dispatch has
    // genuinely begun (and is blocked in the transport), proving real
    // overlap instead of racing a second call in after the first already
    // finished. Releasing only after the observer confirms the second call
    // actually joined the in-flight command (rather than a fixed sleep)
    // keeps this deterministic.
    await started.wait()
    async let second = controller.submitPrompt("hello there")
    await n05WaitForJoin(joined)
    await release.open()

    let (firstOutcome, secondOutcome) = try await (first, second)
    #expect(firstOutcome == .committed)
    #expect(secondOutcome == .committed)
    #expect(await transport.callCount == 1)
    #expect(joined.isSet())
  }

  @Test
  func duplicateApproveTapsJoinTheSameInFlightCommand() async throws {
    let f = try await N05Fixture.make()
    let started = N05Gate()
    let release = N05Gate()
    let joined = N05Signal()
    let transport = N05MockTransport(releaseGate: release, startedGate: started)
    let controller = ClairMobileConversationController(transport: transport)
    await controller.attach(try f.attachment())
    let key = "approve:\(n05Digest("request"))"
    await controller.setDispatchObserverForTesting { dispatchKey, didJoin in
      if dispatchKey == key, didJoin { joined.set() }
    }
    let pending = try f.attentionEvent(revision: 1)
    #expect(await controller.ingest(pending))

    async let first = controller.approve(requestID: n05Digest("request"))
    await started.wait()
    async let second = controller.approve(requestID: n05Digest("request"))
    await n05WaitForJoin(joined)
    await release.open()

    let (firstOutcome, secondOutcome) = try await (first, second)
    #expect(firstOutcome == .committed)
    #expect(secondOutcome == .committed)
    #expect(await transport.callCount == 1)
    #expect(joined.isSet())
    let pendingAfter = await controller.state.pendingApprovals
    #expect(pendingAfter.isEmpty)
  }

  @Test
  func duplicateDenyTapsJoinTheSameInFlightCommand() async throws {
    let f = try await N05Fixture.make()
    let started = N05Gate()
    let release = N05Gate()
    let joined = N05Signal()
    let transport = N05MockTransport(releaseGate: release, startedGate: started)
    let controller = ClairMobileConversationController(transport: transport)
    await controller.attach(try f.attachment())
    let key = "deny:\(n05Digest("request"))"
    await controller.setDispatchObserverForTesting { dispatchKey, didJoin in
      if dispatchKey == key, didJoin { joined.set() }
    }
    let pending = try f.attentionEvent(revision: 1)
    #expect(await controller.ingest(pending))

    async let first = controller.deny(requestID: n05Digest("request"))
    await started.wait()
    async let second = controller.deny(requestID: n05Digest("request"))
    await n05WaitForJoin(joined)
    await release.open()

    _ = try await (first, second)
    #expect(await transport.callCount == 1)
    #expect(joined.isSet())
  }

  @Test
  func duplicateInterruptTapsJoinTheSameInFlightCommand() async throws {
    let f = try await N05Fixture.make()
    let started = N05Gate()
    let release = N05Gate()
    let joined = N05Signal()
    let transport = N05MockTransport(releaseGate: release, startedGate: started)
    let controller = ClairMobileConversationController(transport: transport)
    await controller.attach(try f.attachment())
    await controller.setDispatchObserverForTesting { key, didJoin in
      if key == "interrupt", didJoin { joined.set() }
    }

    async let first = controller.interrupt()
    await started.wait()
    async let second = controller.interrupt()
    await n05WaitForJoin(joined)
    await release.open()

    _ = try await (first, second)
    #expect(await transport.callCount == 1)
    #expect(joined.isSet())
  }

  @Test
  func duplicateStopTapsJoinTheSameInFlightCommand() async throws {
    let f = try await N05Fixture.make()
    let started = N05Gate()
    let release = N05Gate()
    let joined = N05Signal()
    let transport = N05MockTransport(releaseGate: release, startedGate: started)
    let controller = ClairMobileConversationController(transport: transport)
    await controller.attach(try f.attachment())
    await controller.setDispatchObserverForTesting { key, didJoin in
      if key == "stop", didJoin { joined.set() }
    }

    async let first = controller.stop()
    await started.wait()
    async let second = controller.stop()
    await n05WaitForJoin(joined)
    await release.open()

    _ = try await (first, second)
    #expect(await transport.callCount == 1)
    #expect(joined.isSet())
  }

  @Test
  func sequentialPromptsAfterCompletionAreNotCoalesced() async throws {
    let f = try await N05Fixture.make()
    let transport = N05MockTransport()
    let controller = ClairMobileConversationController(transport: transport)
    await controller.attach(try f.attachment())

    _ = try await controller.submitPrompt("first message")
    _ = try await controller.submitPrompt("second message")

    #expect(await transport.callCount == 2)
    let actions = await transport.capturedActions
    #expect(actions == [.prompt("first message"), .prompt("second message")])
  }

  @Test
  func duplicateTapThroughTheRealH06BoundaryStillCommitsExactlyOnce() async throws {
    let f = try await N05Fixture.make()
    let controller = ClairMobileConversationController(transport: f.boundaryTransport)
    await controller.attach(try f.attachment())
    let pending = try f.attentionEvent(revision: 1)
    try f.boundary.ingest(pending)
    #expect(await controller.ingest(pending))

    async let first = controller.approve(requestID: n05Digest("request"))
    async let second = controller.approve(requestID: n05Digest("request"))
    let (firstOutcome, secondOutcome) = try await (first, second)

    #expect(firstOutcome == .committed)
    #expect(secondOutcome == .committed)
    #expect(f.endpoint.captured.count == 1)
  }
}

// MARK: - Background delivery and foreground resume

@Suite
struct N05BackgroundDeliveryTests {
  @Test
  func eventsFoldedWhileBackgroundedAreFullyVisibleOnForegroundResume() async throws {
    let f = try await N05Fixture.make()
    let controller = ClairMobileConversationController(transport: N05MockTransport())
    await controller.attach(try f.attachment())

    // Simulate a burst of streamed deltas arriving while the scene is
    // backgrounded: `ingest` never checks lifecycle, so this is exactly the
    // same code path as foreground delivery.
    for revision in 1...20 {
      let event = try f.conversationEvent(revision: UInt64(revision), text: "chunk \(revision)")
      #expect(await controller.ingest(event))
    }

    // "Resume on foreground" is just reading the already-folded state.
    let state = await controller.state
    #expect(state.messages.count == 20)
    #expect(state.messages.last?.text == "chunk 20")
    #expect(state.lastRevision == Revision(20))
  }

  @Test
  func duplicateOrOutOfOrderEventsDuringBackgroundDeliveryDoNotCorruptState() async throws {
    let f = try await N05Fixture.make()
    let controller = ClairMobileConversationController(transport: N05MockTransport())
    await controller.attach(try f.attachment())

    for revision in 1...5 {
      let event = try f.conversationEvent(revision: UInt64(revision), text: "chunk \(revision)")
      #expect(await controller.ingest(event))
    }
    // A network hiccup while backgrounded redelivers an old revision.
    let replay = try f.conversationEvent(revision: 3, text: "replayed")
    #expect(await controller.ingest(replay) == false)

    let state = await controller.state
    #expect(state.messages.count == 5)
    #expect(state.messages.map(\.text) == ["chunk 1", "chunk 2", "chunk 3", "chunk 4", "chunk 5"])
    #expect(state.lastRevision == Revision(5))
  }

  @Test
  func aNewProcessGenerationObservedWhileBackgroundedResetsTheTranscriptCleanly() async throws {
    let f = try await N05Fixture.make()
    let controller = ClairMobileConversationController(transport: N05MockTransport())
    await controller.attach(try f.attachment())

    let firstGenerationEvent = try f.conversationEvent(revision: 1, text: "before restart")
    #expect(await controller.ingest(firstGenerationEvent))

    let newEpoch = try SessionEpoch(2)
    let restarted = try EventEnvelope(
      eventID: EventID("event-restart"), kind: EventKind("agent.conversation"),
      scope: f.identity.sessionScope, epoch: newEpoch, revision: Revision(1),
      payload: ClairAgentEventPayload.conversation(
        ClairAgentConversationEvent(role: .assistant, text: "after restart")
      )
    )
    #expect(await controller.ingest(restarted))

    let state = await controller.state
    #expect(state.epoch == newEpoch)
    #expect(state.messages.count == 1)
    #expect(state.messages.first?.text == "after restart")
  }
}

// MARK: - Stale approval safety

@Suite
struct N05StaleApprovalTests {
  @Test
  func approvingARequestNoLongerPendingLocallyIsRejectedWithoutCallingTransport() async throws {
    let f = try await N05Fixture.make()
    let transport = N05MockTransport()
    let controller = ClairMobileConversationController(transport: transport)
    await controller.attach(try f.attachment())

    let pending = try f.attentionEvent(revision: 1)
    #expect(await controller.ingest(pending))
    let resolved = try f.attentionEvent(revision: 2, status: .resolved)
    #expect(await controller.ingest(resolved))

    await #expect(throws: ClairMobileConversationError.staleApproval) {
      try await controller.approve(requestID: n05Digest("request"))
    }
    #expect(await transport.callCount == 0)
  }

  @Test
  func anUnknownRequestIDIsRejectedWithoutCallingTransport() async throws {
    let f = try await N05Fixture.make()
    let transport = N05MockTransport()
    let controller = ClairMobileConversationController(transport: transport)
    await controller.attach(try f.attachment())

    await #expect(throws: ClairMobileConversationError.staleApproval) {
      try await controller.deny(requestID: n05Digest("never-seen"))
    }
    #expect(await transport.callCount == 0)
  }

  @Test
  func aResolutionRacingAheadOfTheClientSelfHealsAfterTheHostRejectsTheStaleApproval()
    async throws
  {
    let f = try await N05Fixture.make()
    let controller = ClairMobileConversationController(transport: f.boundaryTransport)
    await controller.attach(try f.attachment())

    let pending = try f.attentionEvent(revision: 1)
    // Both the real host boundary and the client's own local mirror learn
    // about the pending approval.
    try f.boundary.ingest(pending)
    #expect(await controller.ingest(pending))

    // The host resolves it (e.g. the terminal answered it directly) before
    // the resolution event has reached this client -- exactly the "attention
    // already moved on" race the task text calls out.
    let resolved = try f.attentionEvent(revision: 2, status: .resolved)
    try f.boundary.ingest(resolved)

    // The client still believes the approval is locally pending and attempts
    // it; the real H06 boundary must fail it closed.
    #expect(
      await controller.state.pendingApprovals.contains { $0.requestID == n05Digest("request") })
    await #expect(throws: ClairMobileConversationError.staleApproval) {
      try await controller.approve(requestID: n05Digest("request"))
    }

    // The controller self-heals its local mirror instead of leaving a dead
    // approval executable in the UI.
    let pendingAfter = await controller.state.pendingApprovals
    #expect(pendingAfter.isEmpty)
    #expect(f.endpoint.captured.isEmpty)
  }

  @Test
  func anUncorrelatedResolutionInvalidatesTheWholeLocalPendingWindow() async throws {
    let f = try await N05Fixture.make()
    let controller = ClairMobileConversationController(transport: N05MockTransport())
    await controller.attach(try f.attachment())

    let firstPending = try f.attentionEvent(revision: 1, request: "first")
    let secondPending = try f.attentionEvent(revision: 2, request: "second")
    #expect(await controller.ingest(firstPending))
    #expect(await controller.ingest(secondPending))
    #expect(await controller.state.pendingApprovals.count == 2)

    // An uncorrelated resolved attention (no request ID the client can
    // match) cannot safely identify which request it answers.
    let uncorrelated = try f.event(
      .attention(ClairAgentAttentionEvent(kind: .approval, requestID: nil, status: .resolved)),
      revision: 3
    )
    #expect(await controller.ingest(uncorrelated))
    #expect(await controller.state.pendingApprovals.isEmpty)

    await #expect(throws: ClairMobileConversationError.staleApproval) {
      try await controller.approve(requestID: n05Digest("first"))
    }
  }

  @Test
  func aCompletionEventClearsAllPendingApprovals() async throws {
    let f = try await N05Fixture.make()
    let controller = ClairMobileConversationController(transport: N05MockTransport())
    await controller.attach(try f.attachment())

    let pending = try f.attentionEvent(revision: 1)
    #expect(await controller.ingest(pending))
    let completion = try f.event(
      .completion(ClairAgentCompletionEvent(status: .succeeded)), revision: 2
    )
    #expect(await controller.ingest(completion))

    #expect(await controller.state.pendingApprovals.isEmpty)
    #expect(await controller.state.completion == .succeeded)
  }

  @Test
  func detachRejectsFurtherCommandsWithoutReachingTransport() async throws {
    let f = try await N05Fixture.make()
    let transport = N05MockTransport()
    let controller = ClairMobileConversationController(transport: transport)
    await controller.attach(try f.attachment())
    await controller.detach()

    await #expect(throws: ClairMobileConversationError.notAttached) {
      try await controller.submitPrompt("hello")
    }
    #expect(await transport.callCount == 0)
  }
}

// MARK: - Pure state-fold coverage

@Suite
struct N05ConversationStateTests {
  @Test
  func toolCallEventsUpdateByToolIDInsteadOfAppending() {
    var state = ClairMobileConversationState()
    let scope = try! ResourceScope(
      projectID: ProjectID("p"), sessionID: SessionID("s")
    )
    let epoch = try! SessionEpoch(1)
    func toolEvent(revision: UInt64, status: ClairAgentToolCallStatus)
      -> ClairAgentNormalizedEvent
    {
      try! EventEnvelope(
        eventID: EventID("tool-\(revision)"), kind: EventKind("agent.tool_call"),
        scope: scope, epoch: epoch, revision: Revision(revision),
        payload: .toolCall(
          ClairAgentToolCallEvent(toolID: "tool-1", name: "bash", status: status))
      )
    }
    #expect(state.apply(toolEvent(revision: 1, status: .started)) == true)
    #expect(state.apply(toolEvent(revision: 2, status: .completed)) == true)
    #expect(state.toolCalls.count == 1)
    #expect(state.toolCalls.first?.status == .completed)
  }

  @Test
  func eventsOutsideTheAttachedScopeAreIgnored() {
    var state = ClairMobileConversationState()
    let scope = try! ResourceScope(projectID: ProjectID("p"), sessionID: SessionID("s"))
    let otherScope = try! ResourceScope(projectID: ProjectID("p2"), sessionID: SessionID("s2"))
    let epoch = try! SessionEpoch(1)
    state.reset(scope: scope, epoch: epoch)
    let foreign = try! EventEnvelope(
      eventID: EventID("foreign"), kind: EventKind("agent.conversation"),
      scope: otherScope, epoch: epoch, revision: Revision(1),
      payload: ClairAgentEventPayload.conversation(
        ClairAgentConversationEvent(role: .assistant, text: "should not appear")
      )
    )
    #expect(state.apply(foreign) == false)
    #expect(state.messages.isEmpty)
  }
}

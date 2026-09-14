import CryptoKit
import Foundation
import Testing

@testable import ClairV2Agent
@testable import ClairV2DaemonKit
@testable import ClairV2Push
@testable import ClairV2Shared
@testable import ClairV2Transport
@testable import ClairV2Workspace

#if os(macOS)
  import Darwin
#endif

// H10: the P0-B integration gate. These tests exercise `ClairDaemonHost`,
// the composition root added by H10, against the *real* H01-H09 modules
// (real CryptoKit pairing, a real spawned OS process standing in for
// OpenCode, the real H06 command boundary, the real H08 journal, the real
// H09 push registry) rather than re-testing any single module in isolation.
// A `ClairV2CoreTests` fixture client is exactly the "fixture client (in-
// process or a thin process launched by the test)" the H10 worker contract
// calls for: no Mac GUI, no Xcode UI test, and no dependency on a real
// OpenCode binary or a real APNs credential.

// MARK: - Shared fixture

private final class H10Clock: ClairTransportClock, ClairPushClock, @unchecked Sendable {
  private let lock = NSLock()
  private var instant: Date
  init(_ instant: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.instant = instant }
  func now() -> Date { lock.withLock { instant } }
  func advance(by interval: TimeInterval) {
    lock.withLock { instant = instant.addingTimeInterval(interval) }
  }
}

private final class H10RelaySpy: ClairPushSending, @unchecked Sendable {
  private let lock = NSLock()
  private var storedDeliveries: [ClairPushDelivery] = []
  var result: ClairPushProviderStatus = .accepted

  func send(_ delivery: ClairPushDelivery) throws -> ClairPushDeliveryResult {
    lock.lock()
    defer { lock.unlock() }
    storedDeliveries.append(delivery)
    return ClairPushDeliveryResult(status: result)
  }

  var deliveries: [ClairPushDelivery] { lock.withLock { storedDeliveries } }
}

/// Records every committed H06 effect. Real OpenCode stdin/event wiring does
/// not exist anywhere in H01-H09 (there is no provider-text-protocol API on
/// `ClairV2AgentRuntime`/`ClairV2AgentProcess` to write a prompt to); this
/// fixture is the same "synchronous endpoint records the effect" boundary
/// H06's own test suite (`H06Endpoint`) already established as correct.
private final class H10FixtureEndpoint: ClairV2AgentCommandEndpoint, @unchecked Sendable {
  private let lock = NSLock()
  private var effects: [ClairV2AgentCommandEffect] = []
  let outcome: ClairV2AgentCommandOutcome

  init(outcome: ClairV2AgentCommandOutcome = .committed) { self.outcome = outcome }

  func commit(_ effect: ClairV2AgentCommandEffect) -> ClairV2AgentCommandOutcome {
    lock.withLock { effects.append(effect) }
    return outcome
  }

  var committedActions: [ClairV2AgentCommandAction] {
    lock.withLock { effects.map(\.payload.action) }
  }
}

/// A real, disposable Git-backed project root, mirroring the H04 fixture
/// idiom (`H04WorkspaceFixture`) so H07 diff/status has something real to
/// read.
private final class H10ProjectFixture {
  let rootURL: URL

  init() throws {
    rootURL = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("clair-v2-h10-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: rootURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    try runGit(["init", "--quiet"])
    try runGit(["config", "user.email", "clair-h10@example.invalid"])
    try runGit(["config", "user.name", "Clair H10"])
    try Data("initial\n".utf8).write(to: rootURL.appendingPathComponent("tracked.txt"))
    try runGit(["add", "tracked.txt"])
    try runGit(["commit", "--quiet", "-m", "initial"])
  }

  func remove() { try? FileManager.default.removeItem(at: rootURL) }

  func writeUncommittedChange() throws {
    try Data("initial\nsecond line\n".utf8).write(
      to: rootURL.appendingPathComponent("tracked.txt")
    )
  }

  @discardableResult
  private func runGit(_ arguments: [String]) throws -> String {
    let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
    guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
      throw H10FixtureError.commandUnavailable
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = rootURL
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let output =
      (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    guard process.terminationStatus == 0 else { throw H10FixtureError.commandFailed }
    return String(decoding: output, as: UTF8.self)
  }
}

private enum H10FixtureError: Error {
  case commandUnavailable
  case commandFailed
}

/// One fully composed daemon stack: a real `ClairPairingAuthority`, a real
/// `ClairV2AgentRuntime` spawning real (but lightweight) OS processes as a
/// stand-in for OpenCode, and the `ClairDaemonHost` under test. Building two
/// independent instances of this fixture is how the crash-recovery tests
/// simulate "the daemon restarted": everything here is in-memory (see the
/// `ClairDaemonHost` doc comment), so a fresh instance *is* a faithful model
/// of post-restart state.
private struct H10Stack {
  let project: H10ProjectFixture
  let projectID: ProjectID
  let authority: ClairPairingAuthority
  let agentRuntime: ClairV2AgentRuntime
  let relay: H10RelaySpy
  let host: ClairDaemonHost
  let clock: H10Clock

  static func make(
    hostSuffix: String = UUID().uuidString,
    hostKey: ClairHostSigningKey = ClairHostSigningKey(),
    hostLimits: ClairDaemonHostLimits = .standard
  ) throws -> Self {
    let project = try H10ProjectFixture()
    let projectID = try ProjectID("h10-project")
    let workspace = try ClairV2WorkspaceRuntime(
      projects: [try ClairV2ProjectRoot(id: projectID, rootURL: project.rootURL)]
    )
    let projectScope = try ResourceScope(projectID: projectID)
    let clock = H10Clock()
    let authority = try ClairPairingAuthority(
      hostID: try ClairHostID("h10-host-\(hostSuffix)"),
      endpoint: try ClairTransportEndpoint("wss://h10.example.test/mobile"),
      hostKey: hostKey,
      defaultVisibleScopes: [projectScope],
      challengeLifetime: 10,
      tokenLifetime: 60 * 24 * 60 * 60,
      clock: clock
    )
    // A real `/bin/sh` process stands in for `opencode`: H04 has no concept
    // of provider identity beyond the launch spec, and this is the same
    // "real subprocess, fake binary" idiom H04's own test suite uses
    // (`ClairV2SystemAgentProcessFactory` launching `/bin/sh -c "sleep 60"`).
    let provider = try ClairV2OpenCodeProvider(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      version: try ClairV2ProviderVersion("h10-fixture"),
      arguments: ["-c", "sleep 300"],
      outputPolicy: .discard,
      processFactory: ClairV2SystemAgentProcessFactory()
    )
    let agentRuntime = try ClairV2AgentRuntime(
      workspace: workspace,
      provider: provider,
      limits: try ClairV2AgentLaunchLimits(terminationGracePeriod: 1)
    )
    let relay = H10RelaySpy()
    let host = try ClairDaemonHost(
      workspace: workspace,
      authority: authority,
      agentRuntime: agentRuntime,
      pushRelay: relay,
      limits: hostLimits,
      pushClock: clock
    )
    return Self(
      project: project, projectID: projectID, authority: authority, agentRuntime: agentRuntime,
      relay: relay, host: host, clock: clock
    )
  }

  func remove() { project.remove() }

  var projectScope: ResourceScope {
    get throws { try ResourceScope(projectID: projectID) }
  }

  /// Full real H03 pairing handshake -> an authenticated connection, exactly
  /// mirroring `ClairV2TransportTests`' `pairClient` helper.
  func pairedConnection(
    capabilities: [Capability] = [
      .view, .spawnSession, .steerAgent, .approve, .signal, .terminate,
      .attentionNotifications, .manageDevices,
    ]
  ) async throws -> (client: ClairNativeClientTransport, connection: ClairAuthenticatedConnection) {
    let client = ClairNativeClientTransport(deviceKey: ClairDeviceKey())
    let link = try await authority.issuePairingLink(lifetime: 60)
    let paired = try await client.pair(
      using: link, with: authority, displayName: "H10 fixture device",
      confirmHostFingerprint: true
    )
    _ = try await authority.updateGrant(
      deviceID: paired.credential.grant.deviceID,
      capabilities: CapabilitySet(capabilities),
      visibleScopes: [try projectScope]
    )
    let connection = try await client.reconnect(to: authority.presentation(), using: authority)
    return (client, connection)
  }
}

private func h10Digest(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func h10Event(
  _ payload: ClairV2AgentEventPayload,
  scope: ResourceScope,
  epoch: SessionEpoch,
  revision: UInt64,
  eventID: String
) throws -> ClairV2AgentNormalizedEvent {
  try EventEnvelope(
    eventID: EventID(eventID), kind: payload.kind.wireKind, scope: scope, epoch: epoch,
    revision: Revision(revision), payload: payload
  )
}

// MARK: - G1 end-to-end integration

@Test
func h10DrivesEveryG1ServerOperationFromASingleFixtureClient() async throws {
  let stack = try H10Stack.make()
  defer { stack.remove() }
  let (_, connection) = try await stack.pairedConnection()

  // Step 2: choose the project (H02).
  let catalog = try await stack.host.catalog(on: connection)
  #expect(catalog.projects.map(\.id) == [stack.projectID])

  // Step 3: start an OpenCode session (H04) — a real child process.
  let sessionID = try SessionID("h10-session")
  let target = ClairV2AgentTarget(projectID: stack.projectID)
  let endpoint = H10FixtureEndpoint()
  let running = try await stack.host.startSession(
    providerID: .openCode, target: target, sessionID: sessionID, endpoint: endpoint,
    on: connection
  )
  #expect(running.lifecycle == .running)
  let processID = try #require(running.processID)
  #expect(Darwin.kill(processID, 0) == 0)
  let epoch = try SessionEpoch(running.processGeneration)
  let sessionScope = running.identity.sessionScope

  // Step 4: send a prompt and read the (simulated) streaming response (H05
  // events ingested through H06+H08 together).
  let promptCommand = try OperationRequest(
    operationID: OperationID("op-prompt"), scope: sessionScope, kind: .agentInput,
    capability: .steerAgent,
    payload: ClairV2AgentCommandPayload(
      epoch: epoch, processGeneration: running.processGeneration, action: .prompt("hello opencode")
    )
  )
  let promptResult = try await stack.host.execute(promptCommand, on: connection)
  #expect(promptResult.outcome == .committed)
  #expect(endpoint.committedActions == [.prompt("hello opencode")])

  let conversationEvent = try h10Event(
    .conversation(ClairV2AgentConversationEvent(role: .assistant, text: "hi", isDelta: false)),
    scope: sessionScope, epoch: epoch, revision: 1, eventID: "evt-1"
  )
  try await stack.host.ingest(conversationEvent)

  // Step 5: an approval request arrives, and the client approves it
  // explicitly (H06).
  let requestDigest = h10Digest("apply-patch")
  let attentionEvent = try h10Event(
    .attention(
      ClairV2AgentAttentionEvent(kind: .approval, requestID: requestDigest, status: .pending)
    ),
    scope: sessionScope, epoch: epoch, revision: 2, eventID: "evt-2"
  )
  try await stack.host.ingest(attentionEvent)

  let approvalReference = try ClairV2AgentApprovalReference(
    requestID: requestDigest, eventID: EventID("evt-2"), revision: Revision(2)
  )
  let approveCommand = try OperationRequest(
    operationID: OperationID("op-approve"), scope: sessionScope, kind: .agentApprove,
    baseRevision: Revision(2), capability: .approve,
    payload: ClairV2AgentCommandPayload(
      epoch: epoch, processGeneration: running.processGeneration,
      action: .approve(approvalReference)
    )
  )
  let approveResult = try await stack.host.execute(approveCommand, on: connection)
  #expect(approveResult.outcome == .committed)

  let completionEvent = try h10Event(
    .completion(ClairV2AgentCompletionEvent(status: .succeeded)),
    scope: sessionScope, epoch: epoch, revision: 3, eventID: "evt-3"
  )
  try await stack.host.ingest(completionEvent)

  // Step 6: changed files and diff (H07).
  try stack.project.writeUncommittedChange()
  let changed = try await stack.host.changedFiles(projectID: stack.projectID, on: connection)
  #expect(changed.files.map(\.path.rawValue) == ["tracked.txt"])
  let diff = try await stack.host.diff(
    projectID: stack.projectID, path: try ClairV2WorkspacePath("tracked.txt"), on: connection
  )
  #expect(diff.hunks.isEmpty == false)

  // Step 7 (journal replay): a subscriber attaches from zero and observes
  // the full ordered history (H08).
  let subscriberID = try ClairV2JournalSubscriberID("mobile-subscriber-1")
  let zeroCursor = try ReplayCursor(scope: sessionScope, epoch: epoch, revision: .zero)
  let firstAttach = try await stack.host.subscribeJournal(
    subscriberID, cursor: zeroCursor, on: connection)
  guard case .replay(let events, let snapshot) = firstAttach else {
    Issue.record("Expected a replay catch-up from zero, got \(firstAttach).")
    return
  }
  #expect(events.map(\.eventID.rawValue) == ["evt-1", "evt-2", "evt-3"])
  #expect(snapshot.revision == Revision(3))
  try await stack.host.acknowledgeJournal(
    subscriberID, scope: sessionScope, upTo: Revision(3), on: connection)

  // Step 8a (network switch / app relaunch): detach and reattach at the
  // acknowledged cursor; the subscriber must not see a gap or a duplicate.
  try await stack.host.detachJournal(subscriberID, scope: sessionScope, on: connection)
  let resumeCursor = try ReplayCursor(scope: sessionScope, epoch: epoch, revision: Revision(3))
  let reattach = try await stack.host.subscribeJournal(
    subscriberID, cursor: resumeCursor, on: connection)
  guard case .upToDate = reattach else {
    Issue.record("Expected the reattached subscriber to be already caught up, got \(reattach).")
    return
  }

  // Step 7b (push wake event) — a completion notification wakes the mobile
  // client (H09), delivered through the fake APNs relay.
  let deviceID = connection.deviceID
  let pushRegistration = try await stack.host.registerPush(
    token: try ClairPushDeviceToken(Data(repeating: 0xAB, count: 32)),
    generation: connection.generation, environment: .sandbox, scope: sessionScope,
    on: connection
  )
  #expect(pushRegistration.requiresRegistration == false)
  let hostIdentity = await stack.authority.hostIdentity
  let wakeEvent = try #require(
    try ClairDaemonPushEvent(
      normalized: completionEvent, host: hostIdentity,
      issuedAt: UInt64(stack.clock.now().timeIntervalSince1970)
    )
  )
  let delivery = try await stack.host.sendPush(wakeEvent, to: deviceID, environment: .sandbox)
  #expect(delivery.status == .accepted)
  #expect(stack.relay.deliveries.count == 1)

  // Explicit stop (H06 -> real H04 termination -> H08 lifecycle close).
  let stopCommand = try OperationRequest(
    operationID: OperationID("op-stop"), scope: sessionScope, kind: .agentStop,
    capability: .terminate,
    payload: ClairV2AgentCommandPayload(
      epoch: epoch, processGeneration: running.processGeneration, action: .stop
    )
  )
  let stopResult = try await stack.host.stopSession(stopCommand, on: connection)
  #expect(stopResult.outcome == .committed)
  var processGone = false
  for _ in 0..<200 {
    if Darwin.kill(processID, 0) == -1, errno == ESRCH {
      processGone = true
      break
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  #expect(processGone)

  let diagnostics = await stack.host.diagnostics()
  #expect(diagnostics.pairedDeviceCount == 1)
  #expect(diagnostics.pushRegistrationCount == 1)
}

// MARK: - Daemon-wide resource limits (H10)

@Test
func h10RejectsSessionStartOnceTheDaemonWideAgentSessionCapIsReached() async throws {
  let stack = try H10Stack.make(
    hostLimits: try ClairDaemonHostLimits(maximumTotalAgentSessions: 1)
  )
  defer { stack.remove() }
  let (_, connection) = try await stack.pairedConnection()
  let target = ClairV2AgentTarget(projectID: stack.projectID)

  let first = try await stack.host.startSession(
    providerID: .openCode, target: target, sessionID: try SessionID("h10-cap-session-1"),
    endpoint: H10FixtureEndpoint(), on: connection
  )
  #expect(first.lifecycle == .running)

  do {
    _ = try await stack.host.startSession(
      providerID: .openCode, target: target, sessionID: try SessionID("h10-cap-session-2"),
      endpoint: H10FixtureEndpoint(), on: connection
    )
    Issue.record("Expected the daemon-wide agent session cap to reject the second session.")
  } catch let error as ClairDaemonHostError {
    #expect(error == .agentSessionCapacityExceeded)
  }

  // The cap must not have leaked a second real process: exactly one session
  // is known to H04.
  let sessions = await stack.agentRuntime.allSessions()
  #expect(sessions.count == 1)

  // Terminate the real spawned process rather than leaving it to run out its
  // full lifetime in the background after the test returns.
  _ = try? await stack.agentRuntime.stop(sessionID: try SessionID("h10-cap-session-1"))
}

@Test
func h10RejectsAdditionalJournalSubscribersOnceTheDaemonWideCapIsReached() async throws {
  let stack = try H10Stack.make(
    hostLimits: try ClairDaemonHostLimits(maximumTotalJournalSubscribers: 1)
  )
  defer { stack.remove() }
  let (_, connection) = try await stack.pairedConnection()
  let target = ClairV2AgentTarget(projectID: stack.projectID)
  let running = try await stack.host.startSession(
    providerID: .openCode, target: target, sessionID: try SessionID("h10-sub-cap-session"),
    endpoint: H10FixtureEndpoint(), on: connection
  )
  let epoch = try SessionEpoch(running.processGeneration)
  let scope = running.identity.sessionScope
  let cursor = try ReplayCursor(scope: scope, epoch: epoch, revision: .zero)

  let first = try ClairV2JournalSubscriberID("subscriber-a")
  _ = try await stack.host.subscribeJournal(first, cursor: cursor, on: connection)

  let second = try ClairV2JournalSubscriberID("subscriber-b")
  do {
    _ = try await stack.host.subscribeJournal(second, cursor: cursor, on: connection)
    Issue.record("Expected the daemon-wide journal subscriber cap to reject the second attach.")
  } catch let error as ClairDaemonHostError {
    #expect(error == .journalSubscriberCapacityExceeded)
  }

  // Re-subscribing the *same* subscriber must remain safe even at capacity
  // (H08's own idempotent-resubscribe guarantee must not be defeated by the
  // daemon-wide counter).
  _ = try await stack.host.subscribeJournal(first, cursor: cursor, on: connection)

  // Freeing the slot allows a new subscriber in.
  try await stack.host.detachJournal(first, scope: scope, on: connection)
  _ = try await stack.host.subscribeJournal(second, cursor: cursor, on: connection)

  _ = try await stack.host.stopSession(
    try OperationRequest(
      operationID: OperationID("op-stop-sub-cap"), scope: scope, kind: .agentStop,
      capability: .terminate,
      payload: ClairV2AgentCommandPayload(
        epoch: epoch, processGeneration: running.processGeneration, action: .stop
      )
    ),
    on: connection
  )
}

// MARK: - Structured diagnostics redaction (H10)

@Test
func h10StructuredDiagnosticsCarryOnlyCountsNoPromptOrIdentityContent() async throws {
  let stack = try H10Stack.make()
  defer { stack.remove() }
  let (_, connection) = try await stack.pairedConnection()
  let target = ClairV2AgentTarget(projectID: stack.projectID)
  let secretPrompt = "top-secret-do-not-leak-this-prompt-text"
  let sessionID = try SessionID("h10-diagnostics-session")
  let running = try await stack.host.startSession(
    providerID: .openCode, target: target, sessionID: sessionID, endpoint: H10FixtureEndpoint(),
    on: connection
  )
  let epoch = try SessionEpoch(running.processGeneration)
  let promptCommand = try OperationRequest(
    operationID: OperationID("op-diagnostics-prompt"), scope: running.identity.sessionScope,
    kind: .agentInput, capability: .steerAgent,
    payload: ClairV2AgentCommandPayload(
      epoch: epoch, processGeneration: running.processGeneration, action: .prompt(secretPrompt)
    )
  )
  _ = try await stack.host.execute(promptCommand, on: connection)

  let diagnostics = await stack.host.diagnostics()
  #expect(diagnostics.agentSessionCounts.running == 1)
  #expect(diagnostics.pairedDeviceCount == 1)

  let encoded = try JSONEncoder().encode(diagnostics)
  let json = String(decoding: encoded, as: UTF8.self)
  #expect(!json.contains(secretPrompt))
  #expect(!json.contains(sessionID.rawValue))
  #expect(!json.contains(connection.deviceID.rawValue))
  #expect(!json.contains(stack.projectID.rawValue))
  // Only the fields documented on `ClairDaemonDiagnosticsSnapshot` — every
  // one a typed identifier, enum, or count — may appear.
  let allowedTopLevelKeys: Set<String> = [
    "instance_id", "paired_device_count", "active_connection_count", "agent_session_counts",
    "journal_open_session_count", "journal_subscriber_count", "push_registration_count",
  ]
  let decoded =
    try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
  #expect(Set(decoded.keys) == allowedTopLevelKeys)

  _ = try await stack.host.stopSession(
    try OperationRequest(
      operationID: OperationID("op-stop-diagnostics"), scope: running.identity.sessionScope,
      kind: .agentStop, capability: .terminate,
      payload: ClairV2AgentCommandPayload(
        epoch: epoch, processGeneration: running.processGeneration, action: .stop
      )
    ),
    on: connection
  )
}

// MARK: - Crash recovery: every dependent component fails closed (H10)

/// Simulates "the daemon restarted" the only faithful way possible given
/// that H01-H09 keep everything in memory: build a second, completely fresh
/// `H10Stack` (fresh `ClairPairingAuthority` grants, fresh `ClairV2AgentRuntime`
/// sessions, fresh `ClairDaemonHost` command boundary/journal/push registry)
/// and confirm every pre-restart identifier is rejected with a typed error
/// by the new stack, rather than silently accepted or silently presenting
/// stale state as current. The host identity/key is deliberately kept
/// identical across the two stacks so the test isolates exactly the
/// documented boundary (in-memory grants/sessions/journal/registrations do
/// not survive a restart) from the separate, already-documented-as-external
/// question of whether the host's own signing key is persisted.
@Test
func h10EveryDependentComponentFailsClosedAfterASimulatedDaemonRestart() async throws {
  let sharedHostSuffix = UUID().uuidString
  let sharedHostKey = ClairHostSigningKey()

  let before = try H10Stack.make(hostSuffix: sharedHostSuffix, hostKey: sharedHostKey)
  defer { before.remove() }
  let (_, connection) = try await before.pairedConnection()
  let target = ClairV2AgentTarget(projectID: before.projectID)
  let sessionID = try SessionID("h10-restart-session")
  let running = try await before.host.startSession(
    providerID: .openCode, target: target, sessionID: sessionID, endpoint: H10FixtureEndpoint(),
    on: connection
  )
  let epoch = try SessionEpoch(running.processGeneration)
  let scope = running.identity.sessionScope
  let subscriberID = try ClairV2JournalSubscriberID("pre-restart-subscriber")
  let zeroCursor = try ReplayCursor(scope: scope, epoch: epoch, revision: .zero)
  _ = try await before.host.subscribeJournal(subscriberID, cursor: zeroCursor, on: connection)
  let deviceID = connection.deviceID
  _ = try await before.host.registerPush(
    token: try ClairPushDeviceToken(Data(repeating: 0xCD, count: 32)),
    generation: connection.generation, environment: .sandbox, scope: scope, on: connection
  )
  let hostIdentity = await before.authority.hostIdentity
  let wakeEvent = try #require(
    try ClairDaemonPushEvent(
      normalized: h10Event(
        .completion(ClairV2AgentCompletionEvent(status: .succeeded)), scope: scope, epoch: epoch,
        revision: 1, eventID: "evt-restart-1"
      ),
      host: hostIdentity, issuedAt: UInt64(before.clock.now().timeIntervalSince1970)
    )
  )
  _ = try? await before.agentRuntime.stop(sessionID: sessionID)

  // "The daemon restarted": a brand-new stack, same host identity, nothing
  // else carried over.
  let after = try H10Stack.make(hostSuffix: sharedHostSuffix, hostKey: sharedHostKey)
  defer { after.remove() }

  // H03: the pre-restart connection/grant is gone. Any request through the
  // host's authorization wrapper is rejected, not silently permitted.
  await #expect(throws: ClairDaemonHostError.unauthorized) {
    _ = try await after.host.catalog(on: connection)
  }

  // H08: the journal has no entry for this session at all after a restart
  // (H08's own documented behavior); a pre-restart cursor is rejected with a
  // typed "no such session" error rather than replayed from nothing.
  await #expect(throws: ClairV2SessionJournalError.unknownSession) {
    _ = try await after.host.journal.subscribe(subscriberID, cursor: zeroCursor)
  }

  // H06: no session is installed in the fresh command boundary, so ingesting
  // a pre-restart event (bypassing the host's authorization wrapper, to
  // isolate H06's own fail-closed behavior specifically) is rejected.
  let staleEvent = try h10Event(
    .attention(
      ClairV2AgentAttentionEvent(kind: .approval, requestID: h10Digest("x"), status: .pending)),
    scope: scope, epoch: epoch, revision: 1, eventID: "evt-restart-2"
  )
  await #expect(throws: ClairV2AgentCommandError.staleSession) {
    try await after.host.commandBoundary.ingest(staleEvent)
  }

  // H04: the session identity itself is unknown to the fresh provider
  // runtime.
  await #expect(throws: ClairV2AgentError.sessionNotFound(sessionID)) {
    _ = try await after.agentRuntime.session(sessionID: sessionID)
  }

  // H09: the host identity matches (kept identical above), but there is no
  // registration in the fresh registry, so delivery fails closed rather than
  // silently succeeding or silently dropping.
  await #expect(throws: ClairPushError.registrationRequired) {
    _ = try await after.host.sendPush(wakeEvent, to: deviceID, environment: .sandbox)
  }
}

// MARK: - Process-level crash recovery (H01, real separate process)

#if os(macOS)

  /// Simulates a real, ungraceful daemon crash at the OS level: a *separate*
  /// real process (not this test process, and not cleaned up by any Swift
  /// `deinit`) holds the exact same advisory lock and control-socket bind
  /// that `ClairDaemonRuntime` itself takes, then is killed with `SIGKILL` —
  /// the one signal a process can never catch or clean up after. A fresh
  /// `ClairDaemonRuntime` at the same paths must then start cleanly (the
  /// kernel released the flock; the daemon's own `removeSocketIfPresent`
  /// unlinks the abandoned socket file) and report a new `instanceID`, which
  /// is the daemon's own typed, discoverable "I restarted" signal.
  @Test
  func h10DaemonProcessSurvivesAbnormalTerminationAndRestartsWithANewInstanceID() async throws {
    let directory = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("clair-v2-h10-crash-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = ClairDaemonPaths(directoryURL: directory)
    try FileManager.default.createDirectory(
      at: paths.directoryURL, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    // A real external process holds the real flock and a real bound
    // AF_UNIX socket at the daemon's exact paths, then sleeps until killed.
    let crashingProcess = Process()
    crashingProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    crashingProcess.arguments = [
      "-c",
      """
      import fcntl, os, socket, sys, time
      lock_path, socket_path = sys.argv[1], sys.argv[2]
      fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      try:
          os.unlink(socket_path)
      except FileNotFoundError:
          pass
      sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
      sock.bind(socket_path)
      os.chmod(socket_path, 0o600)
      sock.listen(1)
      sys.stdout.write("ready\\n")
      sys.stdout.flush()
      time.sleep(300)
      """,
      paths.lockURL.path, paths.socketURL.path,
    ]
    crashingProcess.standardOutput = FileHandle.nullDevice
    crashingProcess.standardError = FileHandle.nullDevice
    try crashingProcess.run()
    defer {
      if crashingProcess.isRunning { crashingProcess.terminate() }
    }
    // Wait for the python fixture to actually hold the lock/socket before
    // proceeding, rather than racing it. This polls file state directly
    // (never a blocking pipe/FileHandle read, which would not honor a
    // deadline if the child were ever slow to start) with a bounded total
    // wait, so a fixture failure times out instead of hanging the suite.
    var socketReady = false
    for _ in 0..<500 {
      var info = stat()
      if Darwin.lstat(paths.socketURL.path, &info) == 0,
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
      {
        socketReady = true
        break
      }
      guard crashingProcess.isRunning else { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(socketReady, "The external crash-fixture process never bound its control socket.")

    let configuration = try ClairDaemonConfiguration(paths: paths)
    let contendingDaemon = ClairDaemon(configuration: configuration)
    do {
      try contendingDaemon.start()
      Issue.record("Expected the real external lock holder to block a second owner.")
      try? contendingDaemon.stop()
    } catch let error as ClairDaemonError {
      #expect(error == .alreadyRunning)
    }

    // The abrupt, uncatchable kill: no cleanup handler in the crashing
    // process ever runs.
    #expect(Darwin.kill(crashingProcess.processIdentifier, SIGKILL) == 0)
    crashingProcess.waitUntilExit()

    let recovered = ClairDaemon(configuration: configuration)
    try recovered.start()
    defer { try? recovered.stop() }
    let client = ClairDaemonControlClient(paths: paths)
    let health = try client.health()
    #expect(health.status == .healthy)
    #expect(health.processID == ProcessInfo.processInfo.processIdentifier)
  }

#endif

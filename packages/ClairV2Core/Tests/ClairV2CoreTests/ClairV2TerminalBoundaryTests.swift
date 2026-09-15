import Foundation
import Testing

@testable import ClairV2Agent
@testable import ClairV2DaemonKit
@testable import ClairV2Push
@testable import ClairV2Shared
@testable import ClairV2Terminal
@testable import ClairV2Transport
@testable import ClairV2Workspace

@Suite(.serialized)
struct ClairV2TerminalBoundaryTests {
  @Test func t02InputOrderingDedupeScopeAndCapacity() async throws {
    let f = try T02BoundaryFixture(maximumOperations: 64)
    let first = try await f.pair()
    let second = try await f.pair()
    let arrivals = try await withThrowingTaskGroup(of: (UInt64, UInt8).self) { group in
      for index in UInt8(1)...20 {
        group.addTask {
          let request = try f.request("order-\(index)", Data([index]))
          let result =
            index % 2 == 0
            ? try f.boundary.localInput(request)
            : try await f.boundary.input(
              request, on: index % 3 == 0 ? first.connection : second.connection)
          return (result.receipt.arrivalSequence, index)
        }
      }
      var result: [(UInt64, UInt8)] = []
      for try await item in group { result.append(item) }
      return result.sorted { $0.0 < $1.0 }.map(\.1)
    }
    #expect(f.process.writes == arrivals.map { Data([$0]) })
    let request = try f.request("retry", Data([33]))
    let original = try await f.boundary.input(request, on: first.connection)
    let duplicate = try await f.boundary.input(request, on: second.connection)
    #expect(original.receipt.arrivalSequence == duplicate.receipt.arrivalSequence)
    #expect(duplicate.receipt.disposition == .duplicate && f.process.writes.count == 21)
    await #expect(throws: (any Error).self) {
      try await f.boundary.input(f.request("retry", Data([34])), on: first.connection)
    }
    let wrongScope = try ResourceScope(
      projectID: ProjectID("foreign"), sessionID: f.scope.sessionID)
    await #expect(throws: (any Error).self) {
      try await f.boundary.input(
        ClairV2TerminalInputRequest(
          operationID: OperationID("foreign"), scope: wrongScope,
          epoch: f.process.terminalJournal.epoch, processGeneration: 1, bytes: Data([1])),
        on: first.connection)
    }
    #expect(f.process.writes.count == 21)
  }

  @Test func t02OperationWindowNeverEvictsExecutedInputs() async throws {
    let f = try T02BoundaryFixture(maximumOperations: 2)
    let client = try await f.pair()
    let a = try f.request("one", Data([1]))
    _ = try await f.boundary.input(a, on: client.connection)
    f.process.setOutcome(.indeterminate)
    _ = try await f.boundary.input(f.request("two", Data([2])), on: client.connection)
    await #expect(throws: ClairV2TerminalError.operationCapacity) {
      try await f.boundary.input(f.request("three", Data([3])), on: client.connection)
    }
    let retry = try await f.boundary.input(a, on: client.connection)
    #expect(retry.outcome == .queued && retry.receipt.disposition == .duplicate)
    let uncertain = try await f.boundary.input(f.request("two", Data([2])), on: client.connection)
    #expect(uncertain.outcome == .indeterminate && f.process.writes.count == 2)
  }

  @Test func t02ViewOnlyRevokeAndStaleGenerationRejectBeforeEffect() async throws {
    let f = try T02BoundaryFixture()
    let viewer = try await f.pair(capabilities: [.view])
    await #expect(throws: (any Error).self) {
      try await f.boundary.input(f.request("view", Data([1])), on: viewer.connection)
    }
    let writer = try await f.pair()
    let old = try f.request("stale", Data([2]))
    let replacement = try T02MemoryProcess()
    try f.boundary.install(snapshot: f.snapshot(generation: 2), process: replacement)
    await #expect(throws: ClairV2TerminalError.staleSession) {
      try await f.boundary.input(old, on: writer.connection)
    }
    _ = try await f.authority.revoke(deviceID: writer.connection.deviceID)
    await #expect(throws: (any Error).self) {
      try await f.boundary.input(
        ClairV2TerminalInputRequest(
          operationID: OperationID("revoked"), scope: f.scope,
          epoch: replacement.terminalJournal.epoch, processGeneration: 2, bytes: Data([3])),
        on: writer.connection)
    }
    #expect(f.process.writes.isEmpty && replacement.writes.isEmpty)
  }

  @Test func t02SlowSubscriberGapAndAckAreIndependent() async throws {
    let f = try T02BoundaryFixture(journalBytes: 8)
    let a = try await f.pair()
    let b = try await f.pair()
    let fast = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: UUID(), on: a.connection
    ).attachment
    let slow = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: UUID(), on: b.connection
    ).attachment
    try f.process.terminalJournal.append(Data([1, 2, 3, 4]))
    let frame = try #require(try await f.boundary.read(fast, on: a.connection))
    #expect(try await f.boundary.read(fast, on: a.connection) == frame)
    await #expect(throws: ClairV2TerminalError.invalidCursor) {
      try await f.boundary.acknowledge(
        fast, cursor: ClairV2TerminalCursor(epoch: frame.cursor.epoch, offset: 8), on: a.connection)
    }
    try await f.boundary.acknowledge(fast, cursor: frame.nextCursor, on: a.connection)
    try await f.boundary.acknowledge(fast, cursor: frame.nextCursor, on: a.connection)
    try f.process.terminalJournal.append(Data([5, 6, 7, 8, 9, 10, 11, 12]))
    await #expect(throws: ClairV2TerminalError.gap(availableOffset: 4)) {
      try await f.boundary.read(slow, on: b.connection)
    }
    let next = try #require(try await f.boundary.read(fast, on: a.connection))
    #expect(next.bytes == Data([5, 6, 7, 8, 9, 10, 11, 12]))
    try f.process.terminalJournal.append(Data(repeating: 0, count: 16))
    #expect(try await f.boundary.read(fast, on: a.connection) == next)
    try await f.boundary.acknowledge(fast, cursor: next.nextCursor, on: a.connection)
    await #expect(throws: ClairV2TerminalError.gap(availableOffset: 20)) {
      try await f.boundary.read(fast, on: a.connection)
    }
    #expect(f.process.terminalJournal.snapshot().endOffset == 28)
  }

  @Test func t02ReconnectBindsConnectionAndPreservesNamedCursor() async throws {
    let f = try T02BoundaryFixture(maximumSubscribers: 1)
    let peer = try await f.pair()
    let subscriber = UUID()
    let attachment = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: subscriber, on: peer.connection
    ).attachment
    try f.process.terminalJournal.append(Data([9, 8, 7]))
    let offered = try #require(try await f.boundary.read(attachment, on: peer.connection))
    try await f.boundary.acknowledge(attachment, cursor: offered.nextCursor, on: peer.connection)
    await f.authority.close(peer.connection)
    let connection = try await peer.client.reconnect(
      to: f.authority.presentation(), using: f.authority)
    let restored = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: subscriber,
      cursor: offered.nextCursor, on: connection
    ).attachment
    #expect(restored.cursor == offered.nextCursor)
    #expect(try await f.boundary.read(restored, on: connection) == nil)
    await #expect(throws: (any Error).self) {
      try await f.boundary.read(attachment, on: peer.connection)
    }
    await #expect(throws: ClairV2TerminalError.staleSession) {
      try await f.boundary.read(attachment, on: connection)
    }
    try await f.boundary.detach(restored, on: connection)
    #expect(!f.process.terminalJournal.snapshot().isClosed)
  }

  @Test func t04ClosedConnectionDoesNotConsumeSubscriberCapacity() async throws {
    let f = try T02BoundaryFixture(maximumSubscribers: 1)
    let first = try await f.pair()
    _ = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: UUID(), on: first.connection
    )

    _ = try await f.authority.revoke(deviceID: first.connection.deviceID)
    let second = try await f.pair()
    _ = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: UUID(), on: second.connection
    )
  }

  @Test func t04AlternateScreenReconnectPreservesByteExactContinuity() async throws {
    // Bytes are opaque to this layer, but exercising real alternate-screen
    // control sequences proves reconnect never splices, drops, or duplicates
    // a byte across the boundary that redraws a client's whole viewport.
    let enterAltScreen = Data("\u{1B}[?1049h".utf8)
    let redrawWhileDisconnected = Data("\u{1B}[2J\u{1B}[Hsome content".utf8)
    let exitAltScreen = Data("\u{1B}[?1049l".utf8)

    let f = try T02BoundaryFixture(journalBytes: 4096)
    let peer = try await f.pair()
    let subscriber = UUID()
    let attachment = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: subscriber, on: peer.connection
    ).attachment

    try f.process.terminalJournal.append(enterAltScreen)
    let opening = try #require(try await f.boundary.read(attachment, on: peer.connection))
    try await f.boundary.acknowledge(attachment, cursor: opening.nextCursor, on: peer.connection)

    // Reconnect while alternate screen is still active and more redraw bytes
    // arrive only after the client has dropped off the old connection.
    await f.authority.close(peer.connection)
    let connection = try await peer.client.reconnect(
      to: f.authority.presentation(), using: f.authority)
    try f.process.terminalJournal.append(redrawWhileDisconnected)
    let restored = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: subscriber,
      cursor: opening.nextCursor, on: connection
    ).attachment
    #expect(restored.cursor == opening.nextCursor)

    let redrawFrame = try #require(try await f.boundary.read(restored, on: connection))
    #expect(redrawFrame.bytes == redrawWhileDisconnected)
    try await f.boundary.acknowledge(restored, cursor: redrawFrame.nextCursor, on: connection)

    try f.process.terminalJournal.append(exitAltScreen)
    let closing = try #require(try await f.boundary.read(restored, on: connection))
    #expect(closing.bytes == exitAltScreen)

    let assembled = opening.bytes + redrawFrame.bytes + closing.bytes
    #expect(assembled == enterAltScreen + redrawWhileDisconnected + exitAltScreen)
  }

  @Test func t04SlowSubscriberAltScreenFloodGetsExplicitGapNotCorruption() async throws {
    let enterAltScreen = Data("\u{1B}[?1049h".utf8)
    let redrawFlood = Data(repeating: 0x41, count: 64)

    let f = try T02BoundaryFixture(journalBytes: 16)
    let peer = try await f.pair()
    let slow = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: UUID(), on: peer.connection
    ).attachment

    try f.process.terminalJournal.append(enterAltScreen)
    let opening = try #require(try await f.boundary.read(slow, on: peer.connection))
    #expect(opening.bytes == enterAltScreen)
    try await f.boundary.acknowledge(slow, cursor: opening.nextCursor, on: peer.connection)

    // The subscriber stalls (never reads again) while a large redraw burst
    // evicts everything it has not yet consumed out of the bounded journal.
    try f.process.terminalJournal.append(redrawFlood)
    let retainedStart = f.process.terminalJournal.snapshot().retainedStart
    #expect(retainedStart > opening.nextCursor.offset)

    await #expect(throws: ClairV2TerminalError.gap(availableOffset: retainedStart)) {
      try await f.boundary.read(slow, on: peer.connection)
    }
    // A gap is surfaced explicitly; the subscriber never receives a silently
    // spliced or misaligned frame in place of the bytes it lost.
    let snapshot = try await f.boundary.snapshot(slow, on: peer.connection)
    #expect(snapshot.historyTruncated && snapshot.retainedStart == retainedStart)

    // Resync from the daemon-reported retained start recovers exactly the
    // still-available suffix of the flood, byte for byte.
    let resynced = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: UUID(),
      cursor: ClairV2TerminalCursor(epoch: opening.cursor.epoch, offset: retainedStart),
      on: peer.connection
    ).attachment
    let recovered = try #require(try await f.boundary.read(resynced, on: peer.connection))
    #expect(recovered.bytes == redrawFlood.suffix(recovered.bytes.count))
  }

  @Test func t02DesktopGeometryRequiresExactOwnerAndMobileAttachCannotResize() async throws {
    let f = try T02BoundaryFixture()
    let peer = try await f.pair()
    let before = f.process.terminalSize
    _ = try await f.boundary.attach(
      scope: f.scope, generation: 1, subscriberID: UUID(), on: peer.connection)
    #expect(f.process.terminalSize == before)
    let owner = try f.boundary.claimDesktopResizeOwner(scope: f.scope, generation: 1)
    #expect(throws: ClairV2TerminalError.resizeDenied) {
      try f.boundary.claimDesktopResizeOwner(scope: f.scope, generation: 1)
    }
    let size = try ClairV2TerminalSize(rows: 40, columns: 120)
    try f.boundary.resize(size, owner: owner)
    #expect(f.process.terminalSize == size)
    try f.boundary.releaseDesktopResizeOwner(owner)
    #expect(
      try f.boundary.localInput(f.request("without-resize-owner", Data([1]))).outcome == .queued)
    #expect(throws: ClairV2TerminalError.resizeDenied) {
      try f.boundary.resize(before, owner: owner)
    }
    let replacement = try T02MemoryProcess()
    try f.boundary.install(snapshot: f.snapshot(generation: 2), process: replacement)
    #expect(throws: ClairV2TerminalError.resizeDenied) {
      try f.boundary.resize(before, owner: owner)
    }
  }
}

private final class T02MemoryProcess: ClairV2TerminalProcess, @unchecked Sendable {
  let terminalJournal: ClairV2TerminalJournal
  private let lock = NSLock()
  private var values: [Data] = []
  private var outcome: ClairV2TerminalCommitOutcome = .queued
  private var size = try! ClairV2TerminalSize()
  init(capacity: Int = 1024) throws {
    terminalJournal = try ClairV2TerminalJournal(capacity: capacity)
  }
  var writes: [Data] { lock.withLock { values } }
  var terminalSize: ClairV2TerminalSize { lock.withLock { size } }
  func setOutcome(_ value: ClairV2TerminalCommitOutcome) { lock.withLock { outcome = value } }
  func enqueueTerminalInput(_ bytes: Data) -> ClairV2TerminalCommitOutcome {
    lock.withLock {
      values.append(bytes)
      return outcome
    }
  }
  func commitTerminalSignal(_ signal: Int32) -> ClairV2TerminalCommitOutcome { .queued }
  func resizeTerminal(_ size: ClairV2TerminalSize) throws { lock.withLock { self.size = size } }
}

private struct T02BoundaryFixture: Sendable {
  let authority: ClairPairingAuthority
  let process: T02MemoryProcess
  let boundary: ClairV2TerminalBoundary
  let scope: ResourceScope
  let identity: ClairV2AgentSessionIdentity
  init(maximumOperations: Int = 32, journalBytes: Int = 1024, maximumSubscribers: Int = 8) throws {
    let project = try ProjectID("t02-project")
    identity = try ClairV2AgentSessionIdentity(
      provider: ClairV2ProviderIdentity(providerID: .openCode, version: .unknown),
      projectID: project, sessionID: SessionID("t02-session"))
    scope = identity.sessionScope
    authority = try ClairPairingAuthority(
      hostID: ClairHostID("t02-host"),
      endpoint: ClairTransportEndpoint("wss://t02.example.test/mobile"),
      defaultVisibleScopes: [ResourceScope(projectID: project)])
    process = try T02MemoryProcess(capacity: journalBytes)
    boundary = try ClairV2TerminalBoundary(
      authority: authority, maximumSubscribers: maximumSubscribers,
      maximumOperations: maximumOperations)
    try boundary.install(snapshot: snapshot(generation: 1), process: process)
  }
  func snapshot(generation: UInt64) -> ClairV2AgentSessionSnapshot {
    ClairV2AgentSessionSnapshot(
      identity: identity, workingDirectoryURL: URL(fileURLWithPath: "/"), lifecycle: .running,
      processID: 100, processGeneration: generation, exit: nil, failure: nil,
      outputWasTruncated: false)
  }
  func request(_ id: String, _ bytes: Data) throws -> ClairV2TerminalInputRequest {
    try ClairV2TerminalInputRequest(
      operationID: OperationID(id), scope: scope, epoch: process.terminalJournal.epoch,
      processGeneration: 1, bytes: bytes)
  }
  func pair(capabilities: [Capability] = [.view, .writeTerminal]) async throws -> (
    client: ClairNativeClientTransport, connection: ClairAuthenticatedConnection
  ) {
    let client = ClairNativeClientTransport(deviceKey: ClairDeviceKey())
    let paired = try await client.pair(
      using: authority.issuePairingLink(lifetime: 60), with: authority,
      displayName: "T02 fixture", confirmHostFingerprint: true)
    _ = try await authority.updateGrant(
      deviceID: paired.credential.grant.deviceID,
      capabilities: CapabilitySet(capabilities),
      visibleScopes: [ResourceScope(projectID: scope.projectID)])
    return (client, try await client.reconnect(to: authority.presentation(), using: authority))
  }
}

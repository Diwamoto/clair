import Foundation
import Testing

@testable import ClairV2Agent
@testable import ClairV2DaemonKit
@testable import ClairV2GhosttyVT
@testable import ClairV2MobileKit
@testable import ClairV2Shared
@testable import ClairV2Terminal
@testable import ClairV2Transport
@testable import ClairV2Workspace

/// Proves `ClairV2MobileTerminalSession`'s attach/read-pump/acknowledge/
/// background-detach/foreground-resync/keyboard-input state machine against
/// a *real* `ClairV2TerminalBoundary` (T04) over an in-process transport,
/// with a `FakeTerminalEngine` standing in for `GhosttyVTTerminal` (which
/// only runs where `GhosttyVT.xcframework` is actually vendored -- iOS
/// only, never this suite's host; see `ClairV2TerminalEngine`'s doc
/// comment). This is deliberately the same fixture shape as
/// `ClairV2TerminalBoundaryTests`' `T02BoundaryFixture`: a real
/// `ClairPairingAuthority` + `ClairV2TerminalBoundary` + in-memory PTY
/// process fixture, pairing/authenticating a real client connection.
@Suite(.serialized)
@MainActor
struct ClairV2MobileTerminalSessionTests {
  @Test func foregroundAttachesReadsBufferedOutputAndAcknowledges() async throws {
    let f = try T05Fixture()
    let client = try await f.pair()
    f.process.terminalJournal.appendOrFail(Data("hello\n".utf8))
    let engine = FakeTerminalEngine()
    let session = ClairV2MobileTerminalSession(transport: f.transport, engine: engine)

    await session.foreground(scope: f.scope, generation: 1, on: client.connection)
    try await waitUntil { engine.writtenBytes == Data("hello\n".utf8) }

    #expect(session.state == .attached)
    #expect(engine.resizedTo?.columns == Int(f.process.terminalSize.columns))
    #expect(engine.scrollToBottomCallCount == 1)
  }

  @Test func backgroundDetachesReleasingTheSubscriberSlot() async throws {
    // maximumSubscribers: 1 turns "did background() actually release the
    // slot" into something directly observable: a second device's attach
    // must fail while this session holds the only slot, and succeed once
    // background() has run.
    let f = try T05Fixture(maximumSubscribers: 1)
    let client = try await f.pair()
    let session = ClairV2MobileTerminalSession(
      transport: f.transport, engine: FakeTerminalEngine())

    await session.foreground(scope: f.scope, generation: 1, on: client.connection)
    try await waitUntil { session.state == .attached }

    let other = try await f.pair()
    await #expect(throws: (any Error).self) {
      _ = try await f.transport.attach(
        scope: f.scope, generation: 1, cursor: nil, on: other.connection)
    }

    await session.background()
    #expect(session.state == .detached)

    // The slot is free now: the same second device can attach.
    _ = try await f.transport.attach(
      scope: f.scope, generation: 1, cursor: nil, on: other.connection)
  }

  @Test func foregroundAfterBackgroundResumesFromTheAcknowledgedCursor() async throws {
    let f = try T05Fixture()
    let client = try await f.pair()
    let engine = FakeTerminalEngine()
    let session = ClairV2MobileTerminalSession(transport: f.transport, engine: engine)

    f.process.terminalJournal.appendOrFail(Data("first\n".utf8))
    await session.foreground(scope: f.scope, generation: 1, on: client.connection)
    try await waitUntil { engine.writtenBytes == Data("first\n".utf8) }
    await session.background()

    f.process.terminalJournal.appendOrFail(Data("second\n".utf8))
    await session.foreground(scope: f.scope, generation: 1, on: client.connection)
    // `writtenBytes` accumulates across both attaches (`FakeTerminalEngine.write`
    // appends). Resumed exactly at "second", never re-delivered "first":
    // proves the acknowledged cursor round-trips through background()/
    // foreground(), not just "replays everything from the retained start"
    // every time (which would instead produce "first\nfirst\nsecond\n").
    try await waitUntil { engine.writtenBytes == Data("first\nsecond\n".utf8) }
  }

  @Test func staleAcknowledgedCursorFallsBackToFreshResyncAttach() async throws {
    // A tiny journal capacity so writing past it while "backgrounded"
    // (no live subscriber, per T04's bounded-journal design) prunes past
    // this device's last acknowledged cursor -- the gap/resync failure
    // mode `ClairV2MobileTerminalSession.foreground`'s doc comment
    // documents.
    let f = try T05Fixture(journalBytes: 16)
    let client = try await f.pair()
    let engine = FakeTerminalEngine()
    let session = ClairV2MobileTerminalSession(transport: f.transport, engine: engine)

    f.process.terminalJournal.appendOrFail(Data("a".utf8))
    await session.foreground(scope: f.scope, generation: 1, on: client.connection)
    try await waitUntil { engine.writtenBytes == Data("a".utf8) }
    await session.background()

    // Overflow the bounded journal well past its 16-byte capacity so the
    // previously-acknowledged cursor is no longer retained.
    for _ in 0..<8 { f.process.terminalJournal.appendOrFail(Data("0123456789".utf8)) }

    await session.foreground(scope: f.scope, generation: 1, on: client.connection)
    try await waitUntil { session.state == .attached }
    // Recovered via the no-cursor fallback attach instead of getting stuck
    // in `.failed` -- the resync behavior this task requires.
    #expect(session.state == .attached)
  }

  @Test func sendKeyEncodesAndDeliversBytesToTheDaemonProcess() async throws {
    let f = try T05Fixture()
    let client = try await f.pair()
    let session = ClairV2MobileTerminalSession(
      transport: f.transport, engine: FakeTerminalEngine())
    await session.foreground(scope: f.scope, generation: 1, on: client.connection)
    try await waitUntil { session.state == .attached }

    await session.sendKey(.text("ls"))
    await session.sendKey(.return)
    await session.sendKey(.control("c"))

    try await waitUntil { f.process.writes.count == 3 }
    #expect(f.process.writes == [Data("ls".utf8), Data([0x0D]), Data([0x03])])
  }

  @Test func streamEnabledModesShapePasteMouseAndFocusInput() async throws {
    let f = try T05Fixture()
    let client = try await f.pair()
    f.process.terminalJournal.appendOrFail(Data("\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?1000h\u{1B}[?1006h".utf8))
    let session = ClairV2MobileTerminalSession(
      transport: f.transport, engine: FakeTerminalEngine())
    await session.foreground(scope: f.scope, generation: 1, on: client.connection)
    try await waitUntil { session.modes.bracketedPaste && session.modes.mouseSGR }

    await session.paste("a\nb")
    await session.sendFocus(true)
    await session.sendMouse(.left, .press, column: 1, row: 2)

    try await waitUntil { f.process.writes.count == 3 }
    #expect(
      f.process.writes == [
        ClairV2TerminalPaste.bracketStart + Data("a\rb".utf8) + ClairV2TerminalPaste.bracketEnd,
        Data([0x1B, 0x5B, 0x49]),
        Data("\u{1B}[<0;2;3M".utf8),
      ])
  }

  @Test func sendKeyBeforeAttachIsANoOp() async throws {
    let f = try T05Fixture()
    let session = ClairV2MobileTerminalSession(
      transport: f.transport, engine: FakeTerminalEngine())
    await session.sendKey(.text("ls"))
    #expect(f.process.writes.isEmpty)
  }
}

// MARK: - Fixtures

/// A `ClairV2TerminalEngine` fake that records written bytes and calls
/// instead of running a real VT parser -- see the suite doc comment for why.
@MainActor
private final class FakeTerminalEngine: ClairV2TerminalEngine {
  private(set) var writtenBytes = Data()
  private(set) var resizedTo: (columns: Int, rows: Int)?
  private(set) var scrollToBottomCallCount = 0
  private(set) var scrolledByRows: [Int] = []
  var selectionResult: String?

  func write(_ bytes: Data) throws { writtenBytes.append(bytes) }
  func resize(columns: Int, rows: Int) throws { resizedTo = (columns, rows) }
  func scrollToBottom() throws { scrollToBottomCallCount += 1 }
  func scroll(byRows rows: Int) throws { scrolledByRows.append(rows) }
  func snapshot() throws -> GhosttyVTScreenSnapshot {
    GhosttyVTScreenSnapshot(
      lines: String(decoding: writtenBytes, as: UTF8.self).components(separatedBy: "\n"),
      cursor: GhosttyVTCursor(column: 0, row: 0, visible: true), totalRows: 24, scrollbackRows: 0)
  }
  func selectedText(from start: GhosttyVTViewportPoint, to end: GhosttyVTViewportPoint) throws
    -> String?
  {
    selectionResult
  }
}

/// Forwards `ClairV2MobileTerminalTransport` calls to a real, in-process
/// `ClairV2TerminalBoundary` -- the same relationship
/// `ClairInProcessMobileTransport` (`ClairV2MobileReconnect.swift`) has to
/// `ClairPairingAuthority` for other mobile domains. Reconstructs the
/// daemon-only `ClairV2TerminalAttachment` from the mobile mirror's fields
/// on every call: the daemon boundary's subscriber lookup compares the
/// *original* attach-time attachment value field-for-field (not a live
/// cursor), so round-tripping the same id/scope/generation/cursor/epoch is
/// exactly what a faithful adapter must do.
private struct InProcessTerminalTransport: ClairV2MobileTerminalTransport {
  let boundary: ClairV2TerminalBoundary

  func attach(
    scope: ResourceScope, generation: UInt64, cursor: ClairV2TerminalCursor?,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2MobileTerminalAttachment {
    let state = try await boundary.attach(
      scope: scope, generation: generation, subscriberID: UUID(), cursor: cursor, on: connection)
    return ClairV2MobileTerminalAttachment(
      id: state.attachment.id, scope: state.attachment.scope,
      generation: state.attachment.generation, cursor: state.attachment.cursor,
      size: state.size, epoch: state.stream.epoch)
  }

  func read(
    _ attachment: ClairV2MobileTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2TerminalFrame? {
    try await boundary.read(daemon(attachment), on: connection)
  }

  func acknowledge(
    _ attachment: ClairV2MobileTerminalAttachment, cursor: ClairV2TerminalCursor,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    try await boundary.acknowledge(daemon(attachment), cursor: cursor, on: connection)
  }

  func input(
    _ bytes: Data, attachment: ClairV2MobileTerminalAttachment,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    let request = try ClairV2TerminalInputRequest(
      operationID: OperationID(UUID().uuidString), scope: attachment.scope,
      epoch: attachment.epoch, processGeneration: attachment.generation, bytes: bytes)
    _ = try await boundary.input(request, on: connection)
  }

  func detach(
    _ attachment: ClairV2MobileTerminalAttachment, on connection: ClairAuthenticatedConnection
  ) async throws {
    try await boundary.detach(daemon(attachment), on: connection)
  }

  private func daemon(_ attachment: ClairV2MobileTerminalAttachment) -> ClairV2TerminalAttachment {
    ClairV2TerminalAttachment(
      id: attachment.id, scope: attachment.scope, generation: attachment.generation,
      cursor: attachment.cursor)
  }
}

private final class T05Process: ClairV2TerminalProcess, @unchecked Sendable {
  let terminalJournal: ClairV2TerminalJournal
  private let lock = NSLock()
  private var values: [Data] = []
  private var size = try! ClairV2TerminalSize(rows: 24, columns: 80)
  init(capacity: Int) throws {
    terminalJournal = try ClairV2TerminalJournal(capacity: capacity)
  }
  var writes: [Data] { lock.withLock { values } }
  var terminalSize: ClairV2TerminalSize { lock.withLock { size } }
  func enqueueTerminalInput(_ bytes: Data) -> ClairV2TerminalCommitOutcome {
    lock.withLock {
      values.append(bytes)
      return .queued
    }
  }
  func commitTerminalSignal(_ signal: Int32) -> ClairV2TerminalCommitOutcome { .queued }
  func resizeTerminal(_ size: ClairV2TerminalSize) throws { lock.withLock { self.size = size } }
}

private struct T05Fixture: Sendable {
  let authority: ClairPairingAuthority
  let process: T05Process
  let boundary: ClairV2TerminalBoundary
  let transport: InProcessTerminalTransport
  let scope: ResourceScope
  let identity: ClairV2AgentSessionIdentity

  init(journalBytes: Int = 1024, maximumSubscribers: Int = 8) throws {
    let project = try ProjectID("t05-project")
    identity = try ClairV2AgentSessionIdentity(
      provider: ClairV2ProviderIdentity(providerID: .openCode, version: .unknown),
      projectID: project, sessionID: SessionID("t05-session"))
    scope = identity.sessionScope
    authority = try ClairPairingAuthority(
      hostID: ClairHostID("t05-host"),
      endpoint: ClairTransportEndpoint("wss://t05.example.test/mobile"),
      defaultVisibleScopes: [ResourceScope(projectID: project)])
    process = try T05Process(capacity: journalBytes)
    boundary = try ClairV2TerminalBoundary(
      authority: authority, maximumSubscribers: maximumSubscribers)
    try boundary.install(
      snapshot: Self.snapshot(identity: identity, generation: 1), process: process)
    transport = InProcessTerminalTransport(boundary: boundary)
  }

  static func snapshot(
    identity: ClairV2AgentSessionIdentity, generation: UInt64
  ) -> ClairV2AgentSessionSnapshot {
    ClairV2AgentSessionSnapshot(
      identity: identity, workingDirectoryURL: URL(fileURLWithPath: "/"), lifecycle: .running,
      processID: 100, processGeneration: generation, exit: nil, failure: nil,
      outputWasTruncated: false)
  }

  func pair(capabilities: [Capability] = [.view, .writeTerminal]) async throws -> (
    client: ClairNativeClientTransport, connection: ClairAuthenticatedConnection
  ) {
    let client = ClairNativeClientTransport(deviceKey: ClairDeviceKey())
    let paired = try await client.pair(
      using: authority.issuePairingLink(lifetime: 60), with: authority,
      displayName: "T05 fixture", confirmHostFingerprint: true)
    _ = try await authority.updateGrant(
      deviceID: paired.credential.grant.deviceID,
      capabilities: CapabilitySet(capabilities),
      visibleScopes: [ResourceScope(projectID: scope.projectID)])
    return (client, try await client.reconnect(to: authority.presentation(), using: authority))
  }
}

extension ClairV2TerminalJournal {
  /// Test convenience: most call sites in this suite do not care about a
  /// (bounded-capacity) append failure, only about the bytes becoming
  /// visible to a subscriber.
  fileprivate func appendOrFail(_ data: Data) {
    try? append(data)
  }
}

/// Polls `condition` until it returns `true` or `timeout` elapses. Used
/// instead of a fixed `Task.sleep` because `ClairV2MobileTerminalSession`'s
/// read pump runs as an independent `Task` with its own poll/backoff
/// timing; the test only needs to know the effect landed, not exactly when.
private func waitUntil(
  timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !(await condition()) {
    if ContinuousClock.now > deadline {
      Issue.record("condition not met within \(timeout)")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

import ClairGhosttyVT
import ClairShared
import ClairTerminal
import ClairTransport
import Foundation

/// The observable state of one `ClairMobileTerminalSession`. Mirrors the
/// shape of `ClairMobileClientState`/`ClairMobileReconnectState`: exactly
/// one of these holds at a time, and `.attached` is only ever reached
/// through a host-confirmed `attach()`, never assumed from a cache.
public enum ClairMobileTerminalSessionState: Equatable, Sendable {
  case detached
  case attaching
  case attached
  case failed
}

/// Owns one iOS-side terminal: a `GhosttyVTTerminal` VT parser fed by T04's
/// raw byte stream (via `ClairMobileTerminalTransport`), plus the
/// attach/background-detach/foreground-reattach lifecycle T05's acceptance
/// requires. This is the transport-neutral, `UIKit`-free half of the
/// feature -- `ClairTerminalView` (iOS `UIView`) drives it and renders
/// `onScreenUpdate`'s snapshots; this type has no view/gesture code, so its
/// attach/detach/reconnect/byte-feed logic is testable in a plain `swift
/// test` run (see `ClairMobileTerminalSessionTests`) without a simulator.
///
/// Background detach: `background()` cancels the read pump and calls
/// `transport.detach`, releasing this device's subscriber slot on the
/// daemon (T04's `ClairTerminalBoundary.detach`) instead of holding a
/// connection open while suspended. `foreground()` re-attaches using the
/// last acknowledged cursor; if the daemon's bounded journal has already
/// pruned past it (T04's documented gap/backpressure failure mode -- the
/// journal is capacity-bounded per session, independent of subscriber
/// count), this falls back to a fresh attach with no cursor (starts from
/// the journal's current retained start) rather than failing outright. This
/// is the "T04's reconnect/resync path" behavior T05 requires: a session
/// backgrounded longer than the journal's retention window loses exactly
/// that backlog, never corrupts or wedges the stream.
@MainActor
public final class ClairMobileTerminalSession {
  private let transport: any ClairMobileTerminalTransport
  private let terminal: any ClairTerminalEngine
  private var attachment: ClairMobileTerminalAttachment?
  private var lastAcknowledgedCursor: ClairTerminalCursor?
  private var connection: ClairAuthenticatedConnection?
  private var scope: ResourceScope?
  private var generation: UInt64?
  private var pumpTask: Task<Void, Never>?

  public private(set) var state: ClairMobileTerminalSessionState = .detached
  /// DEC modes the remote program has enabled (bracketed paste, mouse, focus),
  /// scanned from the output stream; reset on every fresh attach.
  public private(set) var modes = ClairTerminalModes()
  /// Invoked on the main actor after every successfully applied frame.
  public var onScreenUpdate: ((GhosttyVTScreenSnapshot) -> Void)?

  public init(transport: any ClairMobileTerminalTransport, columns: Int = 80, rows: Int = 24)
    throws
  {
    self.transport = transport
    self.terminal = try GhosttyVTTerminal(columns: columns, rows: rows)
  }

  /// Test/preview seam: injects a `ClairTerminalEngine` directly instead
  /// of constructing a real `GhosttyVTTerminal` (which only runs where
  /// `GhosttyVT.xcframework` is vendored -- see that protocol's doc
  /// comment). Production call sites always use the throwing initializer
  /// above.
  public init(transport: any ClairMobileTerminalTransport, engine: any ClairTerminalEngine) {
    self.transport = transport
    self.terminal = engine
  }

  public var currentSnapshot: GhosttyVTScreenSnapshot? { try? terminal.snapshot() }

  /// Attaches (or re-attaches) to `scope`'s remote terminal session and
  /// starts the read pump. A no-op if already attaching/attached to the
  /// same scope+generation; callers can call this unconditionally from a
  /// scene-foreground handler.
  public func foreground(
    scope: ResourceScope, generation: UInt64, on connection: ClairAuthenticatedConnection
  ) async {
    guard state != .attaching, state != .attached else { return }
    self.connection = connection
    self.scope = scope
    self.generation = generation
    state = .attaching

    do {
      let resolved = try await attachResync(scope: scope, generation: generation, on: connection)
      attachment = resolved
      lastAcknowledgedCursor = resolved.cursor
      try terminal.resize(columns: Int(resolved.size.columns), rows: Int(resolved.size.rows))
      try? terminal.scrollToBottom()
      state = .attached
      startPump(on: connection)
    } catch {
      state = .failed
    }
  }

  /// Tries `lastAcknowledgedCursor` first (resume exactly where this device
  /// left off); on any failure, retries once with no cursor (fresh attach
  /// from the journal's current retained start) -- the resync fallback
  /// documented on the type.
  private func attachResync(
    scope: ResourceScope, generation: UInt64, on connection: ClairAuthenticatedConnection
  ) async throws -> ClairMobileTerminalAttachment {
    if let lastAcknowledgedCursor {
      if let resumed = try? await transport.attach(
        scope: scope, generation: generation, cursor: lastAcknowledgedCursor, on: connection)
      {
        return resumed
      }
    }
    modes = ClairTerminalModes()
    return try await transport.attach(
      scope: scope, generation: generation, cursor: nil, on: connection)
  }

  /// Cancels the read pump and detaches from the daemon, releasing this
  /// device's subscriber slot. The VT parser's own screen state (and
  /// `lastAcknowledgedCursor`, for the next `foreground()`'s resume
  /// attempt) is preserved -- only the live connection is released, so a
  /// quick background/foreground cycle draws the last-known screen
  /// immediately while reattaching, instead of clearing to blank.
  public func background() async {
    pumpTask?.cancel()
    pumpTask = nil
    if let attachment, let connection {
      try? await transport.detach(attachment, on: connection)
    }
    attachment = nil
    self.connection = nil
    state = .detached
  }

  /// Encodes and sends one hardware-keyboard key event upstream. A no-op
  /// (not an error) when not currently attached -- typing into a
  /// backgrounded/detached view has nowhere to go and should not surface as
  /// a user-visible failure.
  public func sendKey(_ key: ClairTerminalKey) async {
    guard let attachment, let connection else { return }
    let bytes = ClairTerminalKeyEncoding.encode(key)
    guard !bytes.isEmpty else { return }
    try? await transport.input(bytes, attachment: attachment, on: connection)
  }

  /// Sends raw pre-encoded bytes (paste, mouse, focus reports). Same no-op-
  /// when-detached contract as `sendKey`. Never resizes the remote PTY: the
  /// mobile viewport is local, geometry is desktop-owned (`T04` resize owner).
  public func sendInput(_ bytes: Data) async {
    guard !bytes.isEmpty, let attachment, let connection else { return }
    try? await transport.input(bytes, attachment: attachment, on: connection)
  }

  public func paste(_ text: String) async {
    await sendInput(ClairTerminalPaste.encode(text, modes: modes))
  }

  public func sendFocus(_ focused: Bool) async {
    await sendInput(ClairTerminalFocus.encode(focused: focused, modes: modes))
  }

  public func sendMouse(
    _ button: ClairTerminalMouseButton, _ action: ClairTerminalMouseAction, column: Int, row: Int
  ) async {
    await sendInput(
      ClairTerminalMouse.encode(button, action, column: column, row: row, modes: modes))
  }

  /// Touch pan-to-scroll: shifts the local VT parser's viewport and
  /// publishes the resulting snapshot immediately (no round trip -- this is
  /// purely local render state, not a change to the remote PTY's geometry
  /// or the daemon's journal).
  public func scroll(byRows rows: Int) {
    try? terminal.scroll(byRows: rows)
    if let snapshot = try? terminal.snapshot() {
      onScreenUpdate?(snapshot)
    }
  }

  /// Plain-text content between two viewport points, for touch-selection
  /// copy. Purely local (the VT parser's own screen state); no network call.
  public func selectedText(
    from start: GhosttyVTViewportPoint, to end: GhosttyVTViewportPoint
  ) -> String? {
    try? terminal.selectedText(from: start, to: end)
  }

  private func startPump(on connection: ClairAuthenticatedConnection) {
    pumpTask = Task { [weak self] in
      while let self, !Task.isCancelled {
        guard await self.pumpOnce(on: connection) else { break }
      }
    }
  }

  /// One read/write/acknowledge cycle. Returns `false` when the pump should
  /// stop (detached concurrently, or a terminal error). A `nil` frame (no
  /// new bytes yet) backs off briefly instead of busy-polling.
  private func pumpOnce(on connection: ClairAuthenticatedConnection) async -> Bool {
    guard let attachment else { return false }
    do {
      guard let frame = try await transport.read(attachment, on: connection) else {
        try? await Task.sleep(nanoseconds: 50_000_000)
        return true
      }
      try terminal.write(frame.bytes)
      modes.feed(frame.bytes)
      try await transport.acknowledge(attachment, cursor: frame.nextCursor, on: connection)
      lastAcknowledgedCursor = frame.nextCursor
      if let snapshot = try? terminal.snapshot() {
        onScreenUpdate?(snapshot)
      }
      return true
    } catch {
      state = .failed
      return false
    }
  }
}

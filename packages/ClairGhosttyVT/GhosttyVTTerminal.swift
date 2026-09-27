#if CLAIR_GHOSTTY_VT_VENDORED
import ClairGhosttyVTABI
#endif
import Foundation

/// The terminal cursor's last-known position and visibility, read via
/// `ghostty_terminal_get`'s `CURSOR_X`/`CURSOR_Y`/`CURSOR_VISIBLE`.
public struct GhosttyVTCursor: Equatable, Sendable {
  public let column: Int
  public let row: Int
  public let visible: Bool
}

/// One rendered screen: the whole active screen (including scrollback rows
/// currently visible after a scroll) as plain-text lines, plus cursor
/// position and scrollback extent. `lines` is produced by
/// `ghostty_terminal_selection_format_alloc` over a `select_all()`
/// snapshot -- the same shape (an array of visible-line strings)
/// `ClairTerminalView`'s CoreText renderer draws one `CTLine` per
/// element of, mirroring how `EditorLineRenderer` (`ClairEditorView`)
/// consumes `TextSnapshot` lines.
public struct GhosttyVTScreenSnapshot: Equatable, Sendable {
  public let lines: [String]
  public let cursor: GhosttyVTCursor
  public let totalRows: Int
  public let scrollbackRows: Int
}

/// A cell position in the visible viewport (0-indexed column/row), used for
/// touch-selection endpoints. Viewport coordinates shift as the user
/// scrolls (`GHOSTTY_POINT_TAG_VIEWPORT`); this is deliberately not the
/// "active area" (cursor-relative) or absolute "screen" tag, because touch
/// selection targets whatever is currently on screen, scrolled or not.
public struct GhosttyVTViewportPoint: Equatable, Sendable {
  public let column: Int
  public let row: Int

  public init(column: Int, row: Int) {
    self.column = column
    self.row = row
  }
}

/// The Swift-concurrency boundary around libghostty-vt, mirroring
/// `GhosttyRuntime`/`GhosttySurfaceHandle` (`ClairGhostty`): libghostty's
/// terminal object is not thread-safe and is owned by whichever thread
/// creates it, so every method here is `@MainActor`-isolated, matching
/// `ClairTerminalView` (a `UIView`, itself main-thread-only). Unlike
/// `GhosttyRuntime`, there is no process-global `ghostty_init` step for
/// libghostty-vt (it is a pure state-machine library, not an app runtime);
/// `init` allocates the terminal directly.
///
/// No fallback terminal engine: absence of the vendored artifact
/// (`CLAIR_GHOSTTY_VT_VENDORED` not defined -- the expected state on every
/// non-iOS build, and any iOS build before `scripts/ghostty.sh
/// vendor-vt` has run) fails every call closed with
/// `GhosttyVTError.runtimeUnavailable`, never falling back to an
/// independently written ANSI/VT interpreter.
@MainActor
public final class GhosttyVTTerminal {
  #if CLAIR_GHOSTTY_VT_VENDORED
  private var handle: clair_ghostty_vt_terminal_t?
  #endif
  private var closed = false

  /// Whether this build was compiled against the vendored library for the
  /// current platform. `false` means every method throws
  /// `.runtimeUnavailable`. `nonisolated` for the same reason as
  /// `GhosttyRuntime.isVendored`: callers (including test skip traits)
  /// need it outside actor isolation.
  public nonisolated static var isVendored: Bool {
    #if CLAIR_GHOSTTY_VT_VENDORED
    return clair_ghostty_vt_abi_is_vendored() != 0
    #else
    return false
    #endif
  }

  /// Creates a terminal with the given cell grid size. `columns`/`rows`
  /// must both be positive (mirrors `ghostty_terminal_new`'s precondition,
  /// checked before the call so the failure is `.invalidValue` either way).
  public init(columns: Int, rows: Int) throws {
    guard columns > 0, rows > 0, columns <= .max, rows <= .max else {
      throw GhosttyVTError.invalidValue
    }
    guard Self.isVendored else { throw GhosttyVTError.runtimeUnavailable }
    #if CLAIR_GHOSTTY_VT_VENDORED
    var newHandle: clair_ghostty_vt_terminal_t?
    let result = clair_ghostty_vt_terminal_new(&newHandle, UInt16(columns), UInt16(rows))
    try GhosttyVTTerminal.check(result)
    self.handle = newHandle
    #endif
  }

  // `isolated deinit`, not plain `deinit`: a plain `deinit` on a
  // `@MainActor` class runs nonisolated in Swift 6 and cannot touch
  // `handle` (a non-`Sendable` C pointer). T03 hit and fixed the same
  // pattern for `ClairGhosttySurfaceView`'s handle/poll-timer cleanup;
  // this mirrors that fix.
  isolated deinit {
    #if CLAIR_GHOSTTY_VT_VENDORED
    if let handle {
      clair_ghostty_vt_terminal_free(handle)
    }
    #endif
  }

  /// Releases the underlying terminal early (e.g. on background detach) so
  /// its memory does not wait for Swift's deterministic-but-later `deinit`.
  /// Idempotent; every method after this throws `.runtimeUnavailable`.
  public func close() {
    guard !closed else { return }
    closed = true
    #if CLAIR_GHOSTTY_VT_VENDORED
    if let handle {
      clair_ghostty_vt_terminal_free(handle)
    }
    handle = nil
    #endif
  }

  /// Feeds raw PTY output bytes (T04's `ClairTerminalStream` frames)
  /// through the VT stream parser. Never fails: malformed input is
  /// tolerated the same way libghostty-vt itself documents
  /// `ghostty_terminal_vt_write` as never failing on untrusted input.
  public func write(_ bytes: Data) throws {
    #if CLAIR_GHOSTTY_VT_VENDORED
    let handle = try requireHandle()
    bytes.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      clair_ghostty_vt_terminal_write(handle, base, raw.count)
    }
    #else
    throw GhosttyVTError.runtimeUnavailable
    #endif
  }

  /// Resizes the cell grid. Desktop rows/columns are never implicitly
  /// changed by a mobile viewport (T06's invariant, already true here
  /// because this terminal is Clair's own local VT parser, not the
  /// daemon-owned PTY T04 streams from -- resizing this only changes how
  /// many of the streamed rows/columns this view renders at once, never
  /// the remote PTY geometry).
  public func resize(columns: Int, rows: Int) throws {
    guard columns > 0, rows > 0 else { throw GhosttyVTError.invalidValue }
    #if CLAIR_GHOSTTY_VT_VENDORED
    let handle = try requireHandle()
    // Cell pixel geometry only affects image-protocol/size-report math this
    // task's minimal UI does not use; 1x1 keeps it a harmless placeholder
    // rather than plumbing real font metrics through this call.
    try GhosttyVTTerminal.check(
      clair_ghostty_vt_terminal_resize(handle, UInt16(columns), UInt16(rows), 1, 1))
    #else
    throw GhosttyVTError.runtimeUnavailable
    #endif
  }

  /// Scrolls the viewport by `rows` (negative scrolls up into scrollback,
  /// positive scrolls down toward the active area), clamped by
  /// libghostty-vt to the available scrollback. Drives touch pan-to-scroll.
  public func scroll(byRows rows: Int) throws {
    #if CLAIR_GHOSTTY_VT_VENDORED
    let handle = try requireHandle()
    var behavior = clair_ghostty_vt_scroll_s()
    behavior.tag = CLAIR_GHOSTTY_VT_SCROLL_DELTA
    behavior.value = clair_ghostty_vt_scroll_value_u(delta: rows)
    clair_ghostty_vt_scroll_viewport(handle, behavior)
    #else
    throw GhosttyVTError.runtimeUnavailable
    #endif
  }

  /// Scrolls all the way back to the active area (bottom). Called on
  /// foreground reattach so a session resumed after backgrounding starts
  /// at the live output, not wherever a stale scroll offset left it.
  public func scrollToBottom() throws {
    #if CLAIR_GHOSTTY_VT_VENDORED
    let handle = try requireHandle()
    var behavior = clair_ghostty_vt_scroll_s()
    behavior.tag = CLAIR_GHOSTTY_VT_SCROLL_BOTTOM
    behavior.value = clair_ghostty_vt_scroll_value_u(delta: 0)
    clair_ghostty_vt_scroll_viewport(handle, behavior)
    #else
    throw GhosttyVTError.runtimeUnavailable
    #endif
  }

  /// The current full-screen render: every visible line as plain text plus
  /// cursor/scrollback metadata. Called once per render pass by
  /// `ClairTerminalView`, same "poll once per frame/write batch" pattern
  /// libghostty-vt's own `GHOSTTY_TERMINAL_DATA_SCROLLBAR` doc comment
  /// recommends for state with no change notification.
  public func snapshot() throws -> GhosttyVTScreenSnapshot {
    #if CLAIR_GHOSTTY_VT_VENDORED
    let handle = try requireHandle()

    var cursorX: UInt16 = 0
    try GhosttyVTTerminal.check(clair_ghostty_vt_cursor_x(handle, &cursorX))
    var cursorY: UInt16 = 0
    try GhosttyVTTerminal.check(clair_ghostty_vt_cursor_y(handle, &cursorY))
    var cursorVisible = false
    try GhosttyVTTerminal.check(clair_ghostty_vt_cursor_visible(handle, &cursorVisible))
    var totalRows: Int = 0
    try GhosttyVTTerminal.check(clair_ghostty_vt_total_rows(handle, &totalRows))
    var scrollbackRows: Int = 0
    try GhosttyVTTerminal.check(clair_ghostty_vt_scrollback_rows(handle, &scrollbackRows))

    var selection = clair_ghostty_vt_selection_s()
    try GhosttyVTTerminal.check(clair_ghostty_vt_select_all(handle, &selection))
    let text = try formatSelection(handle: handle, selection: selection, unwrap: false, trim: false)

    return GhosttyVTScreenSnapshot(
      lines: text.isEmpty ? [] : text.components(separatedBy: "\n"),
      cursor: GhosttyVTCursor(
        column: Int(cursorX), row: Int(cursorY), visible: cursorVisible),
      totalRows: totalRows, scrollbackRows: scrollbackRows)
    #else
    throw GhosttyVTError.runtimeUnavailable
    #endif
  }

  /// Formats the plain text between two viewport points (inclusive), in
  /// document order regardless of drag direction -- the caller (touch
  /// selection) does not need to pre-sort its start/end. `nil` when either
  /// endpoint is out of bounds or the range is empty.
  public func selectedText(
    from start: GhosttyVTViewportPoint, to end: GhosttyVTViewportPoint
  ) throws -> String? {
    #if CLAIR_GHOSTTY_VT_VENDORED
    let handle = try requireHandle()
    guard let startRef = try gridRef(atViewportColumn: start.column, row: start.row),
      let endRef = try gridRef(atViewportColumn: end.column, row: end.row)
    else { return nil }
    var selection = clair_ghostty_vt_selection_s()
    selection.size = MemoryLayout<clair_ghostty_vt_selection_s>.size
    selection.start = startRef
    selection.end = endRef
    selection.rectangle = false
    let text = try formatSelection(handle: handle, selection: selection, unwrap: true, trim: true)
    return text.isEmpty ? nil : text
    #else
    throw GhosttyVTError.runtimeUnavailable
    #endif
  }

  #if CLAIR_GHOSTTY_VT_VENDORED
  /// Resolves a viewport point to a grid reference, for building a
  /// touch-selection endpoint. `nil` when the point is out of bounds
  /// (`GHOSTTY_INVALID_VALUE`) rather than throwing: an out-of-bounds touch
  /// (e.g. a drag past the last line) is routine UI input, not an error.
  private func gridRef(atViewportColumn column: Int, row: Int) throws
    -> clair_ghostty_vt_grid_ref_s?
  {
    let handle = try requireHandle()
    guard column >= 0, row >= 0, column <= UInt16.max, row <= UInt32.max else { return nil }
    var point = clair_ghostty_vt_point_s()
    point.tag = CLAIR_GHOSTTY_VT_POINT_TAG_VIEWPORT
    point.value = clair_ghostty_vt_point_value_u(
      coordinate: clair_ghostty_vt_point_coordinate_s(x: UInt16(column), y: UInt32(row)))
    var ref = clair_ghostty_vt_grid_ref_s()
    let result = clair_ghostty_vt_grid_ref(handle, point, &ref)
    if result == CLAIR_GHOSTTY_VT_INVALID_VALUE { return nil }
    try GhosttyVTTerminal.check(result)
    return ref
  }

  private func formatSelection(
    handle: clair_ghostty_vt_terminal_t, selection: clair_ghostty_vt_selection_s, unwrap: Bool,
    trim: Bool
  ) throws -> String {
    var selection = selection
    var outPtr: UnsafeMutablePointer<UInt8>?
    var outLen: Int = 0
    let result = clair_ghostty_vt_format_selection_alloc(
      handle, &selection, unwrap, trim, &outPtr, &outLen)
    if result == CLAIR_GHOSTTY_VT_NO_VALUE { return "" }
    try GhosttyVTTerminal.check(result)
    guard let outPtr, outLen > 0 else { return "" }
    defer { clair_ghostty_vt_free(outPtr, outLen) }
    return String(decoding: UnsafeBufferPointer(start: outPtr, count: outLen), as: UTF8.self)
  }

  private func requireHandle() throws -> clair_ghostty_vt_terminal_t {
    guard !closed, let handle else { throw GhosttyVTError.runtimeUnavailable }
    return handle
  }

  private static func check(_ result: clair_ghostty_vt_result_e) throws {
    switch result {
    case CLAIR_GHOSTTY_VT_SUCCESS: return
    case CLAIR_GHOSTTY_VT_OUT_OF_MEMORY: throw GhosttyVTError.outOfMemory
    case CLAIR_GHOSTTY_VT_INVALID_VALUE: throw GhosttyVTError.invalidValue
    case CLAIR_GHOSTTY_VT_NO_VALUE: throw GhosttyVTError.noValue
    default: throw GhosttyVTError.unexpected(result.rawValue)
    }
  }
  #endif
}

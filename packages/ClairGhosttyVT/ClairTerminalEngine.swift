import Foundation

/// The subset of `GhosttyVTTerminal` `ClairMobileTerminalSession`
/// (`ClairMobileKit`) actually drives. Exists so the session's attach/
/// background-detach/foreground-reconnect/gap-resync state machine --
/// exactly the D5-risk logic this task needs real test coverage for -- can
/// be tested with an in-memory fake engine, since `GhosttyVTTerminal`
/// itself only runs where `GhosttyVT.xcframework` is actually vendored
/// (iOS device/simulator; never this repo's macOS development/CI hosts,
/// unlike `ClairGhostty`'s macOS embedder, which the T01/T08 precedent's
/// `.enabled(if: GhosttyRuntime.isVendored)` tests can at least sometimes
/// run for real). One protocol, one production conformance
/// (`GhosttyVTTerminal`), one test fake -- not a general-purpose
/// abstraction layer.
@MainActor
public protocol ClairTerminalEngine: AnyObject {
  func write(_ bytes: Data) throws
  func resize(columns: Int, rows: Int) throws
  func scrollToBottom() throws
  func scroll(byRows rows: Int) throws
  func snapshot() throws -> GhosttyVTScreenSnapshot
  func selectedText(from start: GhosttyVTViewportPoint, to end: GhosttyVTViewportPoint) throws
    -> String?
}

extension GhosttyVTTerminal: ClairTerminalEngine {}

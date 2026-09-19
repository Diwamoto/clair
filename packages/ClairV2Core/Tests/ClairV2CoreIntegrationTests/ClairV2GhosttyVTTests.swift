import ClairV2GhosttyVT
import Foundation
import XCTest

/// Mirrors `ClairV2GhosttyTests`' structure for the separate
/// `libghostty-vt` artifact (`ClairV2GhosttyVTABI`/`Config/ghostty-pin.json`'s
/// `libghostty_vt` block). Unlike `GhosttyKit.xcframework` (which has a
/// macos-arm64 slice, so `ClairV2GhosttyTests`' vendored-path test can run
/// on a macOS host that has vendored it), `GhosttyVT.xcframework` only has
/// iOS device/simulator slices (`Package.swift`'s `ghosttyVTVendored`
/// gating is `.when(platforms: [.iOS])`): `GhosttyVTTerminal.isVendored`
/// is unconditionally `false` on every macOS host, including one that has
/// run `scripts/v2-ghostty.sh vendor-vt`. This file's "not vendored" tests
/// therefore always run here; its vendored-path test only runs (and only
/// can run) on an iOS test host, which this repository's `swift test` /
/// `make test-swift` do not target today -- see the T05 worker report for
/// the explicit "not executed" disclosure this implies, the same kind
/// E07/E08 already recorded for their own iOS-only gaps.
final class ClairV2GhosttyVTTests: XCTestCase {
  private var isVendoredEnvironment: Bool { GhosttyVTTerminal.isVendored }

  @MainActor
  func testNotVendoredByDefaultOnThisHost() {
    XCTAssertFalse(GhosttyVTTerminal.isVendored)
  }

  @MainActor
  func testTerminalInitThrowsRuntimeUnavailableWithoutArtifact() throws {
    try XCTSkipIf(isVendoredEnvironment)
    XCTAssertThrowsError(try GhosttyVTTerminal(columns: 80, rows: 24)) { error in
      XCTAssertEqual(error as? GhosttyVTError, .runtimeUnavailable)
    }
  }

  @MainActor
  func testTerminalInitRejectsNonPositiveDimensionsBeforeCheckingVendored() throws {
    // Argument validation happens before the vendored check, so this holds
    // regardless of environment -- worth asserting explicitly since it is
    // the one path that must not depend on `isVendoredEnvironment`.
    XCTAssertThrowsError(try GhosttyVTTerminal(columns: 0, rows: 24)) { error in
      XCTAssertEqual(error as? GhosttyVTError, .invalidValue)
    }
    XCTAssertThrowsError(try GhosttyVTTerminal(columns: 80, rows: 0)) { error in
      XCTAssertEqual(error as? GhosttyVTError, .invalidValue)
    }
  }

  /// The vendored-path mirror of the tests above: on a real iOS test host
  /// with `GhosttyVT.xcframework` vendored, a terminal can be created,
  /// fed known VT bytes, and its parsed screen/cursor read back. Skipped
  /// (never failed) everywhere else, matching `ClairV2GhosttyTests`'
  /// pattern for its own vendored-only test.
  @MainActor
  func testKnownVTBytesRoundTripToParsedScreenAndCursor() throws {
    try XCTSkipUnless(isVendoredEnvironment)
    let terminal = try GhosttyVTTerminal(columns: 10, rows: 3)
    try terminal.write(Data("hi\r\n".utf8))
    let snapshot = try terminal.snapshot()
    XCTAssertEqual(snapshot.lines.first, "hi")
    XCTAssertEqual(snapshot.cursor.row, 1)
    XCTAssertEqual(snapshot.cursor.column, 0)
    XCTAssertTrue(snapshot.cursor.visible)
  }
}

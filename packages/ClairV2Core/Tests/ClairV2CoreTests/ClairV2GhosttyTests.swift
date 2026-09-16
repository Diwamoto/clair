import ClairV2Ghostty
import XCTest

#if os(macOS)
  import AppKit
#endif

@MainActor
final class ClairV2GhosttyTests: XCTestCase {
  /// Whether this build is compiled against and linked to a real,
  /// materialized vendor artifact. `scripts/v2-ghostty.sh vendor` has not
  /// run on most machines that check out this repository, so most of this
  /// file's tests exercise the (default, expected) "not vendored" failure
  /// path. `testFullSurfaceEmbeddingRoundTripsKnownOutput` below is the one
  /// test that only runs, and only can meaningfully run, when this is true.
  private var isVendoredEnvironment: Bool { GhosttyRuntime.isVendored }

  func testBuildIsNotVendoredByDefault() throws {
    try XCTSkipIf(
      isVendoredEnvironment,
      "This machine has vendored libghostty (scripts/v2-ghostty.sh vendor); "
        + "see testFullSurfaceEmbeddingRoundTripsKnownOutput for the vendored-path coverage.")
    XCTAssertFalse(GhosttyRuntime.isVendored)
  }

  func testActivationThrowsRuntimeUnavailableWithoutArtifact() throws {
    try XCTSkipIf(isVendoredEnvironment)
    let runtime = GhosttyRuntime()
    XCTAssertThrowsError(try runtime.activate()) { error in
      guard case GhosttyError.runtimeUnavailable = error else {
        XCTFail("Expected runtimeUnavailable, got \(error)")
        return
      }
    }
  }

  func testRepeatedActivationReturnsSameFailure() throws {
    try XCTSkipIf(isVendoredEnvironment)
    let runtime = GhosttyRuntime()
    XCTAssertThrowsError(try runtime.activate()) { error in
      XCTAssertEqual(error as? GhosttyError, .runtimeUnavailable)
    }
    XCTAssertThrowsError(try runtime.activate()) { error in
      XCTAssertEqual(error as? GhosttyError, .runtimeUnavailable)
    }
  }

  /// The vendored-path mirror of `testRepeatedActivationReturnsSameFailure`:
  /// on a machine that has actually vendored libghostty, `activate()` must
  /// succeed, and a second call must be a no-op success (T01's invariant:
  /// `ghostty_init` runs at most once per process), not a re-attempt.
  func testRepeatedActivationSucceedsOnceVendored() throws {
    try XCTSkipUnless(isVendoredEnvironment)
    let runtime = GhosttyRuntime()
    try runtime.activate()
    try runtime.activate()
  }

  func testInfoRequiresActivation() {
    let runtime = GhosttyRuntime()
    XCTAssertThrowsError(try runtime.info()) { error in
      XCTAssertEqual(error as? GhosttyError, .notActivated)
    }
  }

  func testConfigRequiresActivation() {
    let runtime = GhosttyRuntime()
    XCTAssertThrowsError(try runtime.withConfig { _ in 42 }) { error in
      XCTAssertEqual(error as? GhosttyError, .notActivated)
    }
  }

  func testErrorEquatable() {
    XCTAssertEqual(GhosttyError.runtimeUnavailable, .runtimeUnavailable)
    XCTAssertNotEqual(GhosttyError.runtimeUnavailable, .notActivated)
  }

  func testGhosttyPinMatchesManifest() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // ClairV2GhosttyTests.swift
      .deletingLastPathComponent() // ClairV2CoreTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // ClairV2Core
      .deletingLastPathComponent() // packages
    let pinURL = repoRoot.appendingPathComponent("Config/ghostty-pin.json")
    let data = try Data(contentsOf: pinURL)
    let pin = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertNotNil(pin)
    XCTAssertEqual(GhosttyPin.upstreamRepository, pin?["upstream"] as? String)
    XCTAssertEqual(GhosttyPin.pinnedCommit, pin?["commit"] as? String)
    XCTAssertEqual(GhosttyPin.licenseSPDXIdentifier, pin?["license"] as? String)
    XCTAssertEqual(GhosttyPin.licenseCopyright, pin?["copyright"] as? String)
    if let toolchain = pin?["toolchain"] as? [String: Any] {
      XCTAssertEqual(GhosttyPin.toolchainName, toolchain["name"] as? String)
      XCTAssertEqual(GhosttyPin.toolchainVersion, toolchain["version"] as? String)
    } else {
      XCTFail("toolchain section missing")
    }
    if let build = pin?["build"] as? [String: Any] {
      XCTAssertEqual(GhosttyPin.buildMode, build["mode"] as? String)
      XCTAssertEqual(GhosttyPin.xcframeworkName, build["artifact"] as? String)
    } else {
      XCTFail("build section missing")
    }
  }

  #if os(macOS)
    /// T08's acceptance smoke test: a real `ghostty_app_t` + real
    /// `ghostty_surface_t` backed by a real (offscreen) `NSView`, with
    /// libghostty spawning and running its own real `/bin/sh` child
    /// process for that surface (see `GhosttySurfaceConfig`'s doc comment
    /// for why this — not writing bytes into an externally-owned PTY — is
    /// what "feed known PTY output into a surface" means at this ABI
    /// layer). Ticks the app's event loop until the real known output the
    /// spawned shell printed shows up in a real `readText(.screen)` call,
    /// then separately checks `.cursor` and `size()` as the closest
    /// verifiable equivalents to a direct cursor-grid readback this
    /// internal embedder API exposes.
    func testFullSurfaceEmbeddingRoundTripsKnownOutput() throws {
      try XCTSkipUnless(isVendoredEnvironment)

      let runtime = GhosttyRuntime()
      try runtime.activate()

      let marker = "CLAIRT08HELLO-\(UUID().uuidString.prefix(8))"
      let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
      view.wantsLayer = true

      try runtime.withApp { app in
        try app.withSurface(
          GhosttySurfaceConfig(
            platform: .macOS(Unmanaged.passUnretained(view).toOpaque()),
            workingDirectory: NSTemporaryDirectory(),
            command: "/bin/sh",
            initialInput: "printf '\(marker)\\n'\n"
          )
        ) { surface in
          try surface.setSize(widthPixels: 640, heightPixels: 400)

          var found = false
          for _ in 0..<100 {
            try app.tick()
            Thread.sleep(forTimeInterval: 0.05)
            if let text = try surface.readText(.screen), text.contains(marker) {
              found = true
              break
            }
          }
          XCTAssertTrue(found, "expected known PTY output '\(marker)' in the rendered screen text")

          let size = try surface.size()
          XCTAssertGreaterThan(size.columns, 0)
          XCTAssertGreaterThan(size.rows, 0)
          XCTAssertGreaterThan(size.cellWidthPixels, 0)
          XCTAssertGreaterThan(size.cellHeightPixels, 0)

          // Cursor-relative readback: not asserted for exact content (the
          // shell prompt state at this point is not fully deterministic),
          // only that the call itself is a real, safe round trip and does
          // not throw.
          _ = try surface.readText(.cursor)
        }
      }
    }
  #endif

  func testResourcesAreMissingBeforeVendor() {
    XCTAssertThrowsError(try GhosttyResources.terminfoDatabaseURL()) { error in
      guard case GhosttyError.resourceMissing = error else {
        XCTFail("Expected resourceMissing, got \(error)")
        return
      }
    }
  }
}

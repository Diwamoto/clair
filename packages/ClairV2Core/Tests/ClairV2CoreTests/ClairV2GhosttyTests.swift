import ClairV2Ghostty
import XCTest

@MainActor
final class ClairV2GhosttyTests: XCTestCase {
  func testBuildIsNotVendoredByDefault() {
    XCTAssertFalse(GhosttyRuntime.isVendored)
  }

  func testActivationThrowsRuntimeUnavailableWithoutArtifact() {
    let runtime = GhosttyRuntime()
    XCTAssertThrowsError(try runtime.activate()) { error in
      guard case GhosttyError.runtimeUnavailable = error else {
        XCTFail("Expected runtimeUnavailable, got \(error)")
        return
      }
    }
  }

  func testRepeatedActivationReturnsSameFailure() {
    let runtime = GhosttyRuntime()
    XCTAssertThrowsError(try runtime.activate()) { error in
      XCTAssertEqual(error as? GhosttyError, .runtimeUnavailable)
    }
    XCTAssertThrowsError(try runtime.activate()) { error in
      XCTAssertEqual(error as? GhosttyError, .runtimeUnavailable)
    }
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

  func testResourcesAreMissingBeforeVendor() {
    XCTAssertThrowsError(try GhosttyResources.terminfoDatabaseURL()) { error in
      guard case GhosttyError.resourceMissing = error else {
        XCTFail("Expected resourceMissing, got \(error)")
        return
      }
    }
  }
}

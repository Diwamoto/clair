import Foundation
import XCTest

@testable import ClairApp

final class ClairRuntimeProfileTests: XCTestCase {
  func testStableAndDevIdentitiesAreDisjoint() {
    XCTAssertEqual(ClairRuntimeProfile.all.count, 2)
    XCTAssertNotEqual(
      ClairRuntimeProfile.stable.bundleIdentifier, ClairRuntimeProfile.dev.bundleIdentifier)
    XCTAssertNotEqual(ClairRuntimeProfile.stable.displayName, ClairRuntimeProfile.dev.displayName)
    XCTAssertNotEqual(
      ClairRuntimeProfile.stable.applicationSupportDirectoryName,
      ClairRuntimeProfile.dev.applicationSupportDirectoryName
    )
    XCTAssertNotEqual(
      ClairRuntimeProfile.stable.preferencesDomain,
      ClairRuntimeProfile.dev.preferencesDomain
    )
  }

  func testApplicationSupportPathsUseChannelDirectory() {
    let root = URL(fileURLWithPath: "/tmp/clair-profile-test", isDirectory: true)

    XCTAssertEqual(
      ClairRuntimeProfile.stable.applicationSupportURL(baseDirectory: root).path,
      "/tmp/clair-profile-test/Clair"
    )
    XCTAssertEqual(
      ClairRuntimeProfile.dev.applicationSupportURL(baseDirectory: root).path,
      "/tmp/clair-profile-test/Clair Dev"
    )
  }

  func testPreferencesDomainsDoNotShareValues() throws {
    let key = "ClairRuntimeProfileTests.\(UUID().uuidString)"
    let stableDefaults = try XCTUnwrap(
      UserDefaults(suiteName: ClairRuntimeProfile.stable.preferencesDomain))
    let devDefaults = UserDefaults.standard
    defer {
      stableDefaults.removeObject(forKey: key)
      devDefaults.removeObject(forKey: key)
    }

    XCTAssertEqual(Bundle.main.bundleIdentifier, ClairRuntimeProfile.dev.bundleIdentifier)

    stableDefaults.set("stable", forKey: key)

    XCTAssertEqual(stableDefaults.string(forKey: key), "stable")
    XCTAssertNil(devDefaults.object(forKey: key))

    devDefaults.set("dev", forKey: key)

    XCTAssertEqual(stableDefaults.string(forKey: key), "stable")
    XCTAssertEqual(devDefaults.string(forKey: key), "dev")
  }

  func testApplicationSupportDirectoryCanBeCreated() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let dataURL = ClairRuntimeProfile.dev.applicationSupportURL(baseDirectory: root)
    defer { try? FileManager.default.removeItem(at: root) }

    try BootstrapState.ensureApplicationSupportDirectory(at: dataURL)

    var isDirectory = ObjCBool(false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: dataURL.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
  }

  func testMissingApplicationSupportLocationIsReportedWithoutFallback() {
    let state = BootstrapState.load(
      profile: .dev,
      bundleIdentifier: ClairRuntimeProfile.dev.bundleIdentifier,
      applicationSupportBaseDirectory: nil
    )

    XCTAssertNil(state.applicationSupportURL)
    XCTAssertEqual(state.errorMessage, "Application Support location is unavailable")
  }

  func testRustCoreSmokeCall() {
    XCTAssertEqual(RustCore.smokeValue(), RustCore.expectedSmokeValue)
    XCTAssertEqual(RustCore.smokeValue(), 0x434C_4149)
  }
}

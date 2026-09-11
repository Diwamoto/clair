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
    XCTAssertEqual(RustCore.smokeValue(), 0x434C_4149)
  }
}

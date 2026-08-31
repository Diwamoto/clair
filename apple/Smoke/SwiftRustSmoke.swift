import Foundation

@main
enum SwiftRustSmoke {
  static func main() {
    let profile = ClairRuntimeProfile.current
    validateRuntimeProfiles()
    validateApplicationSupportCreation()

    let expected: UInt32 = 0x434C_4149
    let actual = clair_core_smoke()

    precondition(
      actual == expected,
      String(format: "Rust smoke mismatch: expected 0x%08X, got 0x%08X", expected, actual)
    )
    print(
      String(
        format: "swift-rust channel=%@ bundle=%@ smoke=ok value=0x%08X",
        profile.channel.rawValue,
        profile.bundleIdentifier,
        actual
      )
    )
  }

  private static func validateRuntimeProfiles() {
    let stable = ClairRuntimeProfile.stable
    let dev = ClairRuntimeProfile.dev
    let base = URL(fileURLWithPath: "/tmp/clair-profile-smoke", isDirectory: true)

    precondition(stable.bundleIdentifier == "com.diwamoto.clair")
    precondition(dev.bundleIdentifier == "com.diwamoto.clair.dev")
    precondition(stable.bundleIdentifier != dev.bundleIdentifier)
    precondition(stable.displayName != dev.displayName)
    precondition(stable.preferencesDomain != dev.preferencesDomain)
    precondition(
      stable.applicationSupportURL(baseDirectory: base)
        != dev.applicationSupportURL(baseDirectory: base)
    )
  }

  private static func validateApplicationSupportCreation() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
      for profile in ClairRuntimeProfile.all {
        let dataURL = profile.applicationSupportURL(baseDirectory: root)
        try BootstrapState.ensureApplicationSupportDirectory(at: dataURL)

        var isDirectory = ObjCBool(false)
        precondition(
          FileManager.default.fileExists(atPath: dataURL.path, isDirectory: &isDirectory)
        )
        precondition(isDirectory.boolValue)
      }
    } catch {
      preconditionFailure("Application Support creation failed: \(error)")
    }
  }
}

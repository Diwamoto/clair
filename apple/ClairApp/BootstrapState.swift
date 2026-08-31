import Foundation

struct BootstrapState: Equatable, Sendable {
  let profile: ClairRuntimeProfile
  let applicationSupportURL: URL?
  let rustSmokeValue: UInt32
  let errorMessage: String?

  var rustSmokeSucceeded: Bool {
    rustSmokeValue == RustCore.expectedSmokeValue
  }

  static func load(
    profile: ClairRuntimeProfile = .current,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    applicationSupportBaseDirectory: URL? = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first,
    fileManager: FileManager = .default
  ) -> BootstrapState {
    let dataURL = applicationSupportBaseDirectory.map(profile.applicationSupportURL)
    let smokeValue = RustCore.smokeValue()
    var errors: [String] = []

    if bundleIdentifier != profile.bundleIdentifier {
      errors.append(
        "Bundle identifier mismatch: expected \(profile.bundleIdentifier), "
          + "got \(bundleIdentifier ?? "nil")"
      )
    }

    if let dataURL {
      do {
        try ensureApplicationSupportDirectory(at: dataURL, fileManager: fileManager)
      } catch {
        errors.append("Application Support setup failed: \(error.localizedDescription)")
      }
    } else {
      errors.append("Application Support location is unavailable")
    }

    if smokeValue != RustCore.expectedSmokeValue {
      errors.append(
        String(
          format: "Rust smoke mismatch: expected 0x%08X, got 0x%08X",
          RustCore.expectedSmokeValue,
          smokeValue
        )
      )
    }

    return BootstrapState(
      profile: profile,
      applicationSupportURL: dataURL,
      rustSmokeValue: smokeValue,
      errorMessage: errors.isEmpty ? nil : errors.joined(separator: "\n")
    )
  }

  static func ensureApplicationSupportDirectory(
    at url: URL,
    fileManager: FileManager = .default
  ) throws {
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: nil
    )
  }
}

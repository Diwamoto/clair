import Foundation

enum ClairChannel: String, CaseIterable, Sendable {
  case stable
  case dev
}

struct ClairRuntimeProfile: Equatable, Sendable {
  let channel: ClairChannel
  let bundleIdentifier: String
  let displayName: String
  let applicationSupportDirectoryName: String

  static let stable = ClairRuntimeProfile(
    channel: .stable,
    bundleIdentifier: "com.diwamoto.clair",
    displayName: "Clair",
    applicationSupportDirectoryName: "Clair"
  )

  static let dev = ClairRuntimeProfile(
    channel: .dev,
    bundleIdentifier: "com.diwamoto.clair.dev",
    displayName: "Clair Dev",
    applicationSupportDirectoryName: "Clair Dev"
  )

  static let all: [ClairRuntimeProfile] = [.stable, .dev]

  static var current: ClairRuntimeProfile {
    #if CLAIR_STABLE && CLAIR_DEV
      #error("Exactly one Clair channel compile condition must be set")
    #elseif CLAIR_STABLE
      return .stable
    #elseif CLAIR_DEV
      return .dev
    #else
      #error("A Clair channel compile condition must be set")
    #endif
  }

  var preferencesDomain: String {
    bundleIdentifier
  }

  func applicationSupportURL(baseDirectory: URL) -> URL {
    baseDirectory.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
  }
}

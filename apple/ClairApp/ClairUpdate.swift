import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI

enum ClairUpdateError: Error, Equatable, LocalizedError, Sendable {
  case updaterUnavailable(String)
  case invalidManifest(String)
  case invalidVersion(String)
  case unsupportedChannel(String)
  case unsupportedArchitecture(String)
  case updateNotNewer(current: String, available: String)
  case invalidSignature
  case invalidHash(expected: String, actual: String)
  case network(String)
  case installFailed(String)

  var errorDescription: String? {
    switch self {
    case .updaterUnavailable(let message):
      message
    case .invalidManifest(let message):
      "The update manifest is invalid: \(message)"
    case .invalidVersion(let version):
      "The update version is invalid: \(version)"
    case .unsupportedChannel(let channel):
      "The update channel is not supported: \(channel)"
    case .unsupportedArchitecture(let architecture):
      "The update architecture is not supported: \(architecture)"
    case .updateNotNewer(let current, let available):
      "The available version \(available) is not newer than \(current)."
    case .invalidSignature:
      "The update signature could not be verified."
    case .invalidHash(let expected, let actual):
      "The downloaded update hash did not match (expected \(expected), got \(actual))."
    case .network(let message):
      "The update server could not be reached: \(message)"
    case .installFailed(let message):
      "The update could not be installed: \(message)"
    }
  }
}

struct ClairVersion: Comparable, Equatable, Sendable {
  let rawValue: String
  private let components: [Int]

  init(_ rawValue: String) throws {
    let normalized = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
    let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 4 else {
      throw ClairUpdateError.invalidVersion(rawValue)
    }

    var parsed: [Int] = []
    for part in parts {
      guard !part.isEmpty, let number = Int(part), number >= 0 else {
        throw ClairUpdateError.invalidVersion(rawValue)
      }
      parsed.append(number)
    }

    self.rawValue = normalized
    self.components = parsed
  }

  static func < (lhs: ClairVersion, rhs: ClairVersion) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for index in 0..<count {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right {
        return left < right
      }
    }
    return false
  }
}

struct ClairUpdateArtifact: Codable, Equatable, Sendable {
  let platform: String
  let architecture: String
  let url: URL
  let sha256: String
  let signature: String

  var normalizedSHA256: String {
    sha256.lowercased()
  }
}

struct ClairUpdateManifest: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let channel: ClairChannel
  let version: String
  let artifacts: [ClairUpdateArtifact]
  let notes: String?

  func makeUpdate(
    currentVersion: String,
    architecture: String,
    verifier: ClairUpdateSignatureVerifier
  ) throws -> ClairUpdate {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw ClairUpdateError.invalidManifest("unsupported schema version \(schemaVersion)")
    }
    guard channel == .stable else {
      throw ClairUpdateError.unsupportedChannel(channel.rawValue)
    }

    let current = try ClairVersion(currentVersion)
    let available = try ClairVersion(version)
    guard current < available else {
      throw ClairUpdateError.updateNotNewer(
        current: current.rawValue,
        available: available.rawValue
      )
    }

    guard
      let artifact = artifacts.first(where: {
        $0.platform == "macos" && $0.architecture == architecture
      })
    else {
      throw ClairUpdateError.unsupportedArchitecture(architecture)
    }
    guard artifact.url.scheme?.lowercased() == "https",
      artifact.url.host?.lowercased() == "github.com"
    else {
      throw ClairUpdateError.invalidManifest("artifact URL must be an HTTPS GitHub URL")
    }
    guard Self.isSHA256(artifact.normalizedSHA256) else {
      throw ClairUpdateError.invalidManifest(
        "artifact SHA-256 must contain 64 hexadecimal characters")
    }
    guard verifier.verify(manifest: self, artifact: artifact) else {
      throw ClairUpdateError.invalidSignature
    }

    return ClairUpdate(
      manifest: self,
      artifact: artifact,
      currentVersion: current.rawValue
    )
  }

  static func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57)
          || (scalar.value >= 65 && scalar.value <= 70)
          || (scalar.value >= 97 && scalar.value <= 102)
      }
  }
}

struct ClairUpdate: Equatable, Sendable {
  let manifest: ClairUpdateManifest
  let artifact: ClairUpdateArtifact
  let currentVersion: String

  var version: String {
    manifest.version
  }

  var notes: String? {
    manifest.notes
  }
}

struct ClairUpdateSignatureVerifier: Sendable {
  private let publicKey: Curve25519.Signing.PublicKey

  init(base64EncodedPublicKey: String) throws {
    guard let rawRepresentation = Data(base64Encoded: base64EncodedPublicKey) else {
      throw ClairUpdateError.invalidManifest("the embedded public key is not base64")
    }
    do {
      publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawRepresentation)
    } catch {
      throw ClairUpdateError.invalidManifest("the embedded public key is not Ed25519")
    }
  }

  func verify(
    manifest: ClairUpdateManifest,
    artifact: ClairUpdateArtifact
  ) -> Bool {
    guard let signature = Data(base64Encoded: artifact.signature) else {
      return false
    }
    return publicKey.isValidSignature(
      signature,
      for: Self.signedPayload(manifest: manifest, artifact: artifact)
    )
  }

  static func signedPayload(
    manifest: ClairUpdateManifest,
    artifact: ClairUpdateArtifact
  ) -> Data {
    let value =
      [
        "clair-update-v1",
        manifest.channel.rawValue,
        manifest.version,
        artifact.platform,
        artifact.architecture,
        artifact.url.absoluteString,
        artifact.normalizedSHA256,
      ].joined(separator: "\n") + "\n"
    return Data(value.utf8)
  }
}

struct ClairUpdateConfiguration: Equatable, Sendable {
  static let defaultManifestURL = URL(
    string: "https://github.com/Diwamoto/clair/releases/latest/download/latest.json"
  )!
  static let defaultInstallURL = URL(fileURLWithPath: "/Applications/Clair.app", isDirectory: true)

  let channel: ClairChannel
  let manifestURL: URL?
  let publicKeyBase64: String?
  let currentVersion: String
  let bundleIdentifier: String
  let currentAppURL: URL
  let installURL: URL
  let applicationSupportURL: URL?
  let architecture: String

  var isInstalledAtExpectedPath: Bool {
    currentAppURL.standardizedFileURL.path == installURL.standardizedFileURL.path
  }

  static func live(
    profile: ClairRuntimeProfile,
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) -> ClairUpdateConfiguration {
    let endpoint: URL?
    let publicKey: String?
    if profile.channel == .stable {
      let endpointString = stringValue(
        bundle.object(forInfoDictionaryKey: "ClairUpdateManifestURL")
      )
      endpoint = URL(string: endpointString ?? defaultManifestURL.absoluteString)
      publicKey = stringValue(bundle.object(forInfoDictionaryKey: "ClairUpdatePublicKey"))
    } else {
      endpoint = nil
      publicKey = nil
    }

    let baseDirectory = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    let applicationSupportURL = baseDirectory.map(profile.applicationSupportURL)
    let currentVersion =
      stringValue(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")) ?? "0.0.0"
    let bundleIdentifier = bundle.bundleIdentifier ?? profile.bundleIdentifier

    return ClairUpdateConfiguration(
      channel: profile.channel,
      manifestURL: endpoint,
      publicKeyBase64: publicKey,
      currentVersion: currentVersion,
      bundleIdentifier: bundleIdentifier,
      currentAppURL: bundle.bundleURL,
      installURL: defaultInstallURL,
      applicationSupportURL: applicationSupportURL,
      architecture: currentArchitecture
    )
  }

  private static func stringValue(_ value: Any?) -> String? {
    guard let value = value as? String else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static var currentArchitecture: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }
}

enum ClairUpdateState: Equatable, Sendable {
  case disabled(String)
  case idle
  case checking(manual: Bool)
  case available(ClairUpdate)
  case downloading(ClairUpdate)
  case installing(ClairUpdate)
  case failed(String)

  var isBusy: Bool {
    switch self {
    case .checking, .downloading, .installing:
      true
    case .disabled, .idle, .available, .failed:
      false
    }
  }
}

enum ClairUpdateHasher {
  static func sha256(of fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

struct ClairPendingUpdate: Codable, Equatable, Sendable {
  let version: String
  let bundleIdentifier: String
}

enum ClairUpdateRecovery {
  static let directoryName = "updates-v1"
  static let pendingFileName = "pending.json"
  static let successFileName = "startup-success.txt"

  static func directory(for applicationSupportURL: URL) -> URL {
    applicationSupportURL.appendingPathComponent(directoryName, isDirectory: true)
  }

  static func pendingURL(for applicationSupportURL: URL) -> URL {
    directory(for: applicationSupportURL).appendingPathComponent(pendingFileName)
  }

  static func successURL(for applicationSupportURL: URL) -> URL {
    directory(for: applicationSupportURL).appendingPathComponent(successFileName)
  }

  static func recordPending(
    version: String,
    bundleIdentifier: String,
    applicationSupportURL: URL,
    fileManager: FileManager = .default
  ) throws {
    let directory = directory(for: applicationSupportURL)
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? fileManager.removeItem(at: successURL(for: applicationSupportURL))
    let marker = ClairPendingUpdate(version: version, bundleIdentifier: bundleIdentifier)
    let data = try JSONEncoder().encode(marker)
    try data.write(to: pendingURL(for: applicationSupportURL), options: [.atomic])
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: pendingURL(for: applicationSupportURL).path
    )
  }

  @discardableResult
  static func markSuccessfulLaunchIfNeeded(
    profile: ClairRuntimeProfile,
    bundle: Bundle = .main,
    applicationSupportURL: URL?,
    fileManager: FileManager = .default
  ) -> Bool {
    markSuccessfulLaunchIfNeeded(
      profile: profile,
      bundleIdentifier: bundle.bundleIdentifier,
      version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      applicationSupportURL: applicationSupportURL,
      fileManager: fileManager
    )
  }

  @discardableResult
  static func markSuccessfulLaunchIfNeeded(
    profile: ClairRuntimeProfile,
    bundleIdentifier: String?,
    version: String?,
    applicationSupportURL: URL?,
    fileManager: FileManager = .default
  ) -> Bool {
    guard profile.channel == .stable, let applicationSupportURL else {
      return false
    }
    let pending = pendingURL(for: applicationSupportURL)
    guard
      let data = try? Data(contentsOf: pending),
      let marker = try? JSONDecoder().decode(ClairPendingUpdate.self, from: data),
      bundleIdentifier == marker.bundleIdentifier,
      version == marker.version
    else {
      return false
    }

    let directory = directory(for: applicationSupportURL)
    try? fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? Data(marker.version.utf8).write(
      to: successURL(for: applicationSupportURL),
      options: [.atomic]
    )
    return fileManager.fileExists(atPath: successURL(for: applicationSupportURL).path)
  }

  static func removeMarkers(
    applicationSupportURL: URL,
    fileManager: FileManager = .default
  ) {
    try? fileManager.removeItem(at: pendingURL(for: applicationSupportURL))
    try? fileManager.removeItem(at: successURL(for: applicationSupportURL))
  }
}

struct ClairUpdateInstaller {
  let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func stageArchive(
    at archiveURL: URL,
    update: ClairUpdate,
    configuration: ClairUpdateConfiguration
  ) throws -> URL {
    guard let applicationSupportURL = configuration.applicationSupportURL else {
      throw ClairUpdateError.installFailed("Application Support is unavailable")
    }
    guard fileManager.fileExists(atPath: archiveURL.path) else {
      throw ClairUpdateError.installFailed("the downloaded archive is missing")
    }

    let updateDirectory = ClairUpdateRecovery.directory(for: applicationSupportURL)
    try fileManager.createDirectory(
      at: updateDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let stagingDirectory = updateDirectory.appendingPathComponent(
      "staging-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: stagingDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    do {
      try run(
        executable: "/usr/bin/ditto",
        arguments: ["-x", "-k", archiveURL.path, stagingDirectory.path]
      )
      let appBundles = try fileManager.contentsOfDirectory(
        at: stagingDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ).filter { $0.pathExtension == "app" }
      guard appBundles.count == 1, let appURL = appBundles.first else {
        throw ClairUpdateError.installFailed("the archive must contain exactly one app bundle")
      }
      guard let bundle = Bundle(url: appURL) else {
        throw ClairUpdateError.installFailed("the staged app bundle is unreadable")
      }
      guard bundle.bundleIdentifier == configuration.bundleIdentifier else {
        throw ClairUpdateError.installFailed("the staged bundle identifier does not match Stable")
      }
      guard
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          == update.version
      else {
        throw ClairUpdateError.installFailed("the staged app version does not match the manifest")
      }
      return appURL
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      if let error = error as? ClairUpdateError {
        throw error
      }
      throw ClairUpdateError.installFailed(error.localizedDescription)
    }
  }

  func scheduleRestart(
    stagedAppURL: URL,
    update: ClairUpdate,
    configuration: ClairUpdateConfiguration,
    currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
  ) throws {
    guard configuration.isInstalledAtExpectedPath else {
      throw ClairUpdateError.installFailed(
        "Stable must be installed at \(configuration.installURL.path)"
      )
    }
    guard fileManager.fileExists(atPath: configuration.installURL.path) else {
      throw ClairUpdateError.installFailed("the installed Stable app is missing")
    }
    guard fileManager.fileExists(atPath: stagedAppURL.path) else {
      throw ClairUpdateError.installFailed("the staged app bundle is missing")
    }
    guard let applicationSupportURL = configuration.applicationSupportURL else {
      throw ClairUpdateError.installFailed("Application Support is unavailable")
    }

    let updateDirectory = ClairUpdateRecovery.directory(for: applicationSupportURL)
    try fileManager.createDirectory(
      at: updateDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let pendingURL = ClairUpdateRecovery.pendingURL(for: applicationSupportURL)
    guard !fileManager.fileExists(atPath: pendingURL.path) else {
      throw ClairUpdateError.installFailed("another update is already in progress")
    }

    let backupURL = updateDirectory.appendingPathComponent(
      "backup-\(UUID().uuidString).app",
      isDirectory: true
    )
    let scriptURL = updateDirectory.appendingPathComponent(
      "helper-\(UUID().uuidString).sh",
      isDirectory: false
    )
    let successURL = ClairUpdateRecovery.successURL(for: applicationSupportURL)
    try ClairUpdateRecovery.recordPending(
      version: update.version,
      bundleIdentifier: configuration.bundleIdentifier,
      applicationSupportURL: applicationSupportURL,
      fileManager: fileManager
    )

    do {
      try Data(Self.helperScript.utf8).write(to: scriptURL, options: [.atomic])
      try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: scriptURL.path
      )

      let helper = Process()
      helper.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
      helper.arguments = [
        "/bin/sh",
        scriptURL.path,
        String(currentProcessID),
        configuration.installURL.path,
        stagedAppURL.path,
        backupURL.path,
        successURL.path,
        pendingURL.path,
        update.version,
      ]
      helper.standardInput = FileHandle.nullDevice
      helper.standardOutput = FileHandle.nullDevice
      helper.standardError = FileHandle.nullDevice
      try helper.run()
    } catch {
      ClairUpdateRecovery.removeMarkers(
        applicationSupportURL: applicationSupportURL,
        fileManager: fileManager
      )
      try? fileManager.removeItem(at: scriptURL)
      throw ClairUpdateError.installFailed(error.localizedDescription)
    }
  }

  static let helperScript = #"""
    #!/bin/sh
    set -eu

    current_pid="$1"
    current_app="$2"
    staged_app="$3"
    backup_app="$4"
    success_marker="$5"
    pending_marker="$6"
    expected_version="$7"
    script_path="$0"
    staging_directory="${staged_app%/*}"
    old_moved=0
    new_moved=0

    cleanup_staging() {
      /bin/rm -rf -- "$staging_directory" 2>/dev/null || true
    }

    rollback() {
      status=$?
      if [ "$old_moved" -eq 1 ]; then
        if [ "$new_moved" -eq 1 ]; then
          for pid in $(/usr/bin/pgrep -x Clair 2>/dev/null || true); do
            /bin/kill "$pid" 2>/dev/null || true
          done
          /bin/sleep 0.5
          /bin/rm -rf -- "$current_app" 2>/dev/null || true
        fi
        /bin/mv -- "$backup_app" "$current_app" 2>/dev/null || true
        /usr/bin/open -n "$current_app" >/dev/null 2>&1 || true
      fi
      /bin/rm -f -- "$pending_marker" "$success_marker" 2>/dev/null || true
      cleanup_staging
      /bin/rm -f -- "$script_path" 2>/dev/null || true
      exit "$status"
    }

    trap rollback 0

    wait_count=0
    while /bin/kill -0 "$current_pid" 2>/dev/null; do
      if [ "$wait_count" -ge 150 ]; then
        exit 1
      fi
      /bin/sleep 0.2
      wait_count=$((wait_count + 1))
    done

    /bin/mv -- "$current_app" "$backup_app"
    old_moved=1
    /bin/mv -- "$staged_app" "$current_app"
    new_moved=1
    /usr/bin/open -n "$current_app" >/dev/null 2>&1

    wait_count=0
    while [ "$wait_count" -lt 150 ]; do
      if [ -f "$success_marker" ] && [ "$(/bin/cat "$success_marker")" = "$expected_version" ]; then
        /bin/rm -rf -- "$backup_app"
        /bin/rm -f -- "$pending_marker" "$success_marker" "$script_path"
        cleanup_staging
        trap - 0
        exit 0
      fi
      /bin/sleep 0.2
      wait_count=$((wait_count + 1))
    done

    exit 1
    """#

  private func run(executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ClairUpdateError.installFailed(
        "\(executable) exited with status \(process.terminationStatus)"
      )
    }
  }
}

@MainActor
final class ClairUpdateCoordinator: ObservableObject {
  typealias DataLoader = @Sendable (URL) async throws -> Data
  typealias FileDownloader = @Sendable (URL) async throws -> URL

  @Published private(set) var state: ClairUpdateState

  let profile: ClairRuntimeProfile
  let configuration: ClairUpdateConfiguration

  private let manifestLoader: DataLoader
  private let artifactDownloader: FileDownloader
  private let fileManager: FileManager
  private let restartHandler: () -> Void
  private var automaticTask: Task<Void, Never>?
  private var isStarted = false
  private var snoozedUntil = Date.distantPast

  init(
    profile: ClairRuntimeProfile,
    configuration: ClairUpdateConfiguration,
    manifestLoader: @escaping DataLoader = ClairUpdateCoordinator.loadManifest,
    artifactDownloader: @escaping FileDownloader = ClairUpdateCoordinator.downloadArtifact,
    fileManager: FileManager = .default,
    restartHandler: @escaping () -> Void = {}
  ) {
    self.profile = profile
    self.configuration = configuration
    self.manifestLoader = manifestLoader
    self.artifactDownloader = artifactDownloader
    self.fileManager = fileManager
    self.restartHandler = restartHandler

    if profile.channel == .stable {
      state = .idle
    } else {
      state = .disabled("Dev builds do not use the Stable update feed.")
    }
  }

  deinit {
    automaticTask?.cancel()
  }

  var canCheck: Bool {
    guard profile.channel == .stable,
      configuration.manifestURL != nil,
      configuration.publicKeyBase64 != nil,
      configuration.isInstalledAtExpectedPath,
      !state.isBusy
    else {
      return false
    }
    return true
  }

  func startAutomaticChecks() {
    guard !isStarted, canCheck else {
      return
    }
    isStarted = true
    automaticTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        guard let self, !Task.isCancelled else { return }
        self.check()
        while !Task.isCancelled {
          try await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
          guard !Task.isCancelled else { return }
          self.check()
        }
      } catch {
        // Cancellation is the normal path when the app exits.
      }
    }
  }

  func check(manual: Bool = false) {
    guard profile.channel == .stable else {
      return
    }
    if !manual, Date() < snoozedUntil {
      return
    }
    guard canCheck else {
      if manual, configuration.publicKeyBase64 == nil {
        state = .failed("Stable updater public key is not configured.")
      }
      return
    }

    state = .checking(manual: manual)
    Task { @MainActor [weak self] in
      await self?.performCheck(manual: manual)
    }
  }

  func dismissAvailable() {
    snoozedUntil = Date().addingTimeInterval(6 * 60 * 60)
    state = .idle
  }

  func dismissError() {
    state = .idle
  }

  func installAvailable() {
    guard case .available(let update) = state else {
      return
    }
    state = .downloading(update)
    Task { @MainActor [weak self] in
      await self?.performInstall(update)
    }
  }

  private func performCheck(manual: Bool) async {
    do {
      guard let manifestURL = configuration.manifestURL,
        let publicKeyBase64 = configuration.publicKeyBase64
      else {
        throw ClairUpdateError.updaterUnavailable("Stable updater is not configured.")
      }
      let verifier = try ClairUpdateSignatureVerifier(
        base64EncodedPublicKey: publicKeyBase64
      )
      let data = try await manifestLoader(manifestURL)
      let manifest = try JSONDecoder().decode(ClairUpdateManifest.self, from: data)
      let update = try manifest.makeUpdate(
        currentVersion: configuration.currentVersion,
        architecture: configuration.architecture,
        verifier: verifier
      )
      state = .available(update)
    } catch {
      state = manual ? .failed(Self.message(for: error)) : .idle
    }
  }

  private func performInstall(_ update: ClairUpdate) async {
    do {
      guard let publicKeyBase64 = configuration.publicKeyBase64 else {
        throw ClairUpdateError.updaterUnavailable("Stable updater is not configured.")
      }
      let verifier = try ClairUpdateSignatureVerifier(
        base64EncodedPublicKey: publicKeyBase64
      )
      guard
        try update.manifest.makeUpdate(
          currentVersion: configuration.currentVersion,
          architecture: configuration.architecture,
          verifier: verifier
        ) == update
      else {
        throw ClairUpdateError.invalidManifest("the available update changed before install")
      }

      let archiveURL = try await artifactDownloader(update.artifact.url)
      defer { try? fileManager.removeItem(at: archiveURL) }
      let actualHash = try ClairUpdateHasher.sha256(of: archiveURL)
      guard actualHash == update.artifact.normalizedSHA256 else {
        throw ClairUpdateError.invalidHash(
          expected: update.artifact.normalizedSHA256,
          actual: actualHash
        )
      }

      state = .installing(update)
      let installer = ClairUpdateInstaller(fileManager: fileManager)
      let stagedAppURL = try installer.stageArchive(
        at: archiveURL,
        update: update,
        configuration: configuration
      )
      try installer.scheduleRestart(
        stagedAppURL: stagedAppURL,
        update: update,
        configuration: configuration
      )
      restartHandler()
    } catch {
      state = .failed(Self.message(for: error))
    }
  }

  private static func loadManifest(url: URL) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode)
    else {
      throw ClairUpdateError.network("manifest request returned a non-success status")
    }
    return data
  }

  private static func downloadArtifact(url: URL) async throws -> URL {
    let (fileURL, response) = try await URLSession.shared.download(from: url)
    guard let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode)
    else {
      throw ClairUpdateError.network("artifact request returned a non-success status")
    }
    return fileURL
  }

  private static func message(for error: Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription {
      return description
    }
    return error.localizedDescription
  }
}

struct ClairUpdateNotice: View {
  @ObservedObject var updater: ClairUpdateCoordinator

  var body: some View {
    Group {
      switch updater.state {
      case .disabled, .idle:
        EmptyView()
      case .checking(let manual):
        if manual {
          card {
            Text("Checking for updates…")
              .font(.headline)
          }
        } else {
          EmptyView()
        }
      case .available(let update):
        card {
          Text("Update available")
            .font(.headline)
          Text("v\(update.currentVersion) → v\(update.version)")
            .foregroundStyle(.secondary)
          if let notes = update.notes, !notes.isEmpty {
            Text(notes)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(5)
          }
          HStack {
            Spacer()
            Button("Later") {
              updater.dismissAvailable()
            }
            Button("Restart and install") {
              updater.installAvailable()
            }
            .buttonStyle(.borderedProminent)
          }
        }
      case .downloading(let update):
        card {
          Text("Downloading… v\(update.version)")
            .font(.headline)
          ProgressView()
            .controlSize(.small)
        }
      case .installing(let update):
        card {
          Text("Installing… v\(update.version)")
            .font(.headline)
          Text("Restarting automatically")
            .foregroundStyle(.secondary)
        }
      case .failed(let message):
        card {
          Text("Update failed")
            .font(.headline)
            .foregroundStyle(.red)
          Text(message)
            .font(.caption)
            .textSelection(.enabled)
          HStack {
            Spacer()
            Button("Dismiss") {
              updater.dismissError()
            }
            Button("Check again") {
              updater.dismissError()
              updater.check(manual: true)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8, content: content)
      .frame(width: 340)
      .padding(12)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(.quaternary)
      }
      .shadow(radius: 10)
  }
}

struct ClairUpdateCommands: Commands {
  @ObservedObject var updater: ClairUpdateCoordinator

  var body: some Commands {
    CommandMenu("Clair") {
      Button("Check for Updates…") {
        updater.check(manual: true)
      }
      .disabled(!updater.canCheck)
    }
  }
}

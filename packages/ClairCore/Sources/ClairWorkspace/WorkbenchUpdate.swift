import CryptoKit
import Foundation

// V09: ADR-0008 Stable/Dev identity and ADR-0009 GitHub Release + Ed25519 signed update. The private source
// repo publishes through the public Diwamoto/clair-releases mirror (scripts/release.sh).
// Ported from the v1 updater (apple/ClairApp/ClairUpdate.swift) with the same manifest and signed
// payload, so scripts/generate-update-manifest.swift and the release workflow stay valid.
// Apply only works from an installed `/Applications/<Name>.app`; a SwiftPM binary reports `.notInstalled`.
// Update restart keeps the PTYs: shells are daemon-owned (T09) and `installUpdate` leaves the daemon
// running, so restored panes reattach by key (`ClairDaemonLauncher.keepsSessionsOnQuit`).

public enum ClairChannel: String, Sendable, Codable, CaseIterable {
  case stable, dev

  public var bundleIdentifier: String { self == .stable ? "com.diwamoto.clair" : "com.diwamoto.clair.dev" }
  public var displayName: String { self == .stable ? "Clair" : "Clair Dev" }
  /// Own directory per channel so Dev can never touch Stable's workspace, socket or update state.
  public var dataDirectoryName: String { self == .stable ? "Clair" : "Clair Dev" }

  /// `CLAIR_CHANNEL` (set by `make dev`), else the bundle id, else Stable.
  public static var current: Self {
    if let e = ProcessInfo.processInfo.environment["CLAIR_CHANNEL"], let c = Self(rawValue: e) { return c }
    return Bundle.main.bundleIdentifier == Self.dev.bundleIdentifier ? .dev : .stable
  }

  public var dataURL: URL { URL.applicationSupportDirectory.appending(path: dataDirectoryName) }

  /// B04: the data directory used to be "Clair v2" / "Clair Dev v2". Carry its `workspace.json`
  /// over once, and never overwrite a workspace that already exists in the new location.
  public func migrateLegacyWorkspace(in base: URL = .applicationSupportDirectory) {
    let fm = FileManager.default
    let dir = base.appending(path: dataDirectoryName)
    let old = base.appending(path: dataDirectoryName + " v2").appending(path: "workspace.json")
    let new = dir.appending(path: "workspace.json")
    guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try? fm.moveItem(at: old, to: new)
  }
}

public enum ClairUpdateError: Error, Equatable, Sendable {
  case unavailable(String), invalidManifest(String), invalidVersion(String), unsupportedChannel(String)
  case unsupportedArchitecture(String), notNewer(current: String, available: String)
  case invalidSignature, invalidHash, network(String), installFailed(String)
}

struct ClairVersion: Comparable {
  let raw: String
  private let parts: [Int]

  init(_ s: String) throws {
    raw = s.hasPrefix("v") ? String(s.dropFirst()) : s
    let p = raw.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard (1...4).contains(p.count), p.allSatisfy({ ($0 ?? -1) >= 0 }) else { throw ClairUpdateError.invalidVersion(s) }
    parts = p.map { $0! }
  }

  static func < (a: Self, b: Self) -> Bool {
    for i in 0..<max(a.parts.count, b.parts.count) {
      let l = i < a.parts.count ? a.parts[i] : 0, r = i < b.parts.count ? b.parts[i] : 0
      if l != r { return l < r }
    }
    return false
  }
}

public struct ClairUpdateArtifact: Codable, Equatable, Sendable {
  public let platform: String
  public let architecture: String
  public let url: URL
  public let sha256: String
  public let signature: String
  var hash: String { sha256.lowercased() }
}

public struct ClairUpdateManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let channel: ClairChannel
  public let version: String
  public let artifacts: [ClairUpdateArtifact]
  public let notes: String?

  /// Same bytes the release workflow signs.
  static func payload(_ m: Self, _ a: ClairUpdateArtifact) -> Data {
    Data((["clair-update-v1", m.channel.rawValue, m.version, a.platform, a.architecture, a.url.absoluteString, a.hash]
      .joined(separator: "\n") + "\n").utf8)
  }

  /// Validates schema, channel, version order, architecture, URL, hash shape and signature (in that order).
  func makeUpdate(currentVersion: String, architecture: String, publicKey: Curve25519.Signing.PublicKey) throws -> ClairUpdate {
    guard schemaVersion == 1 else { throw ClairUpdateError.invalidManifest("unsupported schema \(schemaVersion)") }
    guard channel == .stable else { throw ClairUpdateError.unsupportedChannel(channel.rawValue) }
    let cur = try ClairVersion(currentVersion), new = try ClairVersion(version)
    guard cur < new else { throw ClairUpdateError.notNewer(current: cur.raw, available: new.raw) }
    guard let a = artifacts.first(where: { $0.platform == "macos" && $0.architecture == architecture }) else {
      throw ClairUpdateError.unsupportedArchitecture(architecture)
    }
    guard a.url.scheme?.lowercased() == "https", a.url.host?.lowercased() == "github.com" else {
      throw ClairUpdateError.invalidManifest("artifact URL must be an HTTPS GitHub URL")
    }
    guard a.hash.count == 64, a.hash.allSatisfy(\.isHexDigit) else { throw ClairUpdateError.invalidManifest("bad SHA-256") }
    guard let sig = Data(base64Encoded: a.signature), publicKey.isValidSignature(sig, for: Self.payload(self, a)) else {
      throw ClairUpdateError.invalidSignature
    }
    return ClairUpdate(manifest: self, artifact: a, currentVersion: cur.raw)
  }
}

public struct ClairUpdate: Equatable, Sendable {
  public let manifest: ClairUpdateManifest
  public let artifact: ClairUpdateArtifact
  public let currentVersion: String
  public var version: String { manifest.version }
  public var notes: String? { manifest.notes }
}

public struct ClairUpdateConfiguration: Sendable {
  public static let manifestURL = URL(string: "https://github.com/Diwamoto/clair-releases/releases/latest/download/latest.json")!

  public let channel: ClairChannel
  public let publicKeyBase64: String?
  public let currentVersion: String
  public let currentAppURL: URL
  public let installURL: URL
  public let dataURL: URL
  public let architecture: String

  public var isInstalled: Bool { currentAppURL.standardizedFileURL.path == installURL.standardizedFileURL.path }

  /// Reads `ClairUpdatePublicKey` / version from the bundle. Dev has no feed (ADR-0009).
  public static func live(channel: ClairChannel = .current, bundle: Bundle = .main) -> Self {
    func s(_ k: String) -> String? { (bundle.object(forInfoDictionaryKey: k) as? String).flatMap { $0.isEmpty ? nil : $0 } }
    #if arch(arm64)
      let arch = "arm64"
    #else
      let arch = "x86_64"
    #endif
    return Self(
      channel: channel, publicKeyBase64: channel == .stable ? s("ClairUpdatePublicKey") : nil,
      currentVersion: s("CFBundleShortVersionString") ?? "0.0.0", currentAppURL: bundle.bundleURL,
      installURL: URL(fileURLWithPath: "/Applications/\(channel.displayName).app"), dataURL: channel.dataURL, architecture: arch)
  }
}

public enum ClairUpdater {
  public typealias Loader = @Sendable (URL) async throws -> Data
  public typealias Downloader = @Sendable (URL) async throws -> URL

  static func key(_ c: ClairUpdateConfiguration) throws -> Curve25519.Signing.PublicKey {
    guard c.channel == .stable else { throw ClairUpdateError.unavailable("Dev builds do not use the Stable update feed") }
    guard let b64 = c.publicKeyBase64 else { throw ClairUpdateError.unavailable("updater public key is not configured") }
    guard let raw = Data(base64Encoded: b64), let k = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
      throw ClairUpdateError.invalidManifest("embedded public key is not Ed25519")
    }
    return k
  }

  public static func check(_ c: ClairUpdateConfiguration, load: Loader = fetch) async throws -> ClairUpdate {
    let k = try key(c)
    let m = try JSONDecoder().decode(ClairUpdateManifest.self, from: try await load(ClairUpdateConfiguration.manifestURL))
    return try m.makeUpdate(currentVersion: c.currentVersion, architecture: c.architecture, publicKey: k)
  }

  /// Download → SHA-256 → stage (bundle id/version checked) → detached helper swaps the app with backup and rolls back
  /// unless the new process reports a successful start. The caller must terminate the app afterwards.
  public static func install(_ u: ClairUpdate, _ c: ClairUpdateConfiguration, download: Downloader = fetchFile) async throws {
    guard c.isInstalled else { throw ClairUpdateError.installFailed("must be installed at \(c.installURL.path)") }
    // Re-validate: the manifest the user saw must still verify.
    guard try u.manifest.makeUpdate(currentVersion: c.currentVersion, architecture: c.architecture, publicKey: try key(c)) == u else {
      throw ClairUpdateError.invalidManifest("update changed before install")
    }
    let archive = try await download(u.artifact.url)
    defer { try? FileManager.default.removeItem(at: archive) }
    guard try sha256(of: archive) == u.artifact.hash else { throw ClairUpdateError.invalidHash }
    let staged = try stage(archive, u, c)
    try scheduleRestart(staged, u, c)
  }

  static func sha256(of url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static func fetch(_ url: URL) async throws -> Data {
    let (d, r) = try await URLSession.shared.data(from: url)
    guard (r as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { throw ClairUpdateError.network("non-success status") }
    return d
  }

  public static func fetchFile(_ url: URL) async throws -> URL {
    let (f, r) = try await URLSession.shared.download(from: url)
    guard (r as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { throw ClairUpdateError.network("non-success status") }
    return f
  }

  // MARK: install

  static func dir(_ c: ClairUpdateConfiguration) -> URL { c.dataURL.appending(path: "updates-v1") }
  static func pending(_ c: ClairUpdateConfiguration) -> URL { dir(c).appending(path: "pending.json") }
  static func success(_ c: ClairUpdateConfiguration) -> URL { dir(c).appending(path: "startup-success.txt") }

  static func stage(_ archive: URL, _ u: ClairUpdate, _ c: ClairUpdateConfiguration) throws -> URL {
    let fm = FileManager.default
    let staging = dir(c).appending(path: "staging-\(UUID().uuidString)")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
      #if os(macOS)
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", archive.path, staging.path]
      try p.run(); p.waitWithoutRunLoop()
      guard p.terminationStatus == 0 else { throw ClairUpdateError.installFailed("ditto exited \(p.terminationStatus)") }
      #else
      throw ClairUpdateError.installFailed("updates are macOS-only")
      #endif
      let apps = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { $0.pathExtension == "app" }
      guard apps.count == 1, let bundle = Bundle(url: apps[0]) else { throw ClairUpdateError.installFailed("archive must contain exactly one app bundle") }
      guard bundle.bundleIdentifier == c.channel.bundleIdentifier else { throw ClairUpdateError.installFailed("bundle identifier mismatch") }
      guard bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == u.version else {
        throw ClairUpdateError.installFailed("staged version does not match the manifest")
      }
      return apps[0]
    } catch {
      try? fm.removeItem(at: staging)
      throw error as? ClairUpdateError ?? .installFailed("\(error)")
    }
  }

  /// Called on every launch: a new app that starts and sees its own pending marker tells the helper it is healthy.
  @discardableResult
  public static func markStartupSuccess(_ c: ClairUpdateConfiguration) -> Bool {
    guard let d = try? Data(contentsOf: pending(c)), let m = try? JSONDecoder().decode([String: String].self, from: d),
      m["version"] == c.currentVersion, m["bundleIdentifier"] == c.channel.bundleIdentifier
    else { return false }
    return (try? Data(c.currentVersion.utf8).write(to: success(c), options: .atomic)) != nil
  }

  static func scheduleRestart(_ staged: URL, _ u: ClairUpdate, _ c: ClairUpdateConfiguration) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: c.installURL.path), fm.fileExists(atPath: staged.path) else { throw ClairUpdateError.installFailed("installed or staged app is missing") }
    guard !fm.fileExists(atPath: pending(c).path) else { throw ClairUpdateError.installFailed("another update is in progress") }
    try fm.createDirectory(at: dir(c), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.removeItem(at: success(c))
    try JSONEncoder().encode(["version": u.version, "bundleIdentifier": c.channel.bundleIdentifier]).write(to: pending(c), options: .atomic)
    let script = dir(c).appending(path: "helper-\(UUID().uuidString).sh")
    do {
      try Data(helperScript.utf8).write(to: script, options: .atomic)
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      #if os(macOS)
      let h = Process()
      h.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
      h.arguments = ["/bin/sh", script.path, String(ProcessInfo.processInfo.processIdentifier), c.installURL.path, staged.path,
        dir(c).appending(path: "backup-\(UUID().uuidString).app").path, success(c).path, pending(c).path, u.version,
        c.installURL.deletingPathExtension().lastPathComponent]
      h.standardInput = FileHandle.nullDevice; h.standardOutput = FileHandle.nullDevice; h.standardError = FileHandle.nullDevice
      try h.run()
      #else
      throw ClairUpdateError.installFailed("updates are macOS-only")
      #endif
    } catch {
      try? fm.removeItem(at: pending(c)); try? fm.removeItem(at: script)
      throw ClairUpdateError.installFailed("\(error)")
    }
  }

  static let helperScript = #"""
    #!/bin/sh
    set -eu
    current_pid="$1"; current_app="$2"; staged_app="$3"; backup_app="$4"
    success_marker="$5"; pending_marker="$6"; expected_version="$7"; app_name="$8"
    script_path="$0"; staging_directory="${staged_app%/*}"
    old_moved=0; new_moved=0

    rollback() {
      status=$?
      if [ "$old_moved" -eq 1 ]; then
        if [ "$new_moved" -eq 1 ]; then
          for pid in $(/usr/bin/pgrep -x "$app_name" 2>/dev/null || true); do /bin/kill "$pid" 2>/dev/null || true; done
          /bin/sleep 0.5
          /bin/rm -rf -- "$current_app" 2>/dev/null || true
        fi
        /bin/mv -- "$backup_app" "$current_app" 2>/dev/null || true
        /usr/bin/open -n "$current_app" >/dev/null 2>&1 || true
      fi
      /bin/rm -f -- "$pending_marker" "$success_marker" 2>/dev/null || true
      /bin/rm -rf -- "$staging_directory" 2>/dev/null || true
      /bin/rm -f -- "$script_path" 2>/dev/null || true
      exit "$status"
    }
    trap rollback 0

    n=0
    while /bin/kill -0 "$current_pid" 2>/dev/null; do
      [ "$n" -ge 150 ] && exit 1
      /bin/sleep 0.2; n=$((n + 1))
    done
    /bin/mv -- "$current_app" "$backup_app"; old_moved=1
    /bin/mv -- "$staged_app" "$current_app"; new_moved=1
    /usr/bin/open -n "$current_app" >/dev/null 2>&1

    n=0
    while [ "$n" -lt 150 ]; do
      if [ -f "$success_marker" ] && [ "$(/bin/cat "$success_marker")" = "$expected_version" ]; then
        /bin/rm -rf -- "$backup_app" "$staging_directory"
        /bin/rm -f -- "$pending_marker" "$success_marker" "$script_path"
        trap - 0; exit 0
      fi
      /bin/sleep 0.2; n=$((n + 1))
    done
    exit 1
    """#
}

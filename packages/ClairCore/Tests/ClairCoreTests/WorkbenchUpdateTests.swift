import CryptoKit
import XCTest

@testable import ClairWorkspace

/// V09: ADR-0009 manifest trust and rollback; ADR-0008 channel identity.
final class WorkbenchUpdateTests: XCTestCase {
  let sk = Curve25519.Signing.PrivateKey()
  let url = URL(string: "https://github.com/Diwamoto/clair/releases/download/v2.0.0/Clair-2.0.0-macos-arm64.zip")!
  let goodHash = String(repeating: "ab", count: 32)

  func manifest(channel: ClairChannel = .stable, version: String = "2.0.0", arch: String = "arm64", url: URL? = nil, hash: String? = nil,
                tamper: Bool = false) -> ClairUpdateManifest {
    let a0 = ClairUpdateArtifact(platform: "macos", architecture: arch, url: url ?? self.url, sha256: hash ?? goodHash, signature: "")
    let m0 = ClairUpdateManifest(schemaVersion: 1, channel: channel, version: version, artifacts: [a0], notes: nil)
    let sig = try! sk.signature(for: ClairUpdateManifest.payload(m0, a0)).base64EncodedString()
    let a = ClairUpdateArtifact(platform: "macos", architecture: arch, url: url ?? self.url, sha256: tamper ? String(repeating: "cd", count: 32) : (hash ?? goodHash), signature: sig)
    return ClairUpdateManifest(schemaVersion: 1, channel: channel, version: version, artifacts: [a], notes: nil)
  }
  func update(_ m: ClairUpdateManifest, current: String = "1.0.0") throws -> ClairUpdate {
    try m.makeUpdate(currentVersion: current, architecture: "arm64", publicKey: sk.publicKey)
  }
  func code(_ m: ClairUpdateManifest, current: String = "1.0.0") -> ClairUpdateError? {
    do { _ = try update(m, current: current); return nil } catch { return error as? ClairUpdateError }
  }

  func testValidManifestAccepted() throws { XCTAssertEqual(try update(manifest()).version, "2.0.0") }

  func testRejections() {
    XCTAssertEqual(code(manifest(tamper: true)), .invalidSignature)  // hash swapped after signing
    XCTAssertEqual(code(manifest(channel: .dev)), .unsupportedChannel("dev"))
    XCTAssertEqual(code(manifest(), current: "2.0.0"), .notNewer(current: "2.0.0", available: "2.0.0"))
    XCTAssertEqual(code(manifest(), current: "10.0.0"), .notNewer(current: "10.0.0", available: "2.0.0"))  // numeric, not lexical
    XCTAssertEqual(code(manifest(arch: "x86_64")), .unsupportedArchitecture("arm64"))
    XCTAssertEqual(code(manifest(url: URL(string: "http://github.com/x.zip")!)), .invalidManifest("artifact URL must be an HTTPS GitHub URL"))
    XCTAssertEqual(code(manifest(url: URL(string: "https://evil.example/x.zip")!)), .invalidManifest("artifact URL must be an HTTPS GitHub URL"))
    XCTAssertEqual(code(manifest(hash: "zz")), .invalidManifest("bad SHA-256"))
    XCTAssertEqual(code(manifest(version: "2.x")), .invalidVersion("2.x"))
    // signed by someone else
    XCTAssertThrowsError(try manifest().makeUpdate(currentVersion: "1", architecture: "arm64", publicKey: Curve25519.Signing.PrivateKey().publicKey))
  }

  func testMalformedJSONAndDevHasNoFeed() async {
    let bad: ClairUpdater.Loader = { _ in Data("{".utf8) }
    let cfg = ClairUpdateConfiguration(
      channel: .stable, publicKeyBase64: sk.publicKey.rawRepresentation.base64EncodedString(), currentVersion: "1.0.0",
      currentAppURL: URL(fileURLWithPath: "/x"), installURL: URL(fileURLWithPath: "/y"), dataURL: URL(fileURLWithPath: "/z"), architecture: "arm64")
    do { _ = try await ClairUpdater.check(cfg, load: bad); XCTFail() } catch { XCTAssertFalse(error is ClairUpdateError) }
    let dev = ClairUpdateConfiguration(
      channel: .dev, publicKeyBase64: cfg.publicKeyBase64, currentVersion: "1.0.0",
      currentAppURL: cfg.currentAppURL, installURL: cfg.installURL, dataURL: cfg.dataURL, architecture: "arm64")
    do { _ = try await ClairUpdater.check(dev, load: bad); XCTFail() } catch { XCTAssertEqual(error as? ClairUpdateError, .unavailable("Dev builds do not use the Stable update feed")) }
  }

  func testUninstalledAppRefusesInstall() async throws {
    let cfg = ClairUpdateConfiguration(
      channel: .stable, publicKeyBase64: sk.publicKey.rawRepresentation.base64EncodedString(), currentVersion: "1.0.0",
      currentAppURL: URL(fileURLWithPath: "/tmp/somewhere/Clair.app"), installURL: URL(fileURLWithPath: "/Applications/Clair.app"),
      dataURL: URL(fileURLWithPath: "/tmp/z"), architecture: "arm64")
    do { try await ClairUpdater.install(try update(manifest()), cfg); XCTFail() } catch {
      guard case .installFailed = error as? ClairUpdateError else { return XCTFail("\(error)") }
    }
  }

  func testChannelIdentitiesAllDiffer() {
    let s = ClairChannel.stable, d = ClairChannel.dev
    XCTAssertNotEqual(s.bundleIdentifier, d.bundleIdentifier)
    XCTAssertNotEqual(s.displayName, d.displayName)
    XCTAssertNotEqual(s.dataURL, d.dataURL)
    XCTAssertEqual(d.bundleIdentifier, "com.diwamoto.clair.dev")
  }

  func testLegacyWorkspaceMovesOnceAndNeverOverwrites() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appending(path: "b04-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: base) }
    let old = base.appending(path: "Clair Dev v2"), new = base.appending(path: "Clair Dev")
    try fm.createDirectory(at: old, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: old.appending(path: "workspace.json"))
    ClairChannel.dev.migrateLegacyWorkspace(in: base)
    XCTAssertEqual(try String(contentsOf: new.appending(path: "workspace.json"), encoding: .utf8), "old")
    XCTAssertFalse(fm.fileExists(atPath: old.appending(path: "workspace.json").path))
    try Data("older".utf8).write(to: old.appending(path: "workspace.json"))
    ClairChannel.dev.migrateLegacyWorkspace(in: base)
    XCTAssertEqual(try String(contentsOf: new.appending(path: "workspace.json"), encoding: .utf8), "old")
  }

  /// A new app that never reports startup success must be rolled back to the backup (helper script).
  func testHelperRollsBackWhenNewAppFailsToStart() throws {
    let fm = FileManager.default
    let root = URL.temporaryDirectory.appending(path: "clair-v09-\(UUID().uuidString)")
    let staging = root.appending(path: "staging"), current = root.appending(path: "Clair.app"), staged = staging.appending(path: "Clair.app")
    for d in [current, staged] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
    try "old".write(to: current.appending(path: "v"), atomically: true, encoding: .utf8)
    try "new".write(to: staged.appending(path: "v"), atomically: true, encoding: .utf8)
    let script = root.appending(path: "h.sh")
    try ClairUpdater.helperScript.write(to: script, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    // pid 0x7fffffff is not running → no wait; `open -n` on a fake bundle fails → rollback path.
    p.arguments = [script.path, "2147483646", current.path, staged.path, root.appending(path: "backup.app").path,
      root.appending(path: "ok").path, root.appending(path: "pending").path, "2.0.0", "ClairNoSuchProcess"]
    try p.run(); p.waitUntilExit()
    XCTAssertNotEqual(p.terminationStatus, 0)
    XCTAssertEqual(try String(contentsOf: current.appending(path: "v"), encoding: .utf8), "old")
  }

  func testSleepPreventedOnlyWhileAgentsRunAndOnACUnlessOptedIn() throws {
    let r = CommandRegistry.workbench
    let dir = URL.temporaryDirectory.appending(path: "clair-v09-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var s = WorkbenchState()
    try r.execute("project.open", ["path": .string(dir.path)], state: &s).get()
    XCTAssertFalse(s.preventsSleep(onACPower: true))  // no agent
    try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get()
    XCTAssertTrue(s.preventsSleep(onACPower: true))
    XCTAssertFalse(s.preventsSleep(onACPower: false))  // battery, not opted in
    try r.execute("settings.set", ["key": .string("preventSleepOnBattery"), "value": .bool(true)], state: &s).get()
    XCTAssertTrue(s.preventsSleep(onACPower: false))
    s.notices.record(project: s.project, pane: s.tree.focused, kind: .exited, exitCode: 0)
    XCTAssertFalse(s.preventsSleep(onACPower: true))  // the agent exited
  }
}

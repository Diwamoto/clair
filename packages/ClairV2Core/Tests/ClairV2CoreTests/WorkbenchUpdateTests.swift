import CryptoKit
import XCTest

@testable import ClairV2Workspace

/// V09: ADR-0009 manifest trust and rollback; ADR-0008 channel identity.
final class WorkbenchUpdateTests: XCTestCase {
  let sk = Curve25519.Signing.PrivateKey()
  let url = URL(string: "https://github.com/Diwamoto/clair/releases/download/v2.0.0/Clair-2.0.0-macos-arm64.zip")!
  let goodHash = String(repeating: "ab", count: 32)

  func manifest(channel: ClairV2Channel = .stable, version: String = "2.0.0", arch: String = "arm64", url: URL? = nil, hash: String? = nil,
                tamper: Bool = false) -> ClairV2UpdateManifest {
    let a0 = ClairV2UpdateArtifact(platform: "macos", architecture: arch, url: url ?? self.url, sha256: hash ?? goodHash, signature: "")
    let m0 = ClairV2UpdateManifest(schemaVersion: 1, channel: channel, version: version, artifacts: [a0], notes: nil)
    let sig = try! sk.signature(for: ClairV2UpdateManifest.payload(m0, a0)).base64EncodedString()
    let a = ClairV2UpdateArtifact(platform: "macos", architecture: arch, url: url ?? self.url, sha256: tamper ? String(repeating: "cd", count: 32) : (hash ?? goodHash), signature: sig)
    return ClairV2UpdateManifest(schemaVersion: 1, channel: channel, version: version, artifacts: [a], notes: nil)
  }
  func update(_ m: ClairV2UpdateManifest, current: String = "1.0.0") throws -> ClairV2Update {
    try m.makeUpdate(currentVersion: current, architecture: "arm64", publicKey: sk.publicKey)
  }
  func code(_ m: ClairV2UpdateManifest, current: String = "1.0.0") -> ClairV2UpdateError? {
    do { _ = try update(m, current: current); return nil } catch { return error as? ClairV2UpdateError }
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
    let bad: ClairV2Updater.Loader = { _ in Data("{".utf8) }
    let cfg = ClairV2UpdateConfiguration(
      channel: .stable, publicKeyBase64: sk.publicKey.rawRepresentation.base64EncodedString(), currentVersion: "1.0.0",
      currentAppURL: URL(fileURLWithPath: "/x"), installURL: URL(fileURLWithPath: "/y"), dataURL: URL(fileURLWithPath: "/z"), architecture: "arm64")
    do { _ = try await ClairV2Updater.check(cfg, load: bad); XCTFail() } catch { XCTAssertFalse(error is ClairV2UpdateError) }
    let dev = ClairV2UpdateConfiguration(
      channel: .dev, publicKeyBase64: cfg.publicKeyBase64, currentVersion: "1.0.0",
      currentAppURL: cfg.currentAppURL, installURL: cfg.installURL, dataURL: cfg.dataURL, architecture: "arm64")
    do { _ = try await ClairV2Updater.check(dev, load: bad); XCTFail() } catch { XCTAssertEqual(error as? ClairV2UpdateError, .unavailable("Dev builds do not use the Stable update feed")) }
  }

  func testUninstalledAppRefusesInstall() async throws {
    let cfg = ClairV2UpdateConfiguration(
      channel: .stable, publicKeyBase64: sk.publicKey.rawRepresentation.base64EncodedString(), currentVersion: "1.0.0",
      currentAppURL: URL(fileURLWithPath: "/tmp/somewhere/Clair.app"), installURL: URL(fileURLWithPath: "/Applications/Clair.app"),
      dataURL: URL(fileURLWithPath: "/tmp/z"), architecture: "arm64")
    do { try await ClairV2Updater.install(try update(manifest()), cfg); XCTFail() } catch {
      guard case .installFailed = error as? ClairV2UpdateError else { return XCTFail("\(error)") }
    }
  }

  func testChannelIdentitiesAllDiffer() {
    let s = ClairV2Channel.stable, d = ClairV2Channel.dev
    XCTAssertNotEqual(s.bundleIdentifier, d.bundleIdentifier)
    XCTAssertNotEqual(s.displayName, d.displayName)
    XCTAssertNotEqual(s.dataURL, d.dataURL)
    XCTAssertEqual(d.bundleIdentifier, "com.diwamoto.clair.dev")
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
    try ClairV2Updater.helperScript.write(to: script, atomically: true, encoding: .utf8)
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

import Foundation
import XCTest

@testable import ClairWorkspace

/// V02 headless scenario: no UI, only the registry behind a socket and the CLI parser.
final class WorkbenchIPCTests: XCTestCase {
  private final class Host: @unchecked Sendable {
    let lock = NSLock()
    var state = WorkbenchState()
    func run(_ req: WorkbenchIPCRequest) -> Result<CommandResult, CommandError> {
      lock.lock(); defer { lock.unlock() }
      return CommandRegistry.workbench.execute(req.command, req.input, state: &state)  // no `confirmed` path from IPC
    }
  }

  private func serve(uid: uid_t = geteuid()) throws -> (WorkbenchIPCServer, URL, Host) {
    let url = URL(fileURLWithPath: "/tmp/clair-ipc-\(UUID().uuidString.prefix(8))/c.sock")
    let host = Host()
    let server = WorkbenchIPCServer(socket: url, allowedUID: uid, handler: host.run)
    try server.start()
    addTeardownBlock { server.stop(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    return (server, url, host)
  }

  private func cli(_ args: [String], _ url: URL) throws -> WorkbenchIPCReply {
    try WorkbenchIPC.call(XCTUnwrap(WorkbenchCLI.parse(args)), socket: url)
  }

  func testSplitSnapshotAssertViaCLIOnly() throws {
    let (_, url, _) = try serve()
    guard case .pane? = try cli(["pane.splitRight"], url).result else { return XCTFail("split") }
    XCTAssertEqual(try cli(["open", "docs/architecture/pane-layout.md:12:3"], url).error, nil)
    guard case .snapshot(let s)? = try cli(["state.snapshot"], url).result else { return XCTFail("no snapshot") }
    XCTAssertEqual(s.tree.leaves.count, WorkbenchState().tree.leaves.count + 1)
    XCTAssertEqual(s.active, "docs/architecture/pane-layout.md")
    // machine-readable error, state untouched
    XCTAssertEqual(try cli(["pane.focus", "id=99"], url).error?.code, .preconditionFailed)
    XCTAssertEqual(try cli(["nope"], url).error?.code, .unknownCommand)
  }

  func testDestructiveCannotBeConfirmedOverIPC() throws {
    let (_, url, host) = try serve()
    host.state.dirty.insert(host.state.active!)
    XCTAssertEqual(try cli(["tab.close"], url).error?.code, .confirmationRequired)
    XCTAssertEqual(host.state.tabs.count, 1)
    // a `confirmed` field smuggled into the JSON is ignored
    var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkbenchIPCRequest(command: "tab.close"))) as! [String: Any]
    raw["confirmed"] = true
    let fd = try WorkbenchIPC.connectFD(url, timeout: 5); defer { close(fd) }
    WorkbenchIPC.writeAll(fd, try JSONSerialization.data(withJSONObject: raw))
    let reply = try JSONDecoder().decode(WorkbenchIPCReply.self, from: XCTUnwrap(WorkbenchIPC.readLine(fd)))
    XCTAssertEqual(reply.error?.code, .confirmationRequired)
    XCTAssertEqual(host.state.tabs.count, 1)
  }

  func testOtherUserAndMalformedAndPermissions() throws {
    let (_, url, _) = try serve(uid: geteuid() &+ 1)  // peer uid mismatch → dropped, no reply
    XCTAssertThrowsError(try cli(["state.snapshot"], url)) { XCTAssertEqual($0 as? WorkbenchIPCError, .badMessage) }
    let (_, url2, _) = try serve()
    var st = stat()
    XCTAssertEqual(stat(url2.path, &st), 0)
    XCTAssertEqual(st.st_mode & 0o777, 0o600)
    XCTAssertEqual(stat(url2.deletingLastPathComponent().path, &st), 0)
    XCTAssertEqual(st.st_mode & 0o777, 0o700)
  }

  func testNotRunningAndAlreadyRunningAndParse() throws {
    let gone = URL(fileURLWithPath: "/tmp/clair-none/c.sock")
    XCTAssertThrowsError(try cli(["state.snapshot"], gone)) { XCTAssertEqual($0 as? WorkbenchIPCError, .notRunning) }
    let (_, url, _) = try serve()
    XCTAssertThrowsError(try WorkbenchIPCServer(socket: url, handler: { _ in .success(.ok) }).start()) {
      XCTAssertEqual($0 as? WorkbenchIPCError, .alreadyRunning)
    }
    XCTAssertEqual(WorkbenchCLI.parse(["settings.set", "key=showQuota", "value=true"])?.input, ["key": .string("showQuota"), "value": .bool(true)])
    XCTAssertEqual(WorkbenchCLI.parse(["open", "a/b.swift:1:2"])?.input["path"], .string("a/b.swift"))
    XCTAssertNil(WorkbenchCLI.parse([]))
    XCTAssertNil(WorkbenchCLI.parse(["pane.focus", "id"]))
  }
}

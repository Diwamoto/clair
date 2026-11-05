import ClairShared
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
    let dir = URL.temporaryDirectory.appending(path: "clair-open-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    try Data("x".utf8).write(to: dir.appending(path: "f.md"))
    XCTAssertEqual(try cli(["open", dir.appending(path: "f.md").path + ":12:3"], url).error, nil)
    guard case .pane? = try cli(["pane.splitRight"], url).result else { return XCTFail("split") }
    guard case .snapshot(let s)? = try cli(["state.snapshot"], url).result else { return XCTFail("no snapshot") }
    XCTAssertEqual(s.tree.leaves.count, WorkbenchState().tree.leaves.count + 1)
    XCTAssertEqual(s.active, "f.md")  // no Project owned it, so its folder became one
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
    XCTAssertEqual(WorkbenchCLI.parse(["settings.set", "key=hideQuota", "value=true"])?.input, ["key": .string("hideQuota"), "value": .bool(true)])
    let cwd = FileManager.default.currentDirectoryPath
    let rel = try XCTUnwrap(WorkbenchCLI.parse(["open", "a/b.swift:7:2"]))
    XCTAssertEqual(rel.command, "file.open")
    XCTAssertEqual(rel.input, ["path": .string(cwd + "/a/b.swift"), "line": .int(7)])
    XCTAssertEqual(WorkbenchCLI.parse(["open", "/x/y.go"])?.input, ["path": .string("/x/y.go")])
    XCTAssertNil(WorkbenchCLI.parse([]))
    XCTAssertNil(WorkbenchCLI.parse(["pane.focus", "id"]))
    XCTAssertEqual(WorkbenchCLI.parse(["pane", "splitRight"])?.command, "pane.splitRight")
    XCTAssertEqual(WorkbenchCLI.parse(["project", "open", "path=/p"]), WorkbenchCLI.parse(["project.open", "path=/p"]))
    XCTAssertTrue(WorkbenchCLI.help("project").contains("project open"))
  }

  // The GUI's cwd is not the caller's: path arguments it reads from disk are made absolute here, project-relative ones are not.
  func testRelativePathArgumentsResolveAgainstCallerCwd() throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
    XCTAssertEqual(WorkbenchCLI.parse(["project.open", "path=."])?.input, ["path": .string(cwd)])
    XCTAssertEqual(WorkbenchCLI.parse(["debug.breakpoint", "path=a/../b.go", "line=3"])?.input, ["path": .string(cwd + "/b.go"), "line": .int(3)])
    XCTAssertEqual(WorkbenchCLI.parse(["project.addFolder", "name=x", "path=/abs"])?.input, ["name": .string("x"), "path": .string("/abs")])
    XCTAssertEqual(WorkbenchCLI.parse(["tab.open", "path=a/b.swift"])?.input, ["path": .string("a/b.swift")])
  }

  // From a Clair terminal, agent.status / output / list must not get a `parent` they would refuse as unknown.
  func testCallerBecomesParentOnlyWhereTaken() {
    let launch = WorkbenchIPCRequest(command: "agent.launch", input: ["parent": .string("/fake#1")], caller: "/r#2").callerAsParent()
    XCTAssertEqual(launch.input["parent"], .string("/r#2"))
    XCTAssertNil(WorkbenchIPCRequest(command: "agent.launch", input: ["parent": .string("/fake#1")]).callerAsParent().input["parent"])
    for id in ["agent.status", "agent.output", "agent.list"] {
      let req = WorkbenchIPCRequest(command: id, input: ["key": .string("/r#3")], caller: "/r#2").callerAsParent()
      XCTAssertEqual(req.input, ["key": .string("/r#3")], id)
    }
    XCTAssertEqual(WorkbenchIPCRequest(command: "tab.open", input: ["parent": .string("x")], caller: "/r#2").callerAsParent().input["parent"], .string("x"))
  }

  private func decoded(_ outcome: WorkbenchCLI.Outcome) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(outcome.output).utf8)) as? [String: Any])
  }

  private func run(_ args: [String], reply: CommandResult) -> WorkbenchCLI.Outcome {
    WorkbenchCLI.run(args) { _, _ in WorkbenchIPCReply(result: reply) }
  }

  func testOutputHasOneShapeWithoutEnumEncoding() throws {
    XCTAssertEqual(run(["tab.next"], reply: .ok), WorkbenchCLI.Outcome(output: #"{"ok":true,"result":null}"#, code: 0))
    XCTAssertEqual(run(["pane.splitRight"], reply: .pane(3)).output, #"{"ok":true,"result":{"pane":3}}"#)
    XCTAssertEqual(run(["agent.launch"], reply: .text("/p#7")).output, #"{"ok":true,"result":"/p#7"}"#)
    XCTAssertEqual(run(["finder.propose"], reply: .text("id-1")).output, #"{"ok":true,"result":"id-1"}"#)
    XCTAssertEqual(run(["finder.proposal", "id=a"], reply: .text(#"{"state":"pending"}"#)).output, #"{"ok":true,"result":{"state":"pending"}}"#)
    // Only finder.* answers in JSON text; agent output that looks like JSON stays a string.
    XCTAssertEqual(run(["agent.output"], reply: .text("[1]")).output, #"{"ok":true,"result":"[1]"}"#)
    XCTAssertEqual(run(["schedule.list"], reply: .text("[]")).output, #"{"ok":true,"result":[]}"#)  // #72
    let projects = try decoded(run(["project.list"], reply: .projects(active: "a", projects: [])))["result"] as? [String: Any]
    XCTAssertEqual(projects?["active"] as? String, "a")
    let context = try decoded(run(["editor.context"], reply: .diagnostics([])))["result"]
    XCTAssertEqual(context as? [String], [])
    XCTAssertFalse(try XCTUnwrap(run(["state.snapshot"], reply: .snapshot(WorkbenchState())).output).contains("_0"))
  }

  func testRunRendersRepliesFromARealSocket() throws {
    let (_, url, _) = try serve()
    let call: WorkbenchCLI.Call = { try WorkbenchIPC.call($0, socket: url, timeout: $1) }
    XCTAssertEqual(WorkbenchCLI.run(["project", "list"], call: call).code, 0)
    XCTAssertEqual(try decoded(WorkbenchCLI.run(["project", "list"], call: call))["ok"] as? Bool, true)
    XCTAssertEqual(WorkbenchCLI.run(["no.such"], call: call), WorkbenchCLI.Outcome(output: #"{"error":{"code":"unknownCommand","message":"no.such"},"ok":false}"#, code: 1))
    XCTAssertFalse(try XCTUnwrap(WorkbenchCLI.run(["state", "snapshot"], call: call).output).contains("_0"))
  }

  func testReadableIndentsTheSameReplyAndLeavesHelpAlone() {
    let readable = run(["pane.splitRight"], reply: .pane(3)).readable(color: false)
    XCTAssertEqual(readable, WorkbenchCLI.Outcome(output: "{\n  \"ok\" : true,\n  \"result\" : {\n    \"pane\" : 3\n  }\n}", code: 0))
    XCTAssertEqual(run(["help"], reply: .ok).readable(color: true), run(["help"], reply: .ok))
    XCTAssertEqual(WorkbenchCLI.Outcome(output: nil, code: 0).readable(color: true).output, nil)
    XCTAssertEqual(run(["pane.focus", "id"], reply: .ok).readable(color: false).code, 2)
  }

  func testColorPaintsTokensWithoutReadingInsideStrings() throws {
    func paint(_ code: Int, _ text: String) -> String { "\u{1B}[\(code)m\(text)\u{1B}[0m" }
    XCTAssertEqual(
      WorkbenchCLI.colored(#"{"a" : true, "b" : null, "c" : -1.5e+2, "d" : false}"#),
      "{\(paint(36, #""a""#)) : \(paint(35, "true")), \(paint(36, #""b""#)) : \(paint(90, "null")), \(paint(36, #""c""#)) : \(paint(33, "-1.5e+2")), \(paint(36, #""d""#)) : \(paint(35, "false"))}")
    // Literals, numbers, colons and escaped quotes inside a string stay part of that string.
    let text = #""true 1 \" : null""#
    XCTAssertEqual(WorkbenchCLI.colored(text), paint(32, text))
    // Removing the color gives back JSON that still parses.
    let colored = try XCTUnwrap(run(["agent.launch"], reply: .text(#"a"b:1"#)).readable(color: true).output)
    let plain = colored.replacing(#/\x{1B}\[\d+m/#, with: "")
    XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any])?["result"] as? String, #"a"b:1"#)
  }

  func testEveryFailureIsJSONWithItsExitCode() throws {
    let denied = WorkbenchCLI.run(["tab.next"]) { _, _ in WorkbenchIPCReply(error: CommandError(.denied, "no")) }
    XCTAssertEqual(denied, WorkbenchCLI.Outcome(output: #"{"error":{"code":"denied","message":"no"},"ok":false}"#, code: 1))
    XCTAssertEqual(run(["pane.focus", "id"], reply: .ok).code, 2)
    XCTAssertEqual(try decoded(run([], reply: .ok))["ok"] as? Bool, false)
    for (error, code) in [(WorkbenchIPCError.notRunning, "notRunning"), (.badMessage, "ipcFailure")] {
      let down = WorkbenchCLI.run(["tab.next"]) { _, _ in throw error }
      XCTAssertEqual(down.code, 3)
      XCTAssertEqual((try decoded(down)["error"] as? [String: Any])?["code"] as? String, code)
    }
  }

  func testWaitsExitByOutcomeAndKeepTheLastState() throws {
    XCTAssertEqual(run(["agent.wait", "key=/r#1"], reply: .text("exited 2")).output, #"{"ok":true,"result":"exited 2"}"#)
    let timedOut = run(["agent", "wait", "key=/r#1", "timeout=-1"], reply: .text("running"))
    XCTAssertEqual(timedOut.code, 1)
    XCTAssertEqual((try decoded(timedOut)["error"] as? [String: Any])?["code"] as? String, "timeout")
    XCTAssertEqual(try decoded(timedOut)["result"] as? String, "running")
    XCTAssertEqual(run(["finder.wait", "id=a"], reply: .text(#"{"state":"applied"}"#)).code, 0)
    let rejected = run(["finder.wait", "id=a"], reply: .text(#"{"state":"rejected"}"#))
    XCTAssertEqual(rejected.code, 1)
    XCTAssertEqual((try decoded(rejected)["error"] as? [String: Any])?["code"] as? String, "rejected")
    XCTAssertEqual((try decoded(rejected)["result"] as? [String: Any])?["state"] as? String, "rejected")
  }

  func testOpenWaitIsSilentOnSuccess() {
    var calls = 0
    let done = WorkbenchCLI.run(["open", "--wait", "/x.md"]) { request, _ in
      calls += 1
      return WorkbenchIPCReply(result: request.command == "file.isOpen" ? .text("closed") : .ok)
    }
    XCTAssertEqual(done, WorkbenchCLI.Outcome(output: nil, code: 0))
    XCTAssertEqual(calls, 2)
  }

  func testHelpFlagWorksAtAnyDepth() {
    XCTAssertEqual(run(["agent", "launch", "--help"], reply: .ok), WorkbenchCLI.Outcome(output: WorkbenchCLI.help("agent launch"), code: 0))
    XCTAssertEqual(run(["help", "agent", "launch"], reply: .ok).output, WorkbenchCLI.help("agent launch"))
    XCTAssertEqual(run(["-h"], reply: .ok).output, WorkbenchCLI.help())
  }

  func testMessagesFollowTheSavedLanguageButCodesDoNot() throws {
    let file = URL.temporaryDirectory.appending(path: "clair-lang-\(UUID().uuidString.prefix(8)).json")
    addTeardownBlock { try? FileManager.default.removeItem(at: file); ClairLanguage.current = .english }
    try Data(#"{"choices":{"language":"日本語"}}"#.utf8).write(to: file)
    WorkbenchCLI.loadLanguage(from: file)
    XCTAssertTrue(WorkbenchCLI.help().hasPrefix("使い方: clair open"))
    let down = WorkbenchCLI.run(["tab.next"]) { _, _ in throw WorkbenchIPCError.notRunning }
    XCTAssertEqual(down.output, #"{"error":{"code":"notRunning","message":"Clair が起動していません"},"ok":false}"#)
    XCTAssertEqual(CommandRegistry.workbench.execute("pane.splitRight", ["x": .int(1)], state: &Host().state), .failure(CommandError(.invalidInput, "不明な引数です: x")))
    WorkbenchCLI.loadLanguage(from: file.appendingPathExtension("missing"))
    XCTAssertEqual(ClairLanguage.current, .english)
  }

  func testHelpListsCommandsWithArguments() {
    let all = WorkbenchCLI.help()
    XCTAssertTrue(all.hasPrefix("usage: clair open"))
    for id in CommandRegistry.workbench.commands.map(\.id) { XCTAssertTrue(all.contains("\n\(id.replacingOccurrences(of: ".", with: " "))"), id) }
    let projects = WorkbenchCLI.help("project")
    XCTAssertTrue(projects.contains("\nproject list\n"))
    XCTAssertTrue(projects.contains("\nproject rename name=<string> label=<string>\n"))
    XCTAssertTrue(projects.contains("— write, user-only"))
    XCTAssertFalse(projects.contains("\nagent "))
    XCTAssertTrue(WorkbenchCLI.help("agent launch").contains("[direction=right|down]"))
  }

  func testPreviewArgumentParsing() throws {
    let cwd = FileManager.default.currentDirectoryPath
    let preview = try XCTUnwrap(WorkbenchCLI.parse(["preview", "artifact.html"]))
    XCTAssertEqual(preview.command, "file.preview")
    XCTAssertEqual(preview.input, ["path": .string(cwd + "/artifact.html")])
    XCTAssertNil(WorkbenchCLI.parse(["preview"]))
    XCTAssertNil(WorkbenchCLI.parse(["preview", "a.html", "b.html"]))
  }

  func testBlockedCallDoesNotHoldUpNextCall() throws {
    let url = URL(fileURLWithPath: "/tmp/clair-ipc-\(UUID().uuidString.prefix(8))/c.sock")
    let release = DispatchSemaphore(value: 0)
    let server = WorkbenchIPCServer(socket: url) { req in
      if req.command == "slow" { release.wait() }  // stands in for a call parked on an approval card
      return .success(.ok)
    }
    try server.start()
    addTeardownBlock { release.signal(); server.stop(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let slow = expectation(description: "slow")
    DispatchQueue.global().async { _ = try? WorkbenchIPC.call(WorkbenchIPCRequest(command: "slow", input: [:]), socket: url); slow.fulfill() }
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertNoThrow(try WorkbenchIPC.call(WorkbenchIPCRequest(command: "fast", input: [:]), socket: url, timeout: 2))
    release.signal()
    wait(for: [slow], timeout: 3)
  }
}

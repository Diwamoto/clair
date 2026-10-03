import Foundation
import XCTest

@testable import ClairWorkspace

/// ADR-0022: the transport-free half of the Claude Code IDE connection.
@MainActor final class ClaudeIDETests: XCTestCase {
  func testLockFileIsOwnerOnlyAndNamesTheIDE() throws {
    let dir = URL.temporaryDirectory.appending(path: "clair-ide-\(UUID().uuidString)/ide")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let token = ClaudeIDE.newToken()
    XCTAssertEqual(token.count, 32)
    XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    XCTAssertNotEqual(token, ClaudeIDE.newToken())
    let lock = try ClaudeIDE.writeLock(port: 51234, token: token, folders: ["/p/a", "/p/b"], pid: 42, directory: dir)
    XCTAssertEqual(lock.lastPathComponent, "51234.lock")
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: lock)) as? [String: Any])
    XCTAssertEqual(json["ideName"] as? String, "Clair")
    XCTAssertEqual(json["transport"] as? String, "ws")
    XCTAssertEqual(json["authToken"] as? String, token)
    XCTAssertEqual(json["workspaceFolders"] as? [String], ["/p/a", "/p/b"])
    XCTAssertEqual(json["pid"] as? Int, 42)
    let attrs = try FileManager.default.attributesOfItem(atPath: lock.path)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
    XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    // Rewriting replaces it in place; removal deletes it.
    try ClaudeIDE.writeLock(port: 51234, token: token, folders: ["/p/c"], pid: 42, directory: dir)
    let again = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: lock)) as? [String: Any])
    XCTAssertEqual(again["workspaceFolders"] as? [String], ["/p/c"])
    ClaudeIDE.removeLock(port: 51234, directory: dir)
    XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    XCTAssertEqual(ClaudeIDE.lockDirectory(environment: ["CLAUDE_CONFIG_DIR": "/cfg"]).path, "/cfg/ide")
    XCTAssertEqual(ClaudeIDE.lockDirectory(environment: [:], home: URL(fileURLWithPath: "/h")).path, "/h/.claude/ide")
  }

  func testTokenComparisonNeedsTheWholeToken() {
    XCTAssertTrue(ClaudeIDE.tokenMatches("abc123", "abc123"))
    XCTAssertFalse(ClaudeIDE.tokenMatches("abc12", "abc123"))
    XCTAssertFalse(ClaudeIDE.tokenMatches("abc124", "abc123"))
    XCTAssertFalse(ClaudeIDE.tokenMatches("", ""))
  }

  private func object(_ text: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  func testDispatchAnswersInitializeToolsAndDeferredCalls() throws {
    var replies: [String] = []
    var pending: (@MainActor (ClaudeIDEToolResult) -> Void)?
    var called: (String, [String: Any])?
    func send(_ text: String) {
      ClaudeIDE.handle(text, call: { tool, args, done in called = (tool, args); pending = done }, reply: { replies.append($0) })
    }
    send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
    let initialize = try object(replies.removeLast())
    XCTAssertEqual((initialize["result"] as? [String: Any])?["protocolVersion"] as? String, "2024-11-05")
    send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    XCTAssertTrue(replies.isEmpty)  // notifications get no answer
    send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    let tools = try XCTUnwrap(((try object(replies.removeLast()))["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    XCTAssertEqual(
      Set(tools.compactMap { $0["name"] as? String }),
      ["openFile", "openDiff", "getCurrentSelection", "getLatestSelection", "getOpenEditors", "getWorkspaceFolders", "getDiagnostics",
       "checkDocumentDirty", "saveDocument", "close_tab", "closeAllDiffTabs"])
    // openDiff answers only when the user decides.
    send(#"{"jsonrpc":"2.0","id":"7","method":"tools/call","params":{"name":"openDiff","arguments":{"tab_name":"t"}}}"#)
    XCTAssertEqual(called?.0, "openDiff")
    XCTAssertEqual(called?.1["tab_name"] as? String, "t")
    XCTAssertTrue(replies.isEmpty)
    pending?(.text(["FILE_SAVED", "new text"]))
    let saved = try object(replies.removeLast())
    XCTAssertEqual(saved["id"] as? String, "7")
    let content = try XCTUnwrap((saved["result"] as? [String: Any])?["content"] as? [[String: Any]])
    XCTAssertEqual(content.compactMap { $0["text"] as? String }, ["FILE_SAVED", "new text"])
    send(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"rm -rf"}}"#)
    XCTAssertEqual((try object(replies.removeLast())["error"] as? [String: Any])?["code"] as? Int, -32602)
    send(#"{"jsonrpc":"2.0","id":9,"method":"nope"}"#)
    XCTAssertEqual((try object(replies.removeLast())["error"] as? [String: Any])?["code"] as? Int, -32601)
    send("not json")
    XCTAssertEqual((try object(replies.removeLast())["error"] as? [String: Any])?["code"] as? Int, -32700)
  }

  func testNotificationsCarryLSPStylePositions() throws {
    let sel = try object(ClaudeIDE.selectionChanged(path: "/p/a b.go", text: "x", startLine: 1, startCharacter: 2, endLine: 1, endCharacter: 3))
    XCTAssertEqual(sel["method"] as? String, "selection_changed")
    let params = try XCTUnwrap(sel["params"] as? [String: Any])
    XCTAssertEqual(params["fileUrl"] as? String, "file:///p/a%20b.go")
    XCTAssertEqual((params["selection"] as? [String: Any])?["isEmpty"] as? Bool, false)
    let mention = try object(ClaudeIDE.atMentioned(path: "/p/a.go", lineStart: 4, lineEnd: 9))
    XCTAssertEqual(mention["method"] as? String, "at_mentioned")
    XCTAssertEqual((mention["params"] as? [String: Any])?["lineEnd"] as? Int, 9)
    XCTAssertNil((try object(ClaudeIDE.atMentioned(path: "/p/a.go", lineStart: nil, lineEnd: nil))["params"] as? [String: Any])?["lineStart"])
  }

  func testProposalPathsStayInsideTheProposalFolder() {
    let dir = ClaudeIDE.proposalDirectory.path
    XCTAssertTrue(ClaudeIDE.isProposal(dir + "/abc/main.go"))
    XCTAssertFalse(ClaudeIDE.isProposal(dir + "/../workspace.json"))
    XCTAssertFalse(ClaudeIDE.isProposal("/etc/passwd"))
    var s = WorkbenchState()
    s.projects = [WorkbenchProject(name: "P", path: "/tmp")]
    s.project = "P"
    XCTAssertNotNil(
      CommandRegistry.workbench.execute(
        "diff.open", ["path": .string("a.go"), "staged": .bool(false), "untracked": .bool(false), "proposal": .string("/etc/passwd")], state: &s
      ).failure)
    let tab: CommandInput = ["path": .string("a.go"), "staged": .bool(false), "untracked": .bool(false), "proposal": .string(dir + "/x/a.go")]
    XCTAssertNil(CommandRegistry.workbench.execute("diff.open", tab, state: &s).failure)
    XCTAssertEqual(s.activeDiff?.proposal, dir + "/x/a.go")
    s.dropProposalTabs()
    XCTAssertNil(s.activeDiff)
    XCTAssertTrue(s.diffTabs.isEmpty)
  }
}

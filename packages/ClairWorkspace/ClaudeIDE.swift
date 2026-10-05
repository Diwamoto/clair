import Foundation

// ADR-0022: Clair as a Claude Code IDE. Claude Code started in a Clair terminal finds Clair through
// `CLAUDE_CODE_SSE_PORT` (or a lock file under `~/.claude/ide`, for `/ide`), connects to a localhost WebSocket
// with the lock file's token, and speaks MCP over it: Clair answers editor questions (selection, open editors,
// diagnostics) and shows Claude's proposed edits as a diff the user accepts or rejects. This file is the transport-
// free part: lock files, the token, the tool list and the JSON-RPC dispatch. The socket is `ClaudeIDEServer`; the
// tools themselves are answered by the workbench store.

/// What a tool call returns: text items (MCP `content`), or a JSON-RPC error.
public enum ClaudeIDEToolResult: Sendable, Equatable {
  case text([String])
  case error(code: Int, message: String)
}

public enum ClaudeIDE {
  public static let ideName = "Clair"
  static let protocolVersion = "2024-11-05"

  /// `$CLAUDE_CONFIG_DIR/ide`, else `~/.claude/ide`: where Claude Code looks for running IDEs.
  public static func lockDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = .homeDirectory) -> URL {
    if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty { return URL(fileURLWithPath: config).appending(path: "ide") }
    return home.appending(path: ".claude/ide")
  }

  /// 128 random bits as 32 lowercase hex characters (the format Claude Code's own IDE extensions use).
  public static func newToken() -> String {
    var rng = SystemRandomNumberGenerator()
    return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
  }

  /// Writes `<port>.lock` atomically, owner-only (directory 0700, file 0600): the token in it is the only thing that
  /// lets a local process talk to the socket.
  @discardableResult
  public static func writeLock(port: UInt16, token: String, folders: [String], pid: Int32 = ProcessInfo.processInfo.processIdentifier, directory: URL)
    throws -> URL
  {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let body: [String: Any] = ["pid": pid, "workspaceFolders": folders, "ideName": ideName, "transport": "ws", "authToken": token]
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let lock = directory.appending(path: "\(port).lock")
    let temp = directory.appending(path: ".\(port).lock.\(UUID().uuidString)")
    guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    if fm.fileExists(atPath: lock.path) { _ = try fm.replaceItemAt(lock, withItemAt: temp) } else { try fm.moveItem(at: temp, to: lock) }
    return lock
  }

  public static func removeLock(port: UInt16, directory: URL) {
    try? FileManager.default.removeItem(at: directory.appending(path: "\(port).lock"))
  }

  /// Where proposed file texts wait while their diff is open; nothing outside it can be shown as a proposal.
  public static var proposalDirectory: URL { ClairChannel.current.dataURL.appending(path: "proposals") }

  public static func isProposal(_ path: String) -> Bool {
    let dir = proposalDirectory.standardizedFileURL.path + "/"
    let p = URL(fileURLWithPath: path).standardizedFileURL.path
    return p.hasPrefix(dir) && !p.dropFirst(dir.count).split(separator: "/").contains("..")
  }

  /// Compares the client's token without leaking how much of it matched.
  public static func tokenMatches(_ given: String, _ expected: String) -> Bool {
    let a = Array(given.utf8), b = Array(expected.utf8)
    guard a.count == b.count, !b.isEmpty else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  /// The WebSocket subprotocol to accept. Claude Code offers `mcp` and never finishes opening a socket whose upgrade
  /// does not select it (the native build waits out its 30 s connect timeout; the npm build fails at once).
  public static func subprotocol(offered: [String]) -> String? {
    offered.contains("mcp") ? "mcp" : nil
  }

  // MARK: tools

  private static func object(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
  }

  /// The tools Claude Code calls on an IDE, with the input shapes its extensions accept.
  nonisolated(unsafe) static let tools: [[String: Any]] = [
    ["name": "openFile", "description": "Open a file in the editor and optionally select a range of text",
     "inputSchema": object([
      "filePath": ["type": "string", "description": "Path to the file to open"],
      "preview": ["type": "boolean"], "startText": ["type": "string"], "endText": ["type": "string"],
      "selectToEndOfLine": ["type": "boolean"], "makeFrontmost": ["type": "boolean"],
     ], required: ["filePath"])],
    ["name": "openDiff", "description": "Open a diff view comparing old file content with new file content",
     "inputSchema": object([
      "old_file_path": ["type": "string"], "new_file_path": ["type": "string"],
      "new_file_contents": ["type": "string"], "tab_name": ["type": "string"],
     ], required: ["old_file_path", "new_file_path", "new_file_contents", "tab_name"])],
    ["name": "getCurrentSelection", "description": "Get the current text selection in the editor", "inputSchema": object([:])],
    ["name": "getLatestSelection", "description": "Get the most recent text selection (even if not in the active editor)", "inputSchema": object([:])],
    ["name": "getOpenEditors", "description": "Get information about currently open editors", "inputSchema": object([:])],
    ["name": "getWorkspaceFolders", "description": "Get all workspace folders currently open in the IDE", "inputSchema": object([:])],
    ["name": "getDiagnostics", "description": "Get language diagnostics (errors, warnings) from the editor",
     "inputSchema": object(["uri": ["type": "string", "description": "Optional file URI; all open files when omitted"]])],
    ["name": "checkDocumentDirty", "description": "Check if a document has unsaved changes",
     "inputSchema": object(["filePath": ["type": "string"]], required: ["filePath"])],
    ["name": "saveDocument", "description": "Save a document with unsaved changes",
     "inputSchema": object(["filePath": ["type": "string"]], required: ["filePath"])],
    ["name": "close_tab", "description": "Close a tab by name", "inputSchema": object(["tab_name": ["type": "string"]], required: ["tab_name"])],
    ["name": "closeAllDiffTabs", "description": "Close all diff tabs in the editor", "inputSchema": object([:])],
  ]

  static let toolNames: Set<String> = Set(tools.compactMap { $0["name"] as? String })

  /// One JSON-RPC message from Claude Code. `call` runs a tool and may answer later (`openDiff` waits for the user);
  /// `reply` sends a response. Notifications (no `id`) get no reply.
  @MainActor
  public static func handle(
    _ text: String, call: (_ tool: String, _ arguments: [String: Any], _ done: @escaping @MainActor (ClaudeIDEToolResult) -> Void) -> Void,
    reply: @escaping @MainActor (String) -> Void
  ) {
    guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
      return reply(response(nil, error: (-32700, "Parse error")))
    }
    guard let id = message["id"], let method = message["method"] as? String else { return }  // a notification or a response
    switch method {
    case "initialize":
      reply(response(id, result: [
        "protocolVersion": protocolVersion,
        "capabilities": ["tools": ["listChanged": true], "prompts": ["listChanged": true], "logging": [String: Any]()],
        "serverInfo": ["name": "clair", "version": "1"],
      ]))
    case "ping": reply(response(id, result: [String: Any]()))
    case "tools/list": reply(response(id, result: ["tools": tools]))
    case "prompts/list": reply(response(id, result: ["prompts": [Any]()]))
    case "resources/list": reply(response(id, result: ["resources": [Any]()]))
    case "tools/call":
      let params = message["params"] as? [String: Any]
      guard let name = params?["name"] as? String, toolNames.contains(name) else {
        return reply(response(id, error: (-32602, "Unknown tool")))
      }
      let arguments = params?["arguments"] as? [String: Any] ?? [:]
      call(name, arguments) { result in
        switch result {
        case .text(let items):
          reply(response(id, result: ["content": items.map { ["type": "text", "text": $0] }]))
        case .error(let code, let text):
          reply(response(id, error: (code, text)))
        }
      }
    default: reply(response(id, error: (-32601, "Method not found: \(method)")))
    }
  }

  /// `selection_changed`, sent as the user moves the caret or selects. Lines and characters are 0-based (LSP style).
  public static func selectionChanged(
    path: String, text: String, startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int
  ) -> String {
    notification("selection_changed", [
      "text": text, "filePath": path, "fileUrl": URL(fileURLWithPath: path).absoluteString,
      "selection": [
        "start": ["line": startLine, "character": startCharacter], "end": ["line": endLine, "character": endCharacter],
        "isEmpty": startLine == endLine && startCharacter == endCharacter,
      ],
    ])
  }

  /// `at_mentioned`: puts `path` (lines `lineStart...lineEnd`, 0-based) into Claude Code's prompt as context.
  public static func atMentioned(path: String, lineStart: Int?, lineEnd: Int?) -> String {
    var params: [String: Any] = ["filePath": path]
    if let lineStart { params["lineStart"] = lineStart }
    if let lineEnd { params["lineEnd"] = lineEnd }
    return notification("at_mentioned", params)
  }

  /// A JSON value as compact text, for tool results that carry JSON.
  public static func json(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func notification(_ method: String, _ params: [String: Any]) -> String {
    json(["jsonrpc": "2.0", "method": method, "params": params])
  }

  private static func response(_ id: Any?, result: [String: Any]? = nil, error: (Int, String)? = nil) -> String {
    var o: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
    if let result { o["result"] = result }
    if let error { o["error"] = ["code": error.0, "message": error.1] }
    return json(o)
  }
}

extension WorkbenchDiffTab {
  /// The tab a `diff.*` command names.
  static func from(_ i: CommandInput) -> WorkbenchDiffTab {
    WorkbenchDiffTab(
      path: i["path"]!.string!, staged: i["staged"]!.bool!, untracked: i["untracked"]!.bool!, against: i["against"]?.string,
      proposal: i["proposal"]?.string)
  }
}

extension WorkbenchState {
  /// Proposal tabs belong to the Claude Code call that is waiting on them; after a relaunch nobody is, so they go.
  public mutating func dropProposalTabs() {
    diffTabs.removeAll { $0.proposal != nil }
    if activeDiff?.proposal != nil { activeDiff = nil }
    tabOrder.removeAll { if case .diff(let t) = $0 { t.proposal != nil } else { false } }
    for name in layouts.keys {
      layouts[name]?.diffTabs.removeAll { $0.proposal != nil }
      if layouts[name]?.activeDiff?.proposal != nil { layouts[name]?.activeDiff = nil }
      layouts[name]?.tabOrder.removeAll { if case .diff(let t) = $0 { t.proposal != nil } else { false } }
    }
  }
}

extension WorkbenchGit {
  /// `path` (left; empty when it does not exist yet) → the proposed text (right), whole file as context.
  public static func proposalDiff(_ root: String, _ path: String, proposal: String) -> String {
    let file = root + "/" + path
    let left = FileManager.default.fileExists(atPath: file) ? path : "/dev/null"
    return run(root, ["diff", "--no-index", "--unified=1000000", "--", left, proposal], merge: false).out
  }
}

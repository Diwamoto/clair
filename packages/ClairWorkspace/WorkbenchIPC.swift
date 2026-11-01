import ClairShared
import Darwin
import Foundation

// V02: user-scoped local IPC for the workbench Command Registry. The GUI
// process (state owner, ADR-0007) serves `handler`; `clair` CLI is a client.
// Wire: one connection = one newline-terminated JSON request, one JSON reply.
// `confirmed` is deliberately NOT on the wire: a destructive command returns
// `confirmationRequired` and only native GUI approval can run it (V03 relies on this).
// Invariants/test matrix: docs/plans/clair-v02-cli-ipc.md.

public struct WorkbenchIPCRequest: Codable, Equatable, Sendable {
  public var command: String
  public var input: CommandInput
  /// `mcp` = an AI agent's call through `clair mcp serve`; the GUI applies `MCPGate` (V03).
  public var via: Via?
  public enum Via: String, Codable, Sendable { case mcp }
  /// V16: `root#pane` of the Clair terminal the CLI runs in (`CLAIR_TERMINAL_KEY`). Such calls go through
  /// `MCPGate`, and the GUI passes it to agent.* as `parent`. Advisory: a process can unset its environment,
  /// so this routes well-behaved agents to approval; it is not an authentication boundary.
  public var caller: String?
  public init(command: String, input: CommandInput = [:], via: Via? = nil, caller: String? = nil) {
    self.command = command; self.input = input; self.via = via; self.caller = caller
  }
}

public struct WorkbenchIPCReply: Codable, Equatable, Sendable {
  public var result: CommandResult?
  public var error: CommandError?
}

public enum WorkbenchIPCError: Error, Equatable {
  case socket(String)  // setup/connect/io failure
  case notRunning  // no server behind the socket path
  case alreadyRunning
  case badMessage
}

public enum WorkbenchIPC {
  public static let maxMessageBytes = 1 << 20

  /// `CLAIR_COMMAND_SOCKET` overrides (tests; sun_path is limited to ~104 bytes).
  public static var defaultSocketURL: URL {
    if let p = ProcessInfo.processInfo.environment["CLAIR_COMMAND_SOCKET"] { return URL(fileURLWithPath: p) }
    return ClairChannel.current.dataURL.appending(path: "command.sock")
  }

  static func address(_ url: URL) throws -> sockaddr_un {
    var a = sockaddr_un()
    let bytes = Array(url.path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else { throw WorkbenchIPCError.socket("socket path too long") }
    a.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes) }
    return a
  }

  static func connectFD(_ url: URL, timeout: TimeInterval) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw WorkbenchIPCError.socket(String(cString: strerror(errno))) }
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var a = try address(url)
    let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard rc == 0 else {
      let e = errno
      close(fd)
      throw e == ENOENT || e == ECONNREFUSED ? WorkbenchIPCError.notRunning : .socket(String(cString: strerror(e)))
    }
    return fd
  }

  /// Reads until newline/EOF, capped at `maxMessageBytes`.
  static func readLine(_ fd: Int32) -> Data? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count <= maxMessageBytes {
      let n = read(fd, &buf, buf.count)
      if n <= 0 { break }
      data.append(contentsOf: buf[0..<n])
      if buf[0..<n].contains(10) { break }
    }
    return data.isEmpty || data.count > maxMessageBytes ? nil : data
  }

  static func writeAll(_ fd: Int32, _ data: Data) {
    var d = data
    d.append(10)
    d.withUnsafeBytes { raw in
      var off = 0
      while off < raw.count {
        let n = write(fd, raw.baseAddress! + off, raw.count - off)
        if n <= 0 { return }
        off += n
      }
    }
  }

  /// Blocking client call. Throws `.notRunning` when no GUI serves the socket.
  public static func call(_ request: WorkbenchIPCRequest, socket url: URL = defaultSocketURL, timeout: TimeInterval = 5) throws -> WorkbenchIPCReply {
    let fd = try connectFD(url, timeout: timeout)
    defer { close(fd) }
    writeAll(fd, try JSONEncoder().encode(request))
    guard let data = readLine(fd), let reply = try? JSONDecoder().decode(WorkbenchIPCReply.self, from: data) else {
      throw WorkbenchIPCError.badMessage
    }
    return reply
  }
}

/// Serves the registry on a private Unix socket (dir 0700, socket 0600) and
/// drops any peer whose uid differs from `allowedUID`. One thread per connection;
/// the handler serializes against GUI state on the main actor.
public final class WorkbenchIPCServer: @unchecked Sendable {
  public typealias Handler = @Sendable (WorkbenchIPCRequest) -> Result<CommandResult, CommandError>

  private let url: URL
  private let allowedUID: uid_t
  private let handler: Handler
  private var listener: Int32 = -1

  public init(socket url: URL = WorkbenchIPC.defaultSocketURL, allowedUID: uid_t = geteuid(), handler: @escaping Handler) {
    self.url = url; self.allowedUID = allowedUID; self.handler = handler
  }

  public func start() throws {
    signal(SIGPIPE, SIG_IGN)  // a client that vanished mid-reply must not kill the GUI
    let dir = url.deletingLastPathComponent().path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var st = stat()
    if lstat(url.path, &st) == 0 {
      // A live server owns the path; anything else (stale socket) is removed. Never delete non-sockets.
      if (try? WorkbenchIPC.connectFD(url, timeout: 1)).map({ close($0) }) != nil { throw WorkbenchIPCError.alreadyRunning }
      guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == geteuid() else { throw WorkbenchIPCError.socket("path is occupied") }
      unlink(url.path)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw WorkbenchIPCError.socket(String(cString: strerror(errno))) }
    var a = try WorkbenchIPC.address(url)
    let old = umask(0o177)  // socket is created 0600, never briefly wider
    let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    umask(old)
    guard rc == 0, listen(fd, 8) == 0 else {
      let m = String(cString: strerror(errno)); close(fd); throw WorkbenchIPCError.socket(m)
    }
    listener = fd
    Thread.detachNewThread { [self] in serve(fd) }
  }

  public func stop() {
    guard listener >= 0 else { return }
    let fd = listener
    listener = -1
    shutdown(fd, SHUT_RDWR); close(fd)
    unlink(url.path)
  }

  private func serve(_ fd: Int32) {
    while true {
      let c = accept(fd, nil, nil)
      if c < 0 { return }  // listener closed by stop()
      // A call may block on a GUI approval card for a minute; it must not hold up the next `clair …`.
      Thread.detachNewThread { [self] in handle(c) }
    }
  }

  private func handle(_ c: Int32) {
    defer { close(c) }
    var tv = timeval(tv_sec: 5, tv_usec: 0)  // a silent client must not wedge a handler
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(c, &uid, &gid) == 0, uid == allowedUID else { return }
    guard let data = WorkbenchIPC.readLine(c), let req = try? JSONDecoder().decode(WorkbenchIPCRequest.self, from: data) else {
      WorkbenchIPC.writeAll(c, (try? JSONEncoder().encode(WorkbenchIPCReply(error: CommandError(.invalidInput, "malformed request")))) ?? Data())
      return
    }
    var reply = WorkbenchIPCReply()
    switch handler(req) {
    case .success(let r): reply.result = r
    case .failure(let e): reply.error = e
    }
    WorkbenchIPC.writeAll(c, (try? JSONEncoder().encode(reply)) ?? Data())
  }
}

/// CLI argument → request. `clair open path[:line[:col]]` is `file.open` (a relative path is resolved against the
/// caller's cwd, since the GUI's differs); otherwise `clair <group> <command> [key=value …]` with bool/int/double/string inference.
// ponytail: col is parsed but dropped (the editor reveal is line-only); a file literally named `x:12` needs `clair file open path=…`;
// value inference can't force a numeric-looking string, add `key:=json` when a string param needs it.
public enum WorkbenchCLI {
  /// What one invocation leaves behind: a line for stdout (nil = silent) and the exit code.
  public struct Outcome: Equatable, Sendable {
    public let output: String?
    public let code: Int32
  }

  public typealias Call = (WorkbenchIPCRequest, TimeInterval) throws -> WorkbenchIPCReply

  // Output contract (ADR-0026): one JSON line on stdout, `ok` is true exactly when the exit code is 0.
  // `error.code` and the JSON keys are stable; `error.message` follows the language setting.
  public static func success(_ result: Any = NSNull()) -> Outcome {
    Outcome(output: line(["ok": true, "result": result]), code: 0)
  }

  /// exit 1 command error, 2 usage, 3 Clair unreachable. `result` is the last state a wait saw.
  public static func failure(_ code: String, _ message: String, exit: Int32, result: Any? = nil) -> Outcome {
    var object: [String: Any] = ["ok": false, "error": ["code": code, "message": message]]
    object["result"] = result
    return Outcome(output: line(object), code: exit)
  }

  public static func usageFailure(_ usage: String) -> Outcome { failure("usage", tr("usage:") + " " + usage, exit: 2) }

  public static var daemonNotRunning: Outcome { failure("notRunning", tr("The Clair daemon is not running"), exit: 3) }

  private static func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
  }

  /// The reply's value without Swift's enum encoding (`{"text":{"_0":"x"}}` → `"x"`); the wire format stays as it is.
  private static func payload(_ result: CommandResult, command: String) -> Any {
    switch result {
    case .ok: return NSNull()
    case .pane(let pane): return ["pane": pane]
    // finder.* answers in JSON text or a bare proposal id.
    case .text(let text) where command.hasPrefix("finder."):
      return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? text
    default:
      guard let data = try? JSONEncoder().encode(result), let tagged = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let value = tagged.values.first
      else { return NSNull() }
      return unwrapped(value)
    }
  }

  private static func unwrapped(_ value: Any) -> Any {
    if let object = value as? [String: Any] {
      if object.count == 1, let only = object["_0"] { return unwrapped(only) }
      return object.mapValues(unwrapped)
    }
    return (value as? [Any])?.map(unwrapped) ?? value
  }

  private static func outcome(_ reply: WorkbenchIPCReply, command: String) -> Outcome {
    if let error = reply.error { return failure(error.code.rawValue, error.message, exit: 1) }
    return success(payload(reply.result ?? .ok, command: command))
  }

  /// Every call except the two that own stdout (`attach`, `mcp serve`) and `daemon`, which needs the daemon client.
  public static func run(_ arguments: [String], call: Call = { try WorkbenchIPC.call($0, timeout: $1) }) -> Outcome {
    var args = arguments
    if let flag = args.firstIndex(where: { $0 == "--help" || $0 == "-h" }) {
      return Outcome(output: help(args[..<flag].joined(separator: " ")), code: 0)
    }
    if args.first == "help" { return Outcome(output: help(args.dropFirst().joined(separator: " ")), code: 0) }
    // `clair open --wait <path>` ($VISUAL / git editor): returns once that file has no tab in any open Project.
    let wait = args.first == "open" && args.count == 3 && args[1] == "--wait"
    if wait { args.remove(at: 1) }
    guard let request = parse(args) else { return usageFailure(usage) }
    do {
      if request.command == "agent.wait" || request.command == "finder.wait" { return try poll(request, call: call) }
      let reply = try call(request, 90)  // may wait on a GUI approval card (60 s)
      guard wait, reply.error == nil else { return outcome(reply, command: request.command) }
      let check = WorkbenchIPCRequest(command: "file.isOpen", input: ["path": request.input["path"]!], caller: request.caller)
      // ponytail: 0.5 s polling like agent.wait; a GUI push on tab close if latency or IPC load matters.
      while case .text("open")? = try call(check, 5).result { Thread.sleep(forTimeInterval: 0.5) }
      // As $VISUAL (Ctrl+G in Claude) stdout lands in the caller's terminal, so success prints nothing.
      return Outcome(output: nil, code: 0)
    } catch {
      let down = (error as? WorkbenchIPCError) == .notRunning
      return failure(down ? "notRunning" : "ipcFailure", down ? tr("Clair is not running") : "\(error)", exit: 3)
    }
  }

  /// V16 `clair agent wait key=<root#pane>`: until that delegated agent exits. ADR-0025 `clair finder wait id=<proposal>`:
  /// until the user applies or rejects it (rejected exits 1). `timeout=<s>` (default 1800) exits 1 too. Client-side: one IPC call stays short.
  private static func poll(_ wait: WorkbenchIPCRequest, call: Call) throws -> Outcome {
    let agent = wait.command == "agent.wait"
    let deadline = Date().addingTimeInterval(TimeInterval(wait.input["timeout"]?.int ?? 1800))
    var request = wait
    request.command = agent ? "agent.status" : "finder.proposal"
    request.input["timeout"] = nil
    while true {
      let reply = try call(request, 5)
      guard reply.error == nil, let result = reply.result else { return outcome(reply, command: request.command) }
      let text = { if case .text(let t) = result { t } else { "" } }()
      let last = payload(result, command: request.command)
      if agent ? text.hasPrefix("exited") : !text.contains(#""state":"pending""#) {
        if agent || text.contains(#""state":"applied""#) { return success(last) }
        return failure("rejected", tr("The proposal was not applied"), exit: 1, result: last)
      }
      if Date() > deadline { return failure("timeout", tr("Timed out waiting"), exit: 1, result: last) }
      Thread.sleep(forTimeInterval: 1)
    }
  }

  /// The language chosen in Settings (GUI not needed: read from its saved workspace). Unreadable means the default.
  public static func loadLanguage(
    from url: URL = ProcessInfo.processInfo.environment["CLAIR_WORKSPACE_FILE"].map { URL(fileURLWithPath: $0) }
      ?? ClairChannel.current.dataURL.appending(path: "workspace.json")
  ) {
    struct Saved: Decodable { let choices: [String: String]? }
    let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    ClairLanguage.current = ClairLanguage(rawValue: saved?.choices?["language"] ?? "") ?? .english
  }

  public static func parse(_ args: [String]) -> WorkbenchIPCRequest? {
    var args = args
    guard var first = args.first else { return nil }
    if first == "preview" {
      guard args.count == 2, !args[1].isEmpty else { return nil }
      let path = args[1]
      let absolute = path.hasPrefix("/") ? path : URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path
      return WorkbenchIPCRequest(command: "file.preview", input: ["path": .string(absolute)], caller: caller)
    }
    // `clair reveal <path>`: show a file in Clair's file browser (relative to the caller's cwd).
    if first == "reveal" {
      guard args.count == 2, !args[1].isEmpty else { return nil }
      let path = args[1]
      let absolute = path.hasPrefix("/") ? path : URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
      return WorkbenchIPCRequest(command: "finder.reveal", input: ["path": .string(absolute)], caller: caller)
    }
    if first == "open" {
      guard args.count == 2 else { return nil }
      var parts = args[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      var numbers: [Int] = []
      while parts.count > 1, let n = Int(parts.last!) { numbers.insert(n, at: 0); parts.removeLast() }
      let path = parts.joined(separator: ":")
      var input: CommandInput = ["path": .string(path.hasPrefix("/") ? path : URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path)]
      if let line = numbers.first { input["line"] = .int(line) }
      return WorkbenchIPCRequest(command: "file.open", input: input, caller: caller)
    }
    // `clair project open path=.` → `project.open`. The dotted id still parses: installed hooks call `clair agent.report`.
    if !first.contains("."), args.count > 1, !args[1].contains("=") { first += "." + args.remove(at: 1) }
    var input = CommandInput()
    for a in args.dropFirst() {
      guard let eq = a.firstIndex(of: "="), eq != a.startIndex else { return nil }
      let (k, v) = (String(a[..<eq]), String(a[a.index(after: eq)...]))
      input[k] = v == "true" ? .bool(true) : v == "false" ? .bool(false) : Int(v).map(CommandArg.int) ?? Double(v).map(CommandArg.double) ?? .string(v)
      if pathArguments.contains("\(first) \(k)"), !v.hasPrefix("/") {
        input[k] = .string(URL(fileURLWithPath: v, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path)
      }
    }
    return WorkbenchIPCRequest(command: first, input: input, caller: caller)
  }

  /// `command key` pairs the GUI reads as file-system paths. The GUI's cwd is not the caller's, so a relative
  /// one is resolved here (`clair project open path=.`). Project-relative paths (tab.open, review.*) are left alone.
  static let pathArguments: Set<String> = [
    "project.open path", "project.addFolder path", "project.removeFolder path",
    "file.open path", "file.isOpen path", "file.preview path", "debug.breakpoint path",
    "finder.open path", "finder.reveal path", "finder.propose folder", "finder.addFavorite path", "finder.removeFavorite path",
  ]

  static let usage = "clair open [--wait] <path[:line[:col]]> | clair preview <html-path> | clair reveal <path> | clair <group> <command> [key=value ...] | clair help [group]"

  /// `clair help [group]`: every registry command a `clair <group> <command>` call can name, with its arguments.
  public static func help(_ prefix: String = "", registry: CommandRegistry = .workbench) -> String {
    let rows = registry.commands.filter { $0.id.hasPrefix(prefix.replacingOccurrences(of: " ", with: ".")) }.sorted { $0.id < $1.id }.map { d -> String in
      let params = d.params.map { p -> String in
        let arg = "\(p.name)=\(p.allowed?.joined(separator: "|") ?? "<\(p.kind.rawValue)>")"
        return p.required ? arg : "[\(arg)]"
      }
      let risk = ["read", "additive", "write", "destructive", "external"][d.risk.rawValue]
      return ([d.id.replacingOccurrences(of: ".", with: " ")] + params).joined(separator: " ") + "\n    \(tr(d.title)) — \(risk)\(d.aiAvailable ? "" : ", user-only")"
    }
    return """
      \(tr("usage:")) \(usage)
             clair agent wait key=<root#pane> [timeout=<s>] | clair finder wait id=<proposal> [timeout=<s>]
             clair mcp serve | clair daemon stop|status
      \(tr("Every call prints one JSON line: {\"ok\":true,\"result\":…} or {\"ok\":false,\"error\":{\"code\":…,\"message\":…}}."))
      \(tr("Exit 0 ok, 1 command error, 2 usage, 3 Clair not running."))
      \(tr("user-only: not offered to MCP; from a Clair terminal it waits for your approval in Clair."))


      """ + rows.joined(separator: "\n")
  }

  static var caller: String? { ProcessInfo.processInfo.environment["CLAIR_TERMINAL_KEY"].flatMap { $0.isEmpty ? nil : $0 } }
}

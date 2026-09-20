import Darwin
import Foundation

// V02: user-scoped local IPC for the workbench Command Registry. The GUI
// process (state owner, ADR-0007) serves `handler`; `clair` CLI is a client.
// Wire: one connection = one newline-terminated JSON request, one JSON reply.
// `confirmed` is deliberately NOT on the wire: a destructive command returns
// `confirmationRequired` and only native GUI approval can run it (V03 relies on this).
// Invariants/test matrix: docs/plans/clair-v2-v02-cli-ipc.md.

public struct WorkbenchIPCRequest: Codable, Equatable, Sendable {
  public var command: String
  public var input: CommandInput
  /// `mcp` = an AI agent's call through `clair mcp serve`; the GUI applies `MCPGate` (V03).
  public var via: Via?
  public enum Via: String, Codable, Sendable { case mcp }
  public init(command: String, input: CommandInput = [:], via: Via? = nil) { self.command = command; self.input = input; self.via = via }
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

  /// `CLAIR_V2_COMMAND_SOCKET` overrides (tests; sun_path is limited to ~104 bytes).
  public static var defaultSocketURL: URL {
    if let p = ProcessInfo.processInfo.environment["CLAIR_V2_COMMAND_SOCKET"] { return URL(fileURLWithPath: p) }
    return ClairV2Channel.current.dataURL.appending(path: "command.sock")
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
/// drops any peer whose uid differs from `allowedUID`. One thread, one
/// connection at a time: commands are tiny and must be serialized against GUI state anyway.
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
      defer { close(c) }
      var tv = timeval(tv_sec: 5, tv_usec: 0)  // a silent client must not wedge the loop
      setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      var uid: uid_t = 0, gid: gid_t = 0
      guard getpeereid(c, &uid, &gid) == 0, uid == allowedUID else { continue }
      guard let data = WorkbenchIPC.readLine(c), let req = try? JSONDecoder().decode(WorkbenchIPCRequest.self, from: data) else {
        WorkbenchIPC.writeAll(c, (try? JSONEncoder().encode(WorkbenchIPCReply(error: CommandError(.invalidInput, "malformed request")))) ?? Data())
        continue
      }
      var reply = WorkbenchIPCReply()
      switch handler(req) {
      case .success(let r): reply.result = r
      case .failure(let e): reply.error = e
      }
      WorkbenchIPC.writeAll(c, (try? JSONEncoder().encode(reply)) ?? Data())
    }
  }
}

/// CLI argument → request. `clair open path[:line[:col]]` is `tab.open`;
/// otherwise `clair <command-id> [key=value …]` with bool/int/double/string inference.
// ponytail: line/col are parsed but dropped (registry has no cursor command until the editor binds to V04/V05);
// value inference can't force a numeric-looking string, add `key:=json` when a string param needs it.
public enum WorkbenchCLI {
  public static func parse(_ args: [String]) -> WorkbenchIPCRequest? {
    guard let first = args.first else { return nil }
    if first == "open" {
      guard args.count == 2 else { return nil }
      var parts = args[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      while parts.count > 1, Int(parts.last!) != nil { parts.removeLast() }
      return WorkbenchIPCRequest(command: "tab.open", input: ["path": .string(parts.joined(separator: ":"))])
    }
    var input = CommandInput()
    for a in args.dropFirst() {
      guard let eq = a.firstIndex(of: "="), eq != a.startIndex else { return nil }
      let (k, v) = (String(a[..<eq]), String(a[a.index(after: eq)...]))
      input[k] = v == "true" ? .bool(true) : v == "false" ? .bool(false) : Int(v).map(CommandArg.int) ?? Double(v).map(CommandArg.double) ?? .string(v)
    }
    return WorkbenchIPCRequest(command: first, input: input)
  }
}

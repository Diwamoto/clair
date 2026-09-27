#if os(macOS)
import ClairEditorLanguage
import ClairPTY
import ClairWorkspace
import Darwin
import Foundation

/// One DAP connection per debug session. Delve is a child process, bound to a
/// private Unix socket (not a network port); the protocol layer is adapter-neutral.
actor ClairDAPClient {
  enum Failure: Error, LocalizedError {
    case missingAdapter, connectionFailed, disconnected, timeout(String), rejected(String)
    var errorDescription: String? {
      switch self {
      case .missingAdapter: "Delve (dlv) が見つかりません。go install github.com/go-delve/delve/cmd/dlv@latest で導入してください。"
      case .connectionFailed: "デバッガーに接続できませんでした"
      case .disconnected: "デバッガーとの接続が終了しました"
      case .timeout(let command): "デバッガーの応答がありません: \(command)"
      case .rejected(let message): message
      }
    }
  }

  private var adapterPID: Int32?
  private var socket: DAPUnixSocket?
  private var directory: URL?
  private var sequence = 0
  private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
  private let onEvent: @Sendable (Data) -> Void
  private let onDisconnect: @Sendable (String) -> Void

  init(onEvent: @escaping @Sendable (Data) -> Void, onDisconnect: @escaping @Sendable (String) -> Void) {
    self.onEvent = onEvent
    self.onDisconnect = onDisconnect
  }

  func start(root: String, executable: URL? = nil) async throws {
    let adapter = executable ?? LanguageServerCommand(executable: "dlv").resolve()
    guard let adapter else { throw Failure.missingAdapter }
    let dir = URL(fileURLWithPath: "/private/tmp").appending(path: "clair-dap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    directory = dir
    let path = dir.appending(path: "adapter.sock").path
    // Delve launches macOS debugserver into its own process group. Rejoin our
    // isolated adapter group before exec so a failed attach cannot orphan it.
    let shim = dir.appending(path: "debugserver-shim")
    try Self.debugserverShim.write(to: shim, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
    let arguments = [adapter.path, "dap", "--listen=unix:\(path)", "--only-same-user"]
    var environment = ProcessInfo.processInfo.environment
    environment["CLAIR_DEBUGSERVER_REAL_PATH"] = environment["DELVE_DEBUGSERVER_PATH"]
    environment["DELVE_DEBUGSERVER_PATH"] = shim.path
    environment["PATH"] = LanguageServerCommand.loginPath
    let variables = environment.map { "\($0.key)=\($0.value)" }
    var pid: Int32 = 0
    let error = Self.withCStrings(arguments, variables) { argv, envp in
      adapter.path.withCString { executable in
        root.withCString { cwd in clair_spawn_isolated(executable, argv, envp, cwd, &pid) }
      }
    }
    guard error == 0 else { cleanup(); throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
    adapterPID = pid
    var connected: DAPUnixSocket?
    for _ in 0..<100 {
      if let candidate = DAPUnixSocket.connect(path: path) { connected = candidate; break }
      if Darwin.kill(pid, 0) != 0 { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    guard let connected else { cleanup(); throw Failure.connectionFailed }
    socket = connected
    Task.detached { [weak self, connected] in
      var parser = DAPFrameParser()
      do {
        while let bytes = connected.read(), !bytes.isEmpty {
          for body in try parser.append(bytes) { await self?.receive(body) }
        }
        await self?.connectionLost("デバッガーとの接続が終了しました")
      } catch {
        await self?.connectionLost("デバッガーの応答が不正です: \(error)")
      }
    }
  }

  func request(_ command: String, arguments: Data = Data("{}".utf8)) async throws -> Data {
    guard let socket else { throw Failure.disconnected }
    sequence += 1
    let id = sequence
    let args = (try JSONSerialization.jsonObject(with: arguments))
    let payload = try JSONSerialization.data(withJSONObject: ["seq": id, "type": "request", "command": command, "arguments": args])
    let frame = try DAPFrameParser.encode(payload)
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do { try socket.send(frame) } catch {
        pending.removeValue(forKey: id)?.resume(throwing: error)
      }
      Task { [weak self] in
        let seconds = switch command {
        case "launch": 120  // Delve may compile a cold Go package before responding.
        case "attach": 60
        case "disconnect": 2
        default: 15
        }
        try? await Task.sleep(for: .seconds(seconds))
        await self?.expire(id, command: command)
      }
    }
  }

  private func expire(_ id: Int, command: String) {
    pending.removeValue(forKey: id)?.resume(throwing: Failure.timeout(command))
  }

  private func receive(_ body: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let type = object["type"] as? String else { return }
    if type == "response", let id = object["request_seq"] as? Int, let continuation = pending.removeValue(forKey: id) {
      if object["success"] as? Bool == false {
        continuation.resume(throwing: Failure.rejected(object["message"] as? String ?? "デバッガーが \(object["command"] ?? "要求") を拒否しました"))
      } else { continuation.resume(returning: body) }
    } else if type == "event" { onEvent(body) }
  }

  private func connectionLost(_ reason: String) {
    guard socket != nil else { return }
    cleanup()
    for (_, continuation) in pending { continuation.resume(throwing: Failure.disconnected) }
    pending.removeAll()
    onDisconnect(reason)
  }

  func stop() {
    cleanup()
    for (_, continuation) in pending { continuation.resume(throwing: Failure.disconnected) }
    pending.removeAll()
  }

  private static func withCStrings<T>(
    _ arguments: [String], _ environment: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
  ) -> T {
    var argv = arguments.map { strdup($0) } + [nil]
    var envp = environment.map { strdup($0) } + [nil]
    defer { argv.compactMap { $0 }.forEach { free($0) }; envp.compactMap { $0 }.forEach { free($0) } }
    return argv.withUnsafeMutableBufferPointer { a in
      envp.withUnsafeMutableBufferPointer { e in body(a.baseAddress!, e.baseAddress!) }
    }
  }

  static let debugserverShim = #"""
  #!/usr/bin/python3
  import os, shutil, subprocess, sys
  path = os.environ.get('CLAIR_DEBUGSERVER_REAL_PATH') or shutil.which('debugserver')
  if not path:
      candidates = ['/Library/Developer/CommandLineTools/Library/PrivateFrameworks/LLDB.framework/Versions/A/Resources/debugserver']
      try:
          developer = subprocess.check_output(['xcode-select', '--print-path'], text=True).strip()
          candidates.append(os.path.normpath(os.path.join(developer, '..', 'SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver')))
      except (OSError, subprocess.CalledProcessError):
          pass
      path = next((candidate for candidate in candidates if os.access(candidate, os.X_OK)), None)
  if not path:
      sys.exit('debugserver が見つかりません')
  os.setpgid(0, os.getpgid(os.getppid()))
  os.execv(path, [path, *sys.argv[1:]])
  """#

  private func cleanup() {
    socket?.close(); socket = nil
    if let pid = adapterPID {
      Task.detached {
        // Delve can be blocked in macOS debugserver. The whole isolated
        // process group must go, including any debuggee it spawned.
        _ = Darwin.kill(-pid, SIGTERM)
        try? await Task.sleep(for: .seconds(2))
        _ = Darwin.kill(-pid, SIGKILL)
        var status: Int32 = 0
        while Darwin.waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        clair_unregister_isolated(pid)
      }
    }
    adapterPID = nil
    if let directory { try? FileManager.default.removeItem(at: directory) }
    directory = nil
  }
}

private final class DAPUnixSocket: @unchecked Sendable {
  private let fd: Int32
  private let writeLock = NSLock()
  private init(_ fd: Int32) { self.fd = fd }

  static func connect(path: String) -> DAPUnixSocket? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { dst in dst.copyBytes(from: bytes.map(UInt8.init)) }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { Darwin.close(fd); return nil }
    return DAPUnixSocket(fd)
  }

  func send(_ data: Data) throws {
    writeLock.lock(); defer { writeLock.unlock() }
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var sent = 0
      while sent < raw.count {
        let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
        if n <= 0 { throw ClairDAPClient.Failure.disconnected }
        sent += n
      }
    }
  }

  func read() -> Data? {
    var bytes = [UInt8](repeating: 0, count: 8192)
    let n = Darwin.read(fd, &bytes, bytes.count)
    return n > 0 ? Data(bytes.prefix(n)) : nil
  }

  func close() { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
}
#endif

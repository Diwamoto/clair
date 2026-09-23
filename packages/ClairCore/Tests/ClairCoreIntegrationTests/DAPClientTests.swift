#if os(macOS)
import Foundation
import Darwin
import Testing
@testable import ClairAppKit

private actor EventBox {
  var names: [String] = []
  func add(_ name: String) { names.append(name) }
}

@Suite("DAP Unix transport") struct DAPClientTests {
  @Test func debugserverShimJoinsOwnedGroupWithoutKillingAttachTarget() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "clair-dap-group-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let shim = dir.appending(path: "shim")
    let fake = dir.appending(path: "fake-debugserver")
    let runner = dir.appending(path: "runner")
    let groupFile = dir.appending(path: "group")
    let stoppedFile = dir.appending(path: "stopped")
    try ClairDAPClient.debugserverShim.write(to: shim, atomically: true, encoding: .utf8)
    try #"""
    #!/usr/bin/python3
    import os, signal, sys, time
    def stop(*_):
        open(os.environ['STOPPED_FILE'], 'w').write('stopped')
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    open(os.environ['GROUP_FILE'], 'w').write(str(os.getpgrp()))
    while True: time.sleep(1)
    """#.write(to: fake, atomically: true, encoding: .utf8)
    try #"""
    #!/usr/bin/python3
    import os, subprocess, time
    os.setpgrp()
    subprocess.Popen([os.environ['DELVE_DEBUGSERVER_PATH'], '--attach=12345'], preexec_fn=os.setpgrp)
    while True: time.sleep(1)
    """#.write(to: runner, atomically: true, encoding: .utf8)
    for file in [shim, fake, runner] {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    let target = Process()
    target.executableURL = URL(fileURLWithPath: "/bin/sleep")
    target.arguments = ["30"]
    try target.run()
    defer { if target.isRunning { target.terminate() } }
    let adapter = Process()
    adapter.executableURL = runner
    var environment = ProcessInfo.processInfo.environment
    environment["DELVE_DEBUGSERVER_PATH"] = shim.path
    environment["CLAIR_DEBUGSERVER_REAL_PATH"] = fake.path
    environment["GROUP_FILE"] = groupFile.path
    environment["STOPPED_FILE"] = stoppedFile.path
    adapter.environment = environment
    adapter.standardOutput = FileHandle.nullDevice
    adapter.standardError = FileHandle.nullDevice
    try adapter.run()
    defer { if adapter.isRunning { _ = Darwin.kill(-adapter.processIdentifier, SIGKILL) } }
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: groupFile.path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let group = try String(contentsOf: groupFile, encoding: .utf8)
    #expect(Int32(group) == adapter.processIdentifier)
    _ = Darwin.kill(-adapter.processIdentifier, SIGTERM)
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: stoppedFile.path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: stoppedFile.path))
    #expect(target.isRunning)
  }

  @Test func requestEventAndDisconnect() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "clair-dap-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appending(path: "fake-dlv")
    try #"""
    #!/usr/bin/python3
    import json, socket, sys
    path = sys.argv[2].removeprefix('--listen=unix:')
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(1)
    conn, _ = listener.accept()
    def send(obj):
        body = json.dumps(obj).encode()
        conn.sendall(b'Content-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
    data = b''
    while True:
        while b'\r\n\r\n' not in data:
            data += conn.recv(4096)
        header, data = data.split(b'\r\n\r\n', 1)
        length = int(header.split(b':')[1].strip())
        while len(data) < length:
            data += conn.recv(4096)
        body, data = data[:length], data[length:]
        req = json.loads(body)
        send({'seq': 100, 'type': 'response', 'request_seq': req['seq'], 'command': req['command'], 'success': True, 'body': {'ok': True}})
        if req['command'] == 'initialize':
            send({'seq': 101, 'type': 'event', 'event': 'initialized', 'body': {}})
        if req['command'] == 'disconnect':
            break
    conn.close()
    listener.close()
    """#.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

    let box = EventBox()
    let client = ClairDAPClient(onEvent: { data in
      if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let event = object["event"] as? String {
        Task { await box.add(event) }
      }
    }, onDisconnect: { _ in })
    try await client.start(root: dir.path, executable: script)
    let response = try await client.request("initialize")
    #expect(String(decoding: response, as: UTF8.self).contains("\"ok\": true") || String(decoding: response, as: UTF8.self).contains("\"ok\":true"))
    _ = try await client.request("disconnect")
    await client.stop()
    for _ in 0..<20 where await box.names.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await box.names.contains("initialized"))
  }
}
#endif

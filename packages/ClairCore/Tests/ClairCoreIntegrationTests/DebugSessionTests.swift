#if os(macOS)
import Foundation
import Testing
import ClairWorkspace
@testable import ClairAppKit

@Suite("Go DAP session") struct DebugSessionTests {
  @MainActor @Test func launchConfiguresAndLoadsStoppedState() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "clair-debug-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let program = root.appending(path: "main.go")
    try "package main\nfunc main() {}\n".write(to: program, atomically: true, encoding: .utf8)
    let adapter = root.appending(path: "fake-dlv")
    try #"""
    #!/usr/bin/python3
    import json, socket, sys
    path = sys.argv[2].removeprefix('--listen=unix:')
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path); listener.listen(1)
    conn, _ = listener.accept()
    def send(obj):
        body = json.dumps(obj).encode()
        conn.sendall(b'Content-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
    data = b''; launch = None; configured = False
    while True:
        while b'\r\n\r\n' not in data:
            chunk = conn.recv(4096)
            if not chunk: sys.exit(0)
            data += chunk
        header, data = data.split(b'\r\n\r\n', 1)
        length = int(header.split(b':')[1].strip())
        while len(data) < length: data += conn.recv(4096)
        body, data = data[:length], data[length:]
        req = json.loads(body); command = req['command']
        def respond(body={}):
            send({'seq': 100, 'type': 'response', 'request_seq': req['seq'], 'command': command, 'success': True, 'body': body})
        if command in ('launch', 'attach'):
            launch = (req['seq'], command)
            send({'seq': 101, 'type': 'event', 'event': 'initialized', 'body': {}})
            continue
        if command == 'configurationDone':
            configured = True
            respond()
            send({'seq': 102, 'type': 'response', 'request_seq': launch[0], 'command': launch[1], 'success': True, 'body': {}})
            send({'seq': 103, 'type': 'event', 'event': 'stopped', 'body': {'reason': 'breakpoint', 'threadId': 1}})
            continue
        if command == 'threads': respond({'threads': [{'id': 1, 'name': 'main'}, {'id': 3, 'name': 'worker'}]})
        elif command == 'stackTrace': respond({'stackFrames': [{'id': 2, 'name': 'main.main', 'source': {'path': 'main.go'}, 'line': 2}, {'id': 4, 'name': 'main.worker', 'source': {'path': 'main.go'}, 'line': 3}] if req['arguments']['threadId'] == 1 else [{'id': 5, 'name': 'worker.run', 'source': {'path': 'main.go'}, 'line': 4}]})
        elif command == 'scopes': respond({'scopes': [{'name': 'Locals', 'variablesReference': 9 if req['arguments']['frameId'] == 2 else 11}]})
        elif command == 'variables':
            if req['arguments']['variablesReference'] == 10:
                import time; time.sleep(0.05)
            respond({'variables': [{'name': 'x', 'value': '42', 'variablesReference': 10}] if req['arguments']['variablesReference'] == 9 else [{'name': 'child', 'value': 'nested', 'variablesReference': 0}] if req['arguments']['variablesReference'] == 10 else [{'name': 'other', 'value': '99', 'variablesReference': 0}]})
        elif command == 'setBreakpoints': respond({'breakpoints': [{'verified': True, 'line': b['line'] + 1} for b in req['arguments']['breakpoints']]})
        else: respond()
        if command == 'next': send({'seq': 104, 'type': 'event', 'event': 'continued', 'body': {'threadId': 1}})
        if command == 'continue': send({'seq': 105, 'type': 'event', 'event': 'terminated', 'body': {}})
        if command == 'disconnect': break
    conn.close(); listener.close()
    """#.write(to: adapter, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adapter.path)
    let session = ClairDebugSession(project: WorkbenchProject(name: "test", path: root.path), adapterExecutable: adapter)
    session.toggleBreakpoint(path: program.path, line: 2)
    await session.start(.launch(program: program.path, mode: "debug"))
    for _ in 0..<200 {
      if session.phase == .stopped && !session.variables.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.phase == .stopped)
    #expect(session.frames.first?.name == "main.main")
    #expect(session.variables.first?.value == "42")
    #expect(session.breakpoints[program.path] == [2])
    #expect(session.breakpointStatus[program.path]?[2]?.verified == true)
    #expect(session.breakpointStatus[program.path]?[2]?.line == 3)
    session.toggleBreakpoint(path: program.path, line: 3)
    #expect(session.breakpoints[program.path]?.isEmpty == true)
    session.toggleBreakpoint(path: program.path, line: 2)
    let x = try #require(session.variables.first)
    session.expandVariable(x)
    session.expandVariable(x)
    for _ in 0..<200 {
      if session.variables.count > 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.variables.last?.value == "nested")
    #expect(session.variables.count == 2)
    session.selectFrame(4)
    for _ in 0..<200 {
      if session.variables.first?.value == "99" { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.selectedFrame == 4)
    #expect(session.variables.first?.value == "99")
    session.selectThread(3)
    for _ in 0..<200 {
      if session.frames.first?.id == 5 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.frames.first?.id == 5)
    await session.control("next")
    #expect(session.phase == .running)
    await session.stop()
    #expect(session.phase == .ended)
    await session.start(.launch(program: program.path, mode: "debug"))
    for _ in 0..<200 {
      if session.phase == .stopped { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.phase == .stopped)
    await session.control("continue")
    for _ in 0..<200 {
      if session.phase == .ended { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.phase == .ended)
    await session.start(.launch(program: program.path, mode: "debug"))
    for _ in 0..<200 {
      if session.phase == .stopped { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.phase == .stopped)
    await session.stop()
    #expect(session.phase == .ended)
    let attached = ClairDebugSession(project: WorkbenchProject(name: "test", path: root.path), adapterExecutable: adapter)
    await attached.start(.attach(pid: 1234))
    for _ in 0..<200 {
      if attached.phase == .stopped && !attached.variables.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(attached.phase == .stopped)
    #expect(attached.threads.first?.id == 1)
    await attached.stop()
    #expect(attached.phase == .ended)
  }
}
#endif

#if os(macOS)
@Suite("Live Delve DAP") struct LiveDelveTests {
  @MainActor @Test func launchGoBinaryAndStopAtBreakpoint() async throws {
    guard let go = ProcessInfo.processInfo.environment["CLAIR_TEST_GO"],
      let dlv = ProcessInfo.processInfo.environment["CLAIR_TEST_DLV"] else { return }
    let root = FileManager.default.temporaryDirectory.appending(path: "clair-live-dap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "main.go")
    try "import \"fmt\"\nfunc main() {\n    x := 41\n    x++\n    fmt.Println(x)\n}\n".replacingOccurrences(of: "import", with: "package main\nimport")
      .write(to: source, atomically: true, encoding: .utf8)
    let binary = root.appending(path: "debuggee")
    let build = Process()
    build.executableURL = URL(fileURLWithPath: go)
    build.arguments = ["build", "-gcflags=all=-N -l", "-o", binary.path, source.path]
    build.currentDirectoryURL = root
    build.standardOutput = FileHandle.nullDevice
    build.standardError = FileHandle.nullDevice
    try build.run(); build.waitUntilExit()
    #expect(build.terminationStatus == 0)
    guard build.terminationStatus == 0 else { return }
    let session = ClairDebugSession(project: WorkbenchProject(name: "live", path: root.path), adapterExecutable: URL(fileURLWithPath: dlv))
    session.toggleBreakpoint(path: source.path, line: 5)
    await session.start(.launch(program: binary.path, mode: "exec"))
    for _ in 0..<3000 {
      if session.phase == .stopped || session.phase == .ended { break }
      if case .failed = session.phase { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(session.phase == .stopped, "\(session.phase) \(session.console)")
    #expect(session.frames.first?.path == source.path)
    await session.stop()
  }
}
#endif

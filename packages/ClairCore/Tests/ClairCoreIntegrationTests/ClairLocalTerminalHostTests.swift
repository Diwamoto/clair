import Foundation
import Testing

@testable import ClairAgent
@testable import ClairAppKit
@testable import ClairDaemonKit
@testable import ClairPush
@testable import ClairShared
@testable import ClairTerminal
@testable import ClairTransport
@testable import ClairWorkspace

#if os(macOS)
  /// T09: the Mac GUI's terminals are daemon-owned shells reached through the control socket,
  /// and a paired mobile device attaches to the very same PTY through the shared boundary.
  @Suite(.serialized)
  struct ClairLocalTerminalHostTests {
    private static let echoLoop =
      "stty raw -echo; printf READY; while IFS= read -r line; do if [ \"$line\" = SIZE ]; then stty size; else printf '<%s>' \"$line\"; fi; done"

    @Test func terminalProcessIDIsAvailableOnlyWhileItsShellRuns() async throws {
      try await withDaemon { daemon in
        _ = try daemon.attach(key: "agent-pane")
        let response = try daemon.client.terminal(.processID(key: "agent-pane"))
        guard case .processID(let pid) = response else { Issue.record("missing process ID response"); return }
        #expect((pid ?? 0) > 0)
        #expect(try daemon.client.terminal(.processID(key: "other-pane")) == .processID(nil))
        #expect(try daemon.client.terminal(.close(key: "agent-pane")) == .accepted)
        #expect(try daemon.client.terminal(.processID(key: "agent-pane")) == .processID(nil))
      }
    }

    @Test func manuallyStartedCLIIsMatchedToItsTerminal() async throws {
      let directory = URL.temporaryDirectory.appending(path: "clair-cli-detect-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let executable = directory.appending(path: "codex")
      try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
      let daemon = try LocalDaemon(command: "\(executable.path) 10")
      do {
        _ = try daemon.attach(key: "agent-pane")
        guard case .processID(let shellPID) = try daemon.client.terminal(.processID(key: "agent-pane")),
          let shellPID
        else { Issue.record("missing shell PID"); await daemon.stop(); return }
        var found: String?
        for _ in 0..<50 {
          found = ClairCLIProcessScanner.profiles(shells: ["agent-pane": shellPID])["agent-pane"]
          if found != nil { break }
          try await Task.sleep(for: .milliseconds(50))
        }
        #expect(found == "codex")
      } catch {
        await daemon.stop()
        throw error
      }
      await daemon.stop()
    }

    @Test func t09ShellOutlivesDetachAndReattachReplaysFromTheSameSession() async throws {
      try await withDaemon { daemon in
        let first = try daemon.attach(key: "pane-1")
        #expect(try daemon.read(first, until: "READY"))
        try first.send(Data("one\n".utf8))
        #expect(try daemon.read(first, until: "<one>"))
        // Dropping the attachment is a detach; the shell must keep running in the daemon.
        let second = try daemon.attach(key: "pane-1")
        #expect(second.sessionID == first.sessionID)
        #expect(try daemon.read(second, until: "<one>"))
        try second.send(Data("two\n".utf8))
        #expect(try daemon.read(second, until: "<two>"))
      }
    }

    @Test func t09ReattachAtTheSameSizeStillMakesTheForegroundAppRepaint() async throws {
      // A polling loop, since a trap cannot run while `read` blocks.
      let daemon = try LocalDaemon(
        command: "trap 'printf WINCH' WINCH; printf READY; while :; do sleep 0.05; done")
      let first = try daemon.attach(key: "pane-1")
      #expect(try daemon.read(first, until: "READY"))
      // Same size as before: only an explicit SIGWINCH makes claude/vim redraw over the replay.
      let second = try daemon.attach(key: "pane-1")
      #expect(try daemon.read(second, until: "WINCH"))
      await daemon.stop()
    }

    @Test func t09MacAndPairedMobileShareOnePTYAndInputArrivesInOrder() async throws {
      try await withDaemon { daemon in
        let mac = try daemon.attach(key: "pane-1")
        #expect(try daemon.read(mac, until: "READY"))

        let peer = try await daemon.pair()
        let scope = try ResourceScope(
          projectID: ClairLocalTerminalHost.projectID,
          sessionID: SessionID(mac.sessionID))
        let attached = try await daemon.host.terminal.attach(
          scope: scope, generation: 1, subscriberID: UUID(), on: peer.connection)

        try mac.send(Data("from-mac\n".utf8))
        let request = try ClairTerminalInputRequest(
          operationID: OperationID("mobile-1"), scope: scope, epoch: attached.stream.epoch,
          processGeneration: 1, bytes: Data("from-mobile\n".utf8))
        #expect(
          try await daemon.host.terminal.input(request, on: peer.connection).outcome == .queued)
        try mac.send(Data("last\n".utf8))

        // Both surfaces read the same journal: mobile sees Mac's input echoed, and vice versa.
        var mobile = Data()
        var cursor = attached.attachment.cursor
        for _ in 0..<300 where mobile.range(of: Data("<last>".utf8)) == nil {
          if let frame = try await daemon.host.terminal.read(
            attached.attachment, on: peer.connection)
          {
            mobile.append(frame.bytes)
            cursor = frame.nextCursor
            try await daemon.host.terminal.acknowledge(
              attached.attachment, cursor: cursor, on: peer.connection)
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        let text = String(decoding: mobile, as: UTF8.self)
        let order = ["<from-mac>", "<from-mobile>", "<last>"].compactMap { text.range(of: $0) }
        #expect(order.count == 3)
        #expect(order.map(\.lowerBound) == order.map(\.lowerBound).sorted())
        #expect(try daemon.read(mac, until: "<last>"))
      }
    }

    @Test func t09ResizeReachesThePTYAndCloseEndsOnlyThatShell() async throws {
      try await withDaemon { daemon in
        let a = try daemon.attach(key: "pane-a")
        let b = try daemon.attach(key: "pane-b")
        #expect(a.sessionID != b.sessionID)
        #expect(try daemon.read(a, until: "READY"))
        try a.resize(rows: 41, columns: 123)
        try a.send(Data("SIZE\n".utf8))
        #expect(try daemon.read(a, until: "41 123"))

        #expect(try daemon.client.terminal(.close(key: "pane-a")) == .accepted)
        #expect(try daemon.client.terminal(.close(key: "pane-a")) == .rejected)
        try b.send(Data("still\n".utf8))
        #expect(try daemon.read(b, until: "<still>"))
      }
    }

    @Test func t09RejectsARelativeWorkingDirectoryAndUnknownSessions() async throws {
      try await withDaemon { daemon in
        let bad = try daemon.client.terminal(
          .open(key: "x", cwd: "relative", command: nil, rows: 24, columns: 80, environment: [:]))
        #expect(bad == .rejected)
        #expect(
          try daemon.client.terminal(.input(sessionID: "nope", bytes: Data("x".utf8))) == .rejected)
      }
    }

    @Test func t09LocalInputIsNotCappedByTheRemoteOperationWindow() async throws {
      try await withDaemon { daemon in
        let mac = try daemon.attach(key: "pane-1")
        #expect(try daemon.read(mac, until: "READY"))
        // Past the boundary's 4096-operation window: a long-lived shell must keep accepting keys.
        for _ in 0..<4_200 {
          #expect(
            daemon.host.localTerminals.handle(.input(sessionID: mac.sessionID, bytes: Data("x".utf8)))
              == .accepted)
        }
        try mac.send(Data("\n".utf8))
        #expect(try daemon.read(mac, until: "<" + String(repeating: "x", count: 4_200) + ">"))
      }
    }

    @Test func t09ClosedShellsFreeTheirBoundarySlot() throws {
      // A two-slot boundary stands in for the daemon's 64: only close releasing slots lets this pass.
      let authority = try ClairPairingAuthority(
        hostID: ClairHostID("t09-slots"),
        endpoint: ClairTransportEndpoint("wss://t09.example.test/mobile"),
        defaultVisibleScopes: [])
      let host = ClairLocalTerminalHost(
        boundary: try ClairTerminalBoundary(authority: authority, maximumSessions: 2))
      for i in 0..<5 {
        guard
          case .opened = host.handle(
            .open(
              key: "k\(i)", cwd: "/private/tmp", command: "sleep 30", rows: 24, columns: 80,
              environment: [:]))
        else {
          Issue.record("open \(i) was rejected")
          return
        }
        #expect(host.handle(.close(key: "k\(i)")) == .accepted)
      }
      host.closeAll()
    }

    @Test func t09AMismatchedLaunchGetsAFreshShell() async throws {
      try await withDaemon { daemon in
        let open = { (command: String) in
          try daemon.client.terminal(
            .open(
              key: "same", cwd: "/private/tmp", command: command, rows: 24, columns: 80,
              environment: [:]))
        }
        guard case .opened(let first, _, _) = try open("sleep 30"),
          case .opened(let again, _, _) = try open("sleep 30"),
          case .opened(let other, _, _) = try open("sleep 31")
        else {
          Issue.record("open rejected")
          return
        }
        #expect(first == again)
        #expect(first != other)
      }
    }

    @Test func t09ReopeningAKeyWhoseShellExitedStartsANewShell() async throws {
      try await withDaemon { daemon in
        guard case .opened(let first, _, _) = try daemon.client.terminal(
          .open(key: "gone", cwd: "/private/tmp", command: "exit 0", rows: 24, columns: 80, environment: [:]))
        else { Issue.record("open rejected"); return }
        var closed = false
        for _ in 0..<100 where !closed {
          if case .output(_, _, _, let isClosed) = try daemon.client.terminal(
            .read(sessionID: first, epoch: nil, offset: nil, waitMilliseconds: 100))
          { closed = isClosed }
        }
        #expect(closed)
        guard case .opened(let second, _, _) = try daemon.client.terminal(
          .open(key: "gone", cwd: "/private/tmp", command: "exit 0", rows: 24, columns: 80, environment: [:]))
        else { Issue.record("reopen rejected"); return }
        #expect(second != first)
      }
    }

    private func withDaemon(_ body: (LocalDaemon) async throws -> Void) async throws {
      let daemon = try LocalDaemon(command: Self.echoLoop)
      do { try await body(daemon) } catch {
        await daemon.stop()
        throw error
      }
      await daemon.stop()
    }
  }

  private final class LocalDaemon: @unchecked Sendable {
    let directory: URL
    let host: ClairDaemonHost
    let authority: ClairPairingAuthority
    let runtime: ClairDaemonRuntime
    let client: ClairDaemonControlClient
    let command: String

    init(command: String) throws {
      self.command = command
      // Unix socket paths are short; keep it directly under /private/tmp.
      directory = URL(fileURLWithPath: "/private/tmp/clair-t09-\(UUID().uuidString.prefix(8))")
      let workspace = try ClairWorkspaceRuntime(projects: [])
      authority = try ClairPairingAuthority(
        hostID: ClairHostID("t09-host"),
        endpoint: ClairTransportEndpoint("wss://t09.example.test/mobile"),
        defaultVisibleScopes: [ResourceScope(projectID: ClairLocalTerminalHost.projectID)])
      let provider = try ClairOpenCodeProvider(
        executableURL: URL(fileURLWithPath: "/bin/sh"), processFactory: ClairPTYAgentProcessFactory())
      host = try ClairDaemonHost(
        workspace: workspace, authority: authority,
        agentRuntime: try ClairAgentRuntime(workspace: workspace, provider: provider),
        pushRelay: T09NoRelay())
      let paths = ClairDaemonPaths(directoryURL: directory)
      runtime = ClairDaemonRuntime(
        configuration: try ClairDaemonConfiguration(paths: paths), host: host)
      try runtime.start()
      client = ClairDaemonControlClient(paths: paths)
    }

    func attach(key: String) throws -> ClairTerminalAttach {
      try ClairTerminalAttach(
        client: client, key: key, cwd: "/private/tmp", command: command,
        size: try ClairTerminalSize(), environment: ["TERM": "xterm-256color"])
    }

    /// Pumps until `needle` appears in what this attachment has delivered so far.
    func read(_ attach: ClairTerminalAttach, until needle: String) throws -> Bool {
      var seen = Data()
      for _ in 0..<200 {
        _ = try attach.pump(waitMilliseconds: 50) { seen.append($0) }
        if seen.range(of: Data(needle.utf8)) != nil { return true }
      }
      return false
    }

    func pair() async throws -> (
      client: ClairNativeClientTransport, connection: ClairAuthenticatedConnection
    ) {
      let client = ClairNativeClientTransport(deviceKey: ClairDeviceKey())
      let paired = try await client.pair(
        using: authority.issuePairingLink(lifetime: 60), with: authority,
        displayName: "T09 fixture", confirmHostFingerprint: true)
      _ = try await authority.updateGrant(
        deviceID: paired.credential.grant.deviceID,
        capabilities: CapabilitySet([.view, .writeTerminal]),
        visibleScopes: [try ResourceScope(projectID: ClairLocalTerminalHost.projectID)])
      return (client, try await client.reconnect(to: authority.presentation(), using: authority))
    }

    func stop() async {
      await host.shutdown()
      try? runtime.stop()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private struct T09NoRelay: ClairPushSending {
    func send(_ delivery: ClairPushDelivery) throws -> ClairPushDeliveryResult {
      ClairPushDeliveryResult(status: .unavailable)
    }
  }
#endif

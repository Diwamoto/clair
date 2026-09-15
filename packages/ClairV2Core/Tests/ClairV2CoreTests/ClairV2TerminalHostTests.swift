import Foundation
import Testing

@testable import ClairV2Agent
@testable import ClairV2DaemonKit
@testable import ClairV2Push
@testable import ClairV2Shared
@testable import ClairV2Terminal
@testable import ClairV2Transport
@testable import ClairV2Workspace

#if os(macOS)
  @Suite(.serialized)
  struct ClairV2TerminalHostTests {
    @Test func t02AuthenticatedHostControlsARealPTYWithoutFixtureEndpoint() async throws {
      try await withStack { stack in
        let peer = try await stack.pair()
        let host = stack.host
        let started = try await host.startSession(
          providerID: .openCode, target: stack.target, on: peer.connection)
        let scope = started.identity.sessionScope
        let subscriber = UUID()
        let attached = try await host.terminal.attach(
          scope: scope, generation: started.processGeneration, subscriberID: subscriber,
          on: peer.connection)
        let ready = try await stack.receive(
          attached.attachment, on: peer.connection, until: "READY")
        #expect(ready.found)
        let payload = try ClairV2TerminalInputRequest(
          operationID: OperationID("mobile-one"), scope: scope,
          epoch: attached.stream.epoch, processGeneration: started.processGeneration,
          bytes: Data("mobile\n".utf8))
        #expect(try await host.terminal.input(payload, on: peer.connection).outcome == .queued)
        #expect(
          try await host.terminal.input(payload, on: peer.connection).receipt.disposition
            == .duplicate)
        let reply = try await stack.receive(
          attached.attachment, on: peer.connection, until: "<mobile>")
        #expect(reply.found)
        try await host.terminal.detach(attached.attachment, on: peer.connection)
        #expect(
          try await host.agentRuntime.session(sessionID: started.identity.sessionID).processID
            == started.processID)
        await stack.authority.close(peer.connection)
        let reconnected = try await peer.client.reconnect(
          to: stack.authority.presentation(), using: stack.authority)
        let restored = try await host.terminal.attach(
          scope: scope, generation: started.processGeneration,
          subscriberID: subscriber, cursor: reply.cursor, on: reconnected)
        #expect(restored.attachment.scope.sessionID == started.identity.sessionID)
        let owner = try host.terminal.claimDesktopResizeOwner(
          scope: scope, generation: started.processGeneration)
        try host.terminal.resize(ClairV2TerminalSize(rows: 40, columns: 120), owner: owner)
        _ = try await host.terminal.input(
          ClairV2TerminalInputRequest(
            operationID: OperationID("geometry"), scope: scope,
            epoch: restored.stream.epoch, processGeneration: started.processGeneration,
            bytes: Data("SIZE\n".utf8)), on: reconnected)
        let geometry = try await stack.receive(
          restored.attachment, on: reconnected, until: "40 120")
        #expect(geometry.found)
        let semantic = try stack.command(
          started, id: "semantic", action: .prompt("not a raw key sequence"))
        #expect(try await host.execute(semantic, on: reconnected).outcome == .rejected)
        let stop = try stack.command(started, id: "stop", action: .stop)
        #expect(try await host.stopSession(stop, on: reconnected).outcome == .committed)
        #expect(
          try await host.agentRuntime.session(sessionID: started.identity.sessionID).lifecycle
            == .stopped)
        let final = try await host.terminal.snapshot(restored.attachment, on: reconnected)
        #expect(final.isClosed)
        let resumed = try await host.resumeSession(
          sessionID: started.identity.sessionID, on: reconnected)
        #expect(
          resumed.identity.sessionID == started.identity.sessionID
            && resumed.processGeneration > started.processGeneration)
        await #expect(throws: ClairV2TerminalError.staleEpoch) {
          try await host.terminal.attach(
            scope: scope, generation: resumed.processGeneration, subscriberID: subscriber,
            cursor: restored.attachment.cursor, on: reconnected)
        }
        #expect(throws: ClairV2TerminalError.resizeDenied) {
          try host.terminal.resize(ClairV2TerminalSize(), owner: owner)
        }
      }
    }

    @Test func t02HostDuplicateLaunchAndShutdownKeepOneProcessOwner() async throws {
      try await withStack { stack in
        let peer = try await stack.pair()
        let id = try SessionID("stable-session")
        let snapshot = try await stack.host.startSession(
          providerID: .openCode, target: stack.target, sessionID: id, on: peer.connection)
        await #expect(throws: ClairV2AgentError.duplicateLaunch(id)) {
          try await stack.host.startSession(
            providerID: .openCode, target: stack.target, sessionID: id, on: peer.connection)
        }
        #expect(
          try await stack.host.agentRuntime.session(sessionID: id).processID == snapshot.processID)
        await stack.host.shutdown()
        let stopped = try await stack.host.agentRuntime.session(sessionID: id)
        #expect(stopped.lifecycle == .stopped)
        #expect(stopped.processID == nil)
      }
    }

    @Test func t02HostInterruptReachesTheActualProviderProcess() async throws {
      try await withStack(arguments: [
        "-c", "trap 'printf INTERRUPTED' INT; printf READY; while :; do sleep 1; done",
      ]) { stack in
        let peer = try await stack.pair()
        let started = try await stack.host.startSession(
          providerID: .openCode, target: stack.target, on: peer.connection)
        let attachment = try await stack.host.terminal.attach(
          scope: started.identity.sessionScope,
          generation: started.processGeneration, subscriberID: UUID(), on: peer.connection
        ).attachment
        #expect(try await stack.receive(attachment, on: peer.connection, until: "READY").found)
        let interrupt = try stack.command(started, id: "interrupt", action: .interrupt)
        #expect(try await stack.host.execute(interrupt, on: peer.connection).outcome == .committed)
        #expect(
          try await stack.receive(attachment, on: peer.connection, until: "INTERRUPTED").found)
        #expect(
          try await stack.host.execute(interrupt, on: peer.connection).receipt.disposition
            == .duplicate)
      }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["T02_OPENCODE_EXECUTABLE"] != nil))
    func t02RealOpenCodeExecutableUsesThePTYFactory() async throws {
      let executable = try #require(ProcessInfo.processInfo.environment["T02_OPENCODE_EXECUTABLE"])
      // --version exercises the installed provider binary with an empty HOME,
      // without reading user provider credentials or making a model request.
      try await withStack(executable: executable, arguments: ["--version"]) { stack in
        let snapshot = try await stack.host.agentRuntime.start(
          providerID: .openCode, target: stack.target)
        let process = try? await stack.host.agentRuntime.terminalProcess(for: snapshot)
        var exited = false
        for _ in 0..<500 {
          let state = try await stack.host.agentRuntime.session(
            sessionID: snapshot.identity.sessionID)
          if state.lifecycle == .exited {
            exited = true
            break
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(exited)
        if let process {
          let state = process.terminalJournal.snapshot()
          #expect(state.endOffset > 0 && state.isClosed && !state.outputFailed)
        }
      }
    }

    private func withStack(
      executable: String = "/bin/sh",
      arguments: [String] = [
        "-c",
        "stty raw -echo; printf READY; while IFS= read -r line; do if [ \"$line\" = SIZE ]; then stty size; else printf '<%s>' \"$line\"; fi; done",
      ],
      body: (T02HostStack) async throws -> Void
    ) async throws {
      let stack = try T02HostStack(executable: executable, arguments: arguments)
      do { try await body(stack) } catch {
        await stack.host.shutdown()
        stack.remove()
        throw error
      }
      await stack.host.shutdown()
      stack.remove()
    }
  }

  private struct T02HostStack {
    let root: URL
    let host: ClairDaemonHost
    let authority: ClairPairingAuthority
    let target: ClairV2AgentTarget
    init(executable: String, arguments: [String]) throws {
      root = URL(fileURLWithPath: "/private/tmp/clair-v2-t02-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let project = try ProjectID("t02-project")
      target = ClairV2AgentTarget(projectID: project)
      let workspace = try ClairV2WorkspaceRuntime(projects: [
        ClairV2ProjectRoot(id: project, rootURL: root)
      ])
      authority = try ClairPairingAuthority(
        hostID: ClairHostID("t02-host"),
        endpoint: ClairTransportEndpoint("wss://t02.example.test/mobile"),
        defaultVisibleScopes: [ResourceScope(projectID: project)])
      let provider = try ClairV2OpenCodeProvider(
        executableURL: URL(fileURLWithPath: executable), arguments: arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"],
        processFactory: ClairV2PTYAgentProcessFactory())
      let runtime = try ClairV2AgentRuntime(
        workspace: workspace, provider: provider,
        limits: ClairV2AgentLaunchLimits(terminationGracePeriod: 0.05))
      host = try ClairDaemonHost(
        workspace: workspace, authority: authority, agentRuntime: runtime, pushRelay: T02NoRelay())
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func pair() async throws -> (
      client: ClairNativeClientTransport, connection: ClairAuthenticatedConnection
    ) {
      let client = ClairNativeClientTransport(deviceKey: ClairDeviceKey())
      let paired = try await client.pair(
        using: authority.issuePairingLink(lifetime: 60), with: authority,
        displayName: "T02 fixture", confirmHostFingerprint: true)
      _ = try await authority.updateGrant(
        deviceID: paired.credential.grant.deviceID,
        capabilities: CapabilitySet([
          .view, .spawnSession, .writeTerminal, .steerAgent, .signal, .terminate,
        ]),
        visibleScopes: [target.resourceScope])
      return (client, try await client.reconnect(to: authority.presentation(), using: authority))
    }
    func receive(
      _ attachment: ClairV2TerminalAttachment, on connection: ClairAuthenticatedConnection,
      until needle: String
    ) async throws -> (found: Bool, cursor: ClairV2TerminalCursor) {
      var bytes = Data()
      var cursor = attachment.cursor
      for _ in 0..<300 {
        if let frame = try await host.terminal.read(attachment, on: connection) {
          bytes.append(frame.bytes)
          cursor = frame.nextCursor
          try await host.terminal.acknowledge(attachment, cursor: cursor, on: connection)
          if bytes.range(of: Data(needle.utf8)) != nil { return (true, cursor) }
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      return (false, cursor)
    }
    func command(
      _ snapshot: ClairV2AgentSessionSnapshot, id: String, action: ClairV2AgentCommandAction
    ) throws -> ClairV2AgentCommand {
      try ClairV2AgentCommand(
        operationID: OperationID(id), scope: snapshot.identity.sessionScope,
        kind: action.kind.operationKind, capability: action.kind.capability,
        payload: ClairV2AgentCommandPayload(
          epoch: SessionEpoch(snapshot.processGeneration),
          processGeneration: snapshot.processGeneration, action: action))
    }
  }
  private struct T02NoRelay: ClairPushSending {
    func send(_ delivery: ClairPushDelivery) throws -> ClairPushDeliveryResult {
      ClairPushDeliveryResult(status: .unavailable)
    }
  }
#endif

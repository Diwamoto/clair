import Foundation
import Testing

@testable import ClairAgent
@testable import ClairDaemonKit
@testable import ClairPush
@testable import ClairShared
@testable import ClairTerminal
@testable import ClairTransport
@testable import ClairWorkspace

#if os(macOS)
  /// N11 (ADR-0016 Validation): the loopback TLS listener carries pairing, challenge
  /// authentication and the terminal boundary; everything else is refused or closed.
  @Suite(.serialized)
  struct ClairRemoteListenerTests {

    @Test func n11PairAuthenticateAndShareTheMacShellOverTLS() async throws {
      try await withHost { h in
        let mac = try h.attachMac(key: "pane-1")
        #expect(try h.read(mac, until: "READY"))
        let device = ClairDeviceKey()
        let client = try await h.connect()
        let credential = try await h.pair(client, device)
        let info = try await h.authenticate(client, device, credential)
        #expect(info.deviceID == credential.grant.deviceID)

        let scope = try ResourceScope(projectID: ClairLocalTerminalHost.projectID, sessionID: SessionID(mac.sessionID))
        guard case .terminalAttached(let attachment, var cursor, _, _, _, false) = try await client.call(
          .terminalAttach(scope: scope, generation: 1, subscriberID: UUID(), cursor: nil)).0
        else { Issue.record("attach failed"); return }

        try mac.send(Data("from-mac\n".utf8))
        guard case .terminalInput(.queued, _) = try await client.call(
          .terminalInput(operationID: OperationID("remote-1"), scope: scope, epoch: cursor.epoch, processGeneration: 1),
          binary: Data("from-mobile\n".utf8)).0
        else { Issue.record("input not queued"); return }

        var seen = Data()
        for _ in 0..<50 where seen.range(of: Data("<from-mobile>".utf8)) == nil {
          let (reply, frame) = try await client.call(.terminalRead(attachment: attachment, waitMilliseconds: 500))
          guard reply == .terminalFrame, let frame else { continue }
          let decoded = try ClairTerminalFrame.decode(frame)
          #expect(decoded.cursor == cursor)
          seen.append(decoded.bytes)
          cursor = decoded.nextCursor
          _ = try await client.call(.terminalAcknowledge(attachment: attachment, cursor: cursor))
        }
        let text = String(decoding: seen, as: UTF8.self)
        let order = ["<from-mac>", "<from-mobile>"].compactMap { text.range(of: $0)?.lowerBound }
        #expect(order.count == 2 && order == order.sorted())
        #expect(try h.read(mac, until: "<from-mobile>"))  // same PTY on the Mac side
        #expect(try await client.call(.terminalDetach(attachment: attachment)).0 == .ok)
        await client.close()
      }
    }

    /// Review finding: pipelined input must reach the PTY in wire order, and long-polls filling
    /// every in-flight slot must not turn input away as busy.
    @Test func n11PipelinedInputKeepsWireOrderEvenWithEveryReadSlotBusy() async throws {
      try await withHost { h in
        let mac = try h.attachMac(key: "pane-1")
        #expect(try h.read(mac, until: "READY"))
        let device = ClairDeviceKey()
        let client = try await h.connect()
        let credential = try await h.pair(client, device)
        _ = try await h.authenticate(client, device, credential)
        let scope = try ResourceScope(projectID: ClairLocalTerminalHost.projectID, sessionID: SessionID(mac.sessionID))
        guard case .terminalAttached(let attachment, let start, _, _, let end, _) = try await client.call(
          .terminalAttach(scope: scope, generation: 1, subscriberID: UUID(), cursor: nil)).0
        else { Issue.record("attach failed"); return }
        let idle = try await client.call(
          .terminalAttach(scope: scope, generation: 1, subscriberID: UUID(), cursor: ClairTerminalCursor(epoch: start.epoch, offset: end))).0
        guard case .terminalAttached(let parked, _, _, _, _, _) = idle else { Issue.record("attach failed"); return }

        // Park every in-flight slot on a long-poll that has nothing to read yet.
        let polls = (0..<h.listener.limits.maximumInFlightPerConnection).map { _ in
          Task { try await client.call(.terminalRead(attachment: parked, waitMilliseconds: 1_500)) }
        }
        try await Task.sleep(for: .milliseconds(100))
        let lines = (1...20).map { "k\($0)" }
        let inputs = lines.enumerated().map { index, line in
          (ClairRemoteCall.terminalInput(
            operationID: try! OperationID("pipe-\(index)"), scope: scope, epoch: start.epoch, processGeneration: 1),
           Data("\(line)\n".utf8))
        }
        // One write, so the host sees them back to back exactly as a fast typist's keystrokes.
        let results = try await client.pipeline(inputs)
        #expect(results.allSatisfy { if case .terminalInput(.queued, _) = $0 { true } else { false } })
        for poll in polls { _ = try? await poll.value }

        var seen = Data()
        var cursor = start
        for _ in 0..<50 where seen.range(of: Data("<k20>".utf8)) == nil {
          let (reply, frame) = try await client.call(.terminalRead(attachment: attachment, waitMilliseconds: 500))
          guard reply == .terminalFrame, let frame else { continue }
          let decoded = try ClairTerminalFrame.decode(frame)
          seen.append(decoded.bytes)
          cursor = decoded.nextCursor
          _ = try await client.call(.terminalAcknowledge(attachment: attachment, cursor: cursor))
        }
        let text = String(decoding: seen, as: UTF8.self)
        let positions = lines.compactMap { text.range(of: "<\($0)>")?.lowerBound }
        #expect(positions.count == lines.count)
        #expect(positions == positions.sorted())
      }
    }

    @Test func n11ARevokeThatCannotBeSavedFailsInsteadOfReportingSuccess() async throws {
      try await withHost(failSaves: true) { h in
        let device = ClairDeviceKey()
        let client = try await h.connect()
        let credential = try await h.pair(client, device)
        await #expect(throws: (any Error).self) { try await h.listener.revoke(deviceID: credential.grant.deviceID) }
      }
    }

    @Test func n11AWrongPinNeverCompletesTheHandshake() async throws {
      try await withHost { h in
        let other = ClairHostSigningKey().publicKey.fingerprint
        await #expect(throws: ClairRemoteError.pinMismatch) {
          _ = try await ClairTLSChannel.connect(host: "127.0.0.1", port: h.port, pinnedTo: other)
        }
      }
    }

    @Test func n11UnauthenticatedCallsFailAndRepeatedFailuresCloseTheChannel() async throws {
      try await withHost { h in
        let client = try await h.connect()
        guard case .presentation(let presentation) = try await client.call(.presentation).0 else {
          Issue.record("no presentation"); return
        }
        #expect(presentation.fingerprint == h.hostKey.publicKey.fingerprint)
        for _ in 0..<3 {
          await #expect(throws: ClairRemoteError.remote(code: "notPaired")) {
            _ = try await client.call(.terminalDetach(attachment: UUID()))
          }
        }
        await #expect(throws: ClairRemoteError.self) { _ = try await client.call(.presentation) }
      }
    }

    @Test func n11AnIdleUnauthenticatedChannelIsClosedAtTheDeadline() async throws {
      var limits = ClairRemoteListenerLimits()
      limits.authenticationDeadline = .milliseconds(300)
      try await withHost(limits: limits) { h in
        let client = try await h.connect()
        _ = try await client.call(.presentation)
        try await Task.sleep(for: .milliseconds(800))
        #expect(h.listener.openConnectionCount == 0)
        await #expect(throws: ClairRemoteError.self) { _ = try await client.call(.presentation) }
      }
    }

    @Test func n11AnOversizeFrameClosesTheChannel() async throws {
      try await withHost { h in
        let channel = try await ClairTLSChannel.connect(host: "127.0.0.1", port: h.port, pinnedTo: h.pin)
        try await channel.send(Data([0x7F, 0xFF, 0xFF, 0xFF, 0x00]))  // declares ~2 GiB
        await #expect(throws: ClairRemoteError.self) { _ = try await channel.receive() }
      }
    }

    @Test func n11RevokeClosesTheLiveChannelAndPersistsTheRevokedGrant() async throws {
      try await withHost { h in
        let device = ClairDeviceKey()
        let client = try await h.connect()
        let credential = try await h.pair(client, device)
        _ = try await h.authenticate(client, device, credential)
        #expect(h.saved.last?.first?.grant.isRevoked == false)  // pair persisted the grant

        #expect(h.listener.openConnectionCount == 1)
        try await h.listener.revoke(deviceID: credential.grant.deviceID)
        #expect(h.saved.last?.first?.grant.isRevoked == true)
        // Closed by the revoke itself, not by the next failing call.
        for _ in 0..<50 where h.listener.openConnectionCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(h.listener.openConnectionCount == 0)
        await #expect(throws: ClairRemoteError.closed) {
          _ = try await client.call(.authorizeRead(try ResourceScope(projectID: ClairLocalTerminalHost.projectID)))
        }
        // The revoked device cannot come back on a new channel either.
        let again = try await h.connect()
        await #expect(throws: ClairRemoteError.self) { _ = try await h.authenticate(again, device, credential) }
      }
    }

    @Test func n11PairedDevicesReconnectAfterADaemonRestart() async throws {
      let hostKey = ClairHostSigningKey()
      let device = ClairDeviceKey()
      var credential: ClairDeviceCredential?
      var grants: [ClairPersistedDeviceGrant] = []
      try await withHost(hostKey: hostKey) { h in
        let client = try await h.connect()
        credential = try await h.pair(client, device)
        grants = try #require(h.saved.last)
      }
      try await withHost(hostKey: hostKey, grants: grants) { h in
        let client = try await h.connect()  // same pin: the host key survived the restart
        let info = try await h.authenticate(client, device, try #require(credential))
        #expect(info.deviceID == credential?.grant.deviceID)
      }
    }

    @Test func n11ADeviceWithoutTerminalScopeCannotAttach() async throws {
      try await withHost { h in
        let mac = try h.attachMac(key: "pane-1")
        let device = ClairDeviceKey()
        let client = try await h.connect()
        let credential = try await h.pair(client, device, grantTerminal: false)
        _ = try await h.authenticate(client, device, credential)
        let scope = try ResourceScope(projectID: ClairLocalTerminalHost.projectID, sessionID: SessionID(mac.sessionID))
        await #expect(throws: ClairRemoteError.self) {
          _ = try await client.call(.terminalAttach(scope: scope, generation: 1, subscriberID: UUID(), cursor: nil))
        }
      }
    }

    private func withHost(
      hostKey: ClairHostSigningKey = ClairHostSigningKey(), grants: [ClairPersistedDeviceGrant] = [],
      limits: ClairRemoteListenerLimits = .init(), failSaves: Bool = false, _ body: (RemoteHost) async throws -> Void
    ) async throws {
      guard #available(macOS 15, *) else { return }
      let h = try await RemoteHost(hostKey: hostKey, grants: grants, limits: limits, failSaves: failSaves)
      do { try await body(h) } catch {
        await h.stop()
        throw error
      }
      await h.stop()
    }
  }

  private final class RemoteHost: @unchecked Sendable {
    let hostKey: ClairHostSigningKey
    let directory: URL
    let host: ClairDaemonHost
    let authority: ClairPairingAuthority
    let runtime: ClairDaemonRuntime
    let control: ClairDaemonControlClient
    let listener: ClairRemoteListener
    let port: UInt16
    private let lock = NSLock()
    private var persisted: [[ClairPersistedDeviceGrant]] = []
    var saved: [[ClairPersistedDeviceGrant]] { lock.withLock { persisted } }
    var pin: ClairHostFingerprint { hostKey.publicKey.fingerprint }

    @available(macOS 15, *)
    init(
      hostKey: ClairHostSigningKey, grants: [ClairPersistedDeviceGrant], limits: ClairRemoteListenerLimits,
      failSaves: Bool
    ) async throws {
      self.hostKey = hostKey
      directory = URL(fileURLWithPath: "/private/tmp/clair-n11-\(UUID().uuidString.prefix(8))")
      let workspace = try ClairWorkspaceRuntime(projects: [])
      authority = try ClairPairingAuthority(
        hostID: ClairHostID("n11-host"), endpoint: ClairTransportEndpoint("tls://127.0.0.1:1"),
        hostKey: hostKey, persistedGrants: grants)
      let provider = try ClairOpenCodeProvider(
        executableURL: URL(fileURLWithPath: "/bin/sh"), processFactory: ClairPTYAgentProcessFactory())
      host = try ClairDaemonHost(
        workspace: workspace, authority: authority,
        agentRuntime: try ClairAgentRuntime(workspace: workspace, provider: provider), pushRelay: N11NoRelay())
      let paths = ClairDaemonPaths(directoryURL: directory)
      runtime = ClairDaemonRuntime(configuration: try ClairDaemonConfiguration(paths: paths), host: host)
      try runtime.start()
      control = ClairDaemonControlClient(paths: paths)
      let box = Box()
      listener = ClairRemoteListener(
        host: host, identity: try ClairRemoteTLSIdentity.make(hostKey: hostKey), port: 0, limits: limits,
        onGrantsChanged: { grants in
          if failSaves { throw CocoaError(.fileWriteNoPermission) }
          box.append(grants)
        })
      port = try await listener.start()
      box.owner = self
    }

    final class Box: @unchecked Sendable {
      weak var owner: RemoteHost?
      func append(_ grants: [ClairPersistedDeviceGrant]) { owner?.record(grants) }
    }
    private func record(_ grants: [ClairPersistedDeviceGrant]) { lock.withLock { persisted.append(grants) } }

    func connect() async throws -> ClairRemoteClient {
      ClairRemoteClient(channel: try await ClairTLSChannel.connect(host: "127.0.0.1", port: port, pinnedTo: pin))
    }

    /// Pairs over the wire; the host-side grant update stands in for the Mac UI's scope choice.
    func pair(_ client: ClairRemoteClient, _ device: ClairDeviceKey, grantTerminal: Bool = true) async throws
      -> ClairDeviceCredential
    {
      let link = try await authority.issuePairingLink(lifetime: 60)
      let request = ClairPairingRequest(
        link: link, devicePublicKey: device.publicKey, displayName: "N11 fixture", clientOffer: .current,
        confirmedHostFingerprint: true)
      guard case .paired(let result) = try await client.call(.pair(request)).0 else { throw ClairRemoteError.protocolViolation }
      guard grantTerminal else { return result.credential }
      let grant = try await authority.updateGrant(
        deviceID: result.credential.grant.deviceID, capabilities: CapabilitySet([.view, .writeTerminal]),
        visibleScopes: [try ResourceScope(projectID: ClairLocalTerminalHost.projectID)])
      return ClairDeviceCredential(grant: grant, token: result.credential.token)
    }

    func authenticate(_ client: ClairRemoteClient, _ device: ClairDeviceKey, _ credential: ClairDeviceCredential)
      async throws -> ClairConnectionInfo
    {
      let request = ClairReconnectRequest(
        hostID: try ClairHostID("n11-host"), hostFingerprint: pin, deviceID: credential.grant.deviceID,
        token: credential.token, clientOffer: .current, resourceScope: nil)
      guard case .challenge(let challenge) = try await client.call(.beginAuthentication(request)).0,
        case .authenticated(let info) = try await client.call(.authenticate(try challenge.makeProof(using: device))).0
      else { throw ClairRemoteError.protocolViolation }
      return info
    }

    func attachMac(key: String) throws -> ClairTerminalAttach {
      try ClairTerminalAttach(
        client: control, key: key, cwd: "/private/tmp", command: ClairRemoteListenerTestsShell.echoLoop,
        size: try ClairTerminalSize(), environment: ["TERM": "xterm-256color"])
    }

    func read(_ attach: ClairTerminalAttach, until needle: String) throws -> Bool {
      var seen = Data()
      for _ in 0..<200 {
        _ = try attach.pump(waitMilliseconds: 50) { seen.append($0) }
        if seen.range(of: Data(needle.utf8)) != nil { return true }
      }
      return false
    }

    func stop() async {
      await listener.stop()
      await host.shutdown()
      try? runtime.stop()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  extension ClairRemoteClient {
    /// Test-only: several calls in one channel write, then their replies in order.
    fileprivate func pipeline(_ calls: [(ClairRemoteCall, Data?)]) async throws -> [ClairRemoteReply] {
      try await withThrowingTaskGroup(of: (Int, ClairRemoteReply).self) { group in
        let ids = try await enqueue(calls)
        for (index, id) in ids.enumerated() { group.addTask { (index, try await self.reply(to: id).0) } }
        var replies = [ClairRemoteReply?](repeating: nil, count: calls.count)
        for try await (index, reply) in group { replies[index] = reply }
        return replies.map { $0! }
      }
    }
  }

  private enum ClairRemoteListenerTestsShell {
    static let echoLoop =
      "stty raw -echo; printf READY; while IFS= read -r line; do printf '<%s>' \"$line\"; done"
  }

  private struct N11NoRelay: ClairPushSending {
    func send(_ delivery: ClairPushDelivery) throws -> ClairPushDeliveryResult {
      ClairPushDeliveryResult(status: .unavailable)
    }
  }
#endif

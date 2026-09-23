#if os(macOS)

  import ClairPush
  import ClairShared
  import ClairTerminal
  import ClairTransport
  import CryptoKit
  import Foundation
  import Network
  import Security

  // N11 (ADR-0016): the host end of the remote client wire. A loopback TLS 1.3
  // listener whose certificate carries the persisted host key, so a client's pin
  // is the host fingerprint it confirmed at pairing. Every authenticated call runs
  // through the existing boundaries with the connection this channel authenticated;
  // nothing from the wire is trusted as a connection.

  public struct ClairRemoteListenerLimits: Sendable {
    public var authenticationDeadline: Duration = .seconds(10)
    public var maximumUnauthenticated = 16
    public var maximumConnections = 64
    public var maximumAuthenticationFailures = 3
    public var maximumAttachmentsPerConnection = 16
    public var maximumInFlightPerConnection = 8

    public init() {}
  }

  public enum ClairRemoteTLSIdentity {
    public enum Failure: Error, Equatable { case certificate(String), importFailed(Int32) }

    /// Self-signed certificate for the host key, imported in memory only: nothing is
    /// added to a keychain and no key material is written to disk.
    /// ponytail: shells out to `/usr/bin/openssl` for the X.509 + PKCS#12 encoding
    /// (~160 ms, once per daemon start); replace with a DER encoder if that ever matters.
    @available(macOS 15, *)
    public static func make(hostKey: ClairHostSigningKey) throws -> SecIdentity {
      let key = try P256.Signing.PrivateKey(rawRepresentation: hostKey.rawRepresentation)
      let pem = Data((key.pemRepresentation + "\n").utf8)
      let certificate = try openssl(
        ["req", "-new", "-x509", "-key", "/dev/stdin", "-subj", "/CN=Clair host", "-days", "825", "-sha256"],
        input: pem)
      let passphrase = UUID().uuidString
      let pkcs12 = try openssl(["pkcs12", "-export", "-passout", "pass:\(passphrase)"], input: pem + certificate)
      var items: CFArray?
      let status = SecPKCS12Import(
        pkcs12 as CFData,
        [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true] as CFDictionary, &items)
      guard status == errSecSuccess,
        let identity = (items as? [[String: Any]])?.first?[kSecImportItemIdentity as String]
      else { throw Failure.importFailed(status) }
      return identity as! SecIdentity
    }

    private static func openssl(_ arguments: [String], input: Data) throws -> Data {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
      process.arguments = arguments
      let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
      process.standardInput = stdin
      process.standardOutput = stdout
      process.standardError = stderr
      do { try process.run() } catch { throw Failure.certificate("openssl: \(error)") }
      stdin.fileHandleForWriting.write(input)
      try? stdin.fileHandleForWriting.close()
      let output = stdout.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw Failure.certificate(String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
      }
      return output
    }
  }

  public final class ClairRemoteListener: @unchecked Sendable {
    public let host: ClairDaemonHost
    public let limits: ClairRemoteListenerLimits
    private let identity: SecIdentity
    private let requestedPort: UInt16
    private let onGrantsChanged: @Sendable ([ClairPersistedDeviceGrant]) throws -> Void
    private var persistTail: Task<Void, Error>?
    private let queue = DispatchQueue(label: "clair.remote-listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var sessions: [UUID: ClairRemoteSession] = [:]
    private var authenticated: Set<UUID> = []

    /// `port` 0 picks a free port (tests). `onGrantsChanged` saves grants after a pair or revoke.
    public init(
      host: ClairDaemonHost, identity: SecIdentity, port: UInt16, limits: ClairRemoteListenerLimits = .init(),
      onGrantsChanged: @escaping @Sendable ([ClairPersistedDeviceGrant]) throws -> Void = { _ in }
    ) {
      self.host = host
      self.identity = identity
      self.requestedPort = port
      self.limits = limits
      self.onGrantsChanged = onGrantsChanged
    }

    /// Binds 127.0.0.1 only and returns the bound port. Remote devices reach it through
    /// a private route that passes TCP through (ADR-0016 §5), never a TLS-terminating proxy.
    public func start() async throws -> UInt16 {
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
      sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
      let parameters = NWParameters(tls: tls)
      parameters.requiredLocalEndpoint = .hostPort(
        host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in self?.admit(connection) }
      let once = ClairRemoteOnce()
      return try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { state in
          switch state {
          case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
          case .failed(let error), .waiting(let error):
            listener.cancel()
            once.run { continuation.resume(throwing: error) }
          default: break
          }
        }
        lock.withLock { self.listener = listener }
        listener.start(queue: queue)
      }
    }

    public func stop() async {
      let (listener, open) = lock.withLock { (self.listener, Array(sessions.values)) }
      listener?.cancel()
      for session in open { await session.close() }
    }

    /// Revokes the device and closes its live channels before returning (ADR-0016 §6).
    @discardableResult
    public func revoke(deviceID: ClairDeviceID) async throws -> ClairRevocation {
      let revocation = try await host.authority.revoke(deviceID: deviceID)
      let closing = Set(revocation.closedConnectionIDs)
      for session in lock.withLock({ Array(sessions.values) }) {
        if let id = await session.connectionID, closing.contains(id) { await session.close() }
      }
      // A revoke that is not on disk would come back after a restart: fail loudly instead.
      try await persistGrants()
      return revocation
    }

    public var openConnectionCount: Int { lock.withLock { sessions.count } }

    private func admit(_ connection: NWConnection) {
      let id = UUID()
      let admitted = lock.withLock { () -> Bool in
        guard sessions.count < limits.maximumConnections,
          sessions.count - authenticated.count < limits.maximumUnauthenticated
        else { return false }
        sessions[id] = ClairRemoteSession(listener: self)
        return true
      }
      guard admitted else { return connection.cancel() }
      let deadline = limits.authenticationDeadline
      let handshake = Task {
        try await ClairTLSChannel.accept(connection, queue: queue)
      }
      Task {
        // Unauthenticated connections (handshake included) get a fixed time budget.
        let timer = Task {
          try await Task.sleep(for: deadline)
          if !self.isAuthenticated(id) {
            connection.cancel()
            await self.session(id)?.close()
          }
        }
        defer { timer.cancel() }
        guard let channel = try? await handshake.value, let session = self.session(id) else {
          connection.cancel()
          self.remove(id)
          return
        }
        await session.run(channel: channel, id: id)
        self.remove(id)
      }
    }

    private func session(_ id: UUID) -> ClairRemoteSession? { lock.withLock { sessions[id] } }
    private func isAuthenticated(_ id: UUID) -> Bool { lock.withLock { authenticated.contains(id) } }
    private func remove(_ id: UUID) {
      lock.withLock {
        sessions.removeValue(forKey: id)
        authenticated.remove(id)
      }
    }
    fileprivate func markAuthenticated(_ id: UUID) { _ = lock.withLock { authenticated.insert(id) } }
    /// Snapshot + save run one at a time, each after the previous save, so an older snapshot
    /// (say, taken before a revoke) can never overwrite a newer one on disk.
    fileprivate func persistGrants() async throws {
      let task = lock.withLock { () -> Task<Void, Error> in
        let previous = persistTail
        let task = Task { [host, onGrantsChanged] in
          _ = await previous?.result
          try onGrantsChanged(await host.authority.persistedGrants())
        }
        persistTail = task
        return task
      }
      try await task.value
    }
  }

  /// One remote channel. Requests are read in order (so an input's raw frame always
  /// follows its header) and then handled concurrently, so a long-poll read never
  /// holds up input on the same channel.
  actor ClairRemoteSession {
    private unowned let listener: ClairRemoteListener
    private var host: ClairDaemonHost { listener.host }
    private var channel: ClairTLSChannel?
    private var connection: ClairAuthenticatedConnection?
    private var attachments: [UUID: (attachment: ClairTerminalAttachment, subscriberID: UUID)] = [:]
    private var failures = 0
    private var inFlight = 0
    private var closed = false

    init(listener: ClairRemoteListener) {
      self.listener = listener
    }

    var connectionID: ClairConnectionID? { connection?.connectionID }

    func run(channel: ClairTLSChannel, id: UUID) async {
      guard !closed else { return await channel.close() }
      self.channel = channel
      do {
        while !closed {
          let request = try ProtocolCodec.decodeFrame(
            ClairRemoteRequest.self, from: try await channel.receive(), limits: ClairRemoteWire.limits)
          if case .terminalInput = request.call {
            // Input commits here, in wire order (spec §7: Mac and mobile input reach the PTY in
            // arrival order), and never competes with long-polls for an in-flight slot.
            let binary = try BoundedFrame.decode(try await channel.receive(), limits: ClairRemoteWire.limits).payload
            let (reply, data, closing) = await handle(request.call, binary: binary, sessionID: id)
            await send(ClairRemoteResponse(id: request.id, reply: reply), data)
            if closing { await close() }
            continue
          }
          guard inFlight < listener.limits.maximumInFlightPerConnection else {
            await send(ClairRemoteResponse(id: request.id, reply: .failure(code: "busy")), nil)
            continue
          }
          inFlight += 1
          Task {
            let (reply, data, closing) = await self.handle(request.call, binary: nil, sessionID: id)
            await self.send(ClairRemoteResponse(id: request.id, reply: reply), data)
            if closing { await self.close() }  // the client still learns why
            await self.finished()
          }
        }
      } catch {
        // Oversize, truncated or malformed frames and unknown calls end the channel.
      }
      await close()
    }

    func close() async {
      guard !closed else { return }
      closed = true
      if let connection {
        for entry in attachments.values { try? await host.terminal.detach(entry.attachment, on: connection) }
        await host.authority.close(connection)
      }
      attachments = [:]
      await channel?.close()
    }

    private func finished() { inFlight -= 1 }

    private func send(_ response: ClairRemoteResponse, _ binary: Data?) async {
      guard !closed, let channel,
        var frame = try? ProtocolCodec.encodeFrame(response, limits: ClairRemoteWire.limits)
      else { return }
      if let binary { frame.append(binary) }
      do { try await channel.send(frame) } catch { await close() }
    }

    private func handle(_ call: ClairRemoteCall, binary: Data?, sessionID: UUID) async
      -> (ClairRemoteReply, Data?, closing: Bool)
    {
      do {
        let (reply, data) = try await perform(call, binary: binary, sessionID: sessionID)
        return (reply, data, false)
      } catch {
        return (.failure(code: Self.code(error)), nil, await rejected(authenticated: call.requiresAuthentication))
      }
    }

    /// Before authentication, a few failures end the channel. After it, a call that failed
    /// because the grant was revoked, rotated or expired ends the channel too.
    private func rejected(authenticated: Bool) async -> Bool {
      if let connection, authenticated { return await !host.authority.isConnectionActive(connection) }
      failures += 1
      return failures >= listener.limits.maximumAuthenticationFailures
    }

    private func perform(_ call: ClairRemoteCall, binary: Data?, sessionID: UUID) async throws -> (ClairRemoteReply, Data?) {
      if call.requiresAuthentication, connection == nil { throw ClairTransportError.notPaired }
      switch call {
      case .presentation:
        return (.presentation(await host.authority.presentation()), nil)
      case .pair(let request):
        let result = try await host.authority.pair(request)
        // ponytail: a failed save keeps the pairing in memory only (it is lost on restart, which
        // is safe); the error surfaces on the daemon's stderr through the save closure.
        try? await listener.persistGrants()
        return (.paired(result), nil)
      case .beginAuthentication(let request):
        guard connection == nil else { throw ClairTransportError.invalidConnection }
        return (.challenge(try await host.authority.beginAuthentication(request)), nil)
      case .authenticate(let proof):
        guard connection == nil else { throw ClairTransportError.invalidConnection }
        let authenticated = try await host.authority.authenticate(proof)
        guard !closed else {
          await host.authority.close(authenticated)
          throw ClairTransportError.connectionClosed
        }
        connection = authenticated
        listener.markAuthenticated(sessionID)
        return (.authenticated(authenticated.info), nil)
      case .authorizeRead(let scope):
        try await host.authority.authorizeRead(scope: scope, on: connection!)
        return (.ok, nil)
      case .terminalAttach(let scope, let generation, let subscriberID, let cursor):
        guard attachments.count < listener.limits.maximumAttachmentsPerConnection else {
          throw ClairTerminalError.capacity
        }
        let state = try await host.terminal.attach(
          scope: scope, generation: generation, subscriberID: subscriberID, cursor: cursor, on: connection!)
        // The boundary replaced this subscriber's previous attachment on the same session; forget it too.
        attachments = attachments.filter { $0.value.subscriberID != subscriberID || $0.value.attachment.scope != scope }
        attachments[state.attachment.id] = (state.attachment, subscriberID)
        return (
          .terminalAttached(
            attachment: state.attachment.id, cursor: state.attachment.cursor, size: state.size,
            retainedStart: state.stream.retainedStart, endOffset: state.stream.endOffset,
            isClosed: state.stream.isClosed), nil
        )
      case .terminalRead(let id, let wait):
        let attachment = try attachment(id)
        let deadline = ContinuousClock.now + .milliseconds(Int(min(wait, ClairRemoteWire.maximumReadWaitMilliseconds)))
        while true {
          if let frame = try await host.terminal.read(attachment, on: connection!) {
            return (.terminalFrame, try frame.encoded())
          }
          let stream = try await host.terminal.snapshot(attachment, on: connection!)
          if stream.isClosed || closed || ContinuousClock.now >= deadline {
            return (.terminalIdle(isClosed: stream.isClosed), nil)
          }
          // ponytail: 20 ms poll of the journal; a journal append signal would remove the latency floor.
          try await Task.sleep(for: .milliseconds(20))
        }
      case .terminalAcknowledge(let id, let cursor):
        try await host.terminal.acknowledge(try attachment(id), cursor: cursor, on: connection!)
        return (.ok, nil)
      case .terminalDetach(let id):
        try await host.terminal.detach(try attachment(id), on: connection!)
        attachments.removeValue(forKey: id)
        return (.ok, nil)
      case .terminalInput(let operationID, let scope, let epoch, let processGeneration):
        guard let binary else { throw ClairTerminalError.invalidOperation }
        let result = try await host.terminal.input(
          ClairTerminalInputRequest(
            operationID: operationID, scope: scope, epoch: epoch,
            processGeneration: processGeneration,
            bytes: binary), on: connection!)
        return (.terminalInput(result.outcome, result.receipt), nil)
      case .agentDispatch(let command):
        let result = try await host.commandBoundary.execute(command, on: connection!)
        return (.agentDispatched(outcome: result.outcome, receipt: result.receipt), nil)
      case .workspaceChangedFiles(let scope):
        guard scope.sessionID == nil else { throw ClairDaemonHostError.unauthorized }
        let summary = try await host.changedFiles(
          projectID: scope.projectID, worktreeID: scope.worktreeID, on: connection!)
        return (.changedFileSummary(summary), nil)
      case .workspaceDiff(let scope, let path, let basis):
        guard scope.sessionID == nil else { throw ClairDaemonHostError.unauthorized }
        let diff = try await host.diff(
          projectID: scope.projectID, worktreeID: scope.worktreeID,
          path: path, basis: basis, on: connection!)
        return (.gitDiff(diff), nil)
      case .sessionVerify(let scope, let cachedCursor):
        let cursor = try await host.verifySessionCursor(
          scope: scope, cachedCursor: cachedCursor, on: connection!)
        return (.sessionVerified(cursor), nil)
      case .pushRegister(let tokenBytes, let environment, let scope):
        let token = try ClairPushDeviceToken(tokenBytes)
        let registration = try await host.registerPush(
          token: token, environment: environment, scope: scope, on: connection!)
        return (
          .pushRegistered(
            scope: registration.scope, environment: registration.environment,
            expiresAt: registration.expiresAt,
            requiresRegistration: registration.requiresRegistration), nil
        )
      case .pushUnregister(let environment):
        try await host.unregisterPush(environment: environment, on: connection!)
        return (.ok, nil)
      }
    }

    private func attachment(_ id: UUID) throws -> ClairTerminalAttachment {
      guard let entry = attachments[id] else { throw ClairTerminalError.invalidOperation }
      return entry.attachment
    }

    /// Stable, non-sensitive failure codes: the error case name only.
    static func code(_ error: Error) -> String {
      if case ClairTransportError.protocolFailure(let inner) = error { return code(inner) }
      let name = String(describing: error).prefix { $0 != "(" }
      return String(name.split(separator: ".").last ?? name)
    }
  }

  private final class ClairRemoteOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
      if lock.withLock({ () -> Bool in defer { done = true }; return !done }) { body() }
    }
  }

#endif

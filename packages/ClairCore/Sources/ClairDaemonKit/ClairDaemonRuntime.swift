#if os(macOS)

  import Dispatch
  import Foundation

  import ClairShared
  import ClairTransport

  public final class ClairDaemonRuntime: @unchecked Sendable {
    public let configuration: ClairDaemonConfiguration

    private let condition = NSCondition()
    private var lifecycleState: ClairDaemonLifecycleState = .stopped
    private var instanceLock: ClairDaemonInstanceLock?
    private var controlServer: ClairDaemonControlServer?
    private var startedAt = Date()
    /// H01 owns the control socket and lock, while H10 owns provider
    /// processes and their dependent in-memory state. Stopping the daemon
    /// must fence both lifecycles.
    private let shutdownHandler: (@Sendable () async -> Void)?
    /// N09: absent when this runtime is composed without a host (e.g. a
    /// bare H01 lifecycle test), in which case `.issuePairing` fails closed
    /// with `.pairingUnavailable` instead of silently no-op'ing.
    private let pairingIssuer: (@Sendable () async throws -> ClairPairingLink)?
    /// Regenerated on every successful `start()` (see H10). This is the
    /// daemon-restart signal reported in `ClairDaemonHealth.instanceID`.
    private var instanceID = UUID()

    public init(
      configuration: ClairDaemonConfiguration,
      shutdownHandler: (@Sendable () async -> Void)? = nil,
      pairingIssuer: (@Sendable () async throws -> ClairPairingLink)? = nil
    ) {
      self.configuration = configuration
      self.shutdownHandler = shutdownHandler
      self.pairingIssuer = pairingIssuer
    }

    /// Convenience composition initializer for the real H10 daemon host.
    /// The host remains injected so H01's filesystem/control-channel runtime
    /// does not invent workspace or credential configuration of its own.
    public convenience init(
      configuration: ClairDaemonConfiguration,
      host: ClairDaemonHost
    ) {
      self.init(
        configuration: configuration,
        shutdownHandler: { await host.shutdown() },
        pairingIssuer: { try await host.authority.issuePairingLink() }
      )
    }

    public var state: ClairDaemonLifecycleState {
      condition.lock()
      defer { condition.unlock() }
      return lifecycleState
    }

    public var isRunning: Bool {
      state == .running
    }

    public var health: ClairDaemonHealth {
      condition.lock()
      let lifecycle = lifecycleState
      let startedAt = self.startedAt
      let instanceID = self.instanceID
      condition.unlock()

      let status: ClairDaemonHealthStatus
      switch lifecycle {
      case .running:
        status = .healthy
      case .stopping:
        status = .stopping
      case .stopped, .starting:
        status = .stopped
      }
      let uptime =
        lifecycle == .stopped
        ? 0
        : UInt64(max(0, Date().timeIntervalSince(startedAt)))
      return ClairDaemonHealth(
        status: status,
        lifecycle: lifecycle,
        processID: ProcessInfo.processInfo.processIdentifier,
        version: configuration.version,
        uptimeSeconds: uptime,
        instanceID: instanceID
      )
    }

    public func start() throws {
      condition.lock()
      while lifecycleState == .stopping {
        condition.wait()
      }
      guard lifecycleState == .stopped else {
        condition.unlock()
        throw ClairDaemonError.alreadyRunning
      }
      lifecycleState = .starting
      condition.unlock()

      var acquiredLock: ClairDaemonInstanceLock?
      var server: ClairDaemonControlServer?
      do {
        try ClairDaemonSocketSupport.ensurePrivateDirectory(at: configuration.paths.directoryURL)
        acquiredLock = try ClairDaemonSocketSupport.acquireLock(at: configuration.paths.lockURL)
        let newServer = ClairDaemonControlServer(
          paths: configuration.paths,
          frameLimits: configuration.frameLimits
        ) { [weak self] request in
          self?.handle(request)
            ?? .failure(
              ClairDaemonControlFailure(code: .notRunning)
            )
        }
        try newServer.start()
        server = newServer

        condition.lock()
        instanceLock = acquiredLock
        controlServer = newServer
        startedAt = Date()
        instanceID = UUID()
        lifecycleState = .running
        condition.broadcast()
        condition.unlock()
      } catch {
        server?.stopWithoutThrowing()
        if let acquiredLock {
          releaseLock(acquiredLock)
        }
        condition.lock()
        lifecycleState = .stopped
        condition.broadcast()
        condition.unlock()
        throw error
      }
    }

    public func stop() throws {
      condition.lock()
      while lifecycleState == .starting || lifecycleState == .stopping {
        condition.wait()
      }
      guard lifecycleState != .stopped else {
        condition.unlock()
        return
      }
      lifecycleState = .stopping
      let server = controlServer
      let instanceLock = self.instanceLock
      let shutdownHandler = self.shutdownHandler
      controlServer = nil
      self.instanceLock = nil
      condition.unlock()

      var cleanupError: Error?
      do {
        try server?.stop()
      } catch {
        cleanupError = error
      }
      if let shutdownHandler {
        let completion = DispatchSemaphore(value: 0)
        Task.detached {
          await shutdownHandler()
          completion.signal()
        }
        completion.wait()
      }
      if let instanceLock {
        releaseLock(instanceLock)
      }

      condition.lock()
      lifecycleState = .stopped
      condition.broadcast()
      condition.unlock()

      if cleanupError != nil {
        throw ClairDaemonError.cleanupFailed
      }
    }

    public func restart() throws {
      try stop()
      try start()
    }

    public func waitUntilStopped() {
      condition.lock()
      while lifecycleState != .stopped {
        condition.wait()
      }
      condition.unlock()
    }

    deinit {
      try? stop()
    }

    private func handle(
      _ request: ClairDaemonControlRequest
    ) -> ClairDaemonControlResponse {
      switch request {
      case .health:
        return .health(health)
      case .version:
        return .version(configuration.version)
      case .shutdown:
        do {
          try stop()
          return .shutdownAccepted
        } catch {
          return .failure(ClairDaemonControlFailure(code: .internalFailure))
        }
      case .issuePairing:
        return issuePairing()
      }
    }

    /// Bridges the actor-isolated `ClairPairingAuthority.issuePairingLink()`
    /// into this synchronous handler, mirroring how `.shutdown` already
    /// bridges its async `shutdownHandler` with a semaphore below.
    private func issuePairing() -> ClairDaemonControlResponse {
      guard let pairingIssuer else {
        return .failure(ClairDaemonControlFailure(code: .pairingUnavailable))
      }
      let semaphore = DispatchSemaphore(value: 0)
      // The semaphore below establishes the happens-before edge the compiler
      // cannot see: `outcome` is written once from the detached task, then
      // `semaphore.wait()` blocks this thread until that write is visible.
      nonisolated(unsafe) var outcome: Result<ClairPairingLink, Error>!
      Task.detached {
        do {
          outcome = .success(try await pairingIssuer())
        } catch {
          outcome = .failure(error)
        }
        semaphore.signal()
      }
      semaphore.wait()
      guard case .success(let link) = outcome else {
        return .failure(ClairDaemonControlFailure(code: .pairingUnavailable))
      }
      do {
        let code = try ClairPairingLinkCodec.encode(link)
        return .pairingIssued(
          ClairDaemonPairingIssuance(
            code: code, fingerprint: link.hostFingerprint, expiresAt: link.expiresAt))
      } catch {
        return .failure(ClairDaemonControlFailure(code: .internalFailure))
      }
    }

    private func releaseLock(_ lock: ClairDaemonInstanceLock) {
      ClairDaemonSocketSupport.releaseLock(lock)
    }
  }

  public typealias ClairDaemon = ClairDaemonRuntime

  private final class ClairDaemonControlServer: @unchecked Sendable {
    private let paths: ClairDaemonPaths
    private let frameLimits: FrameLimits
    private let handler: @Sendable (ClairDaemonControlRequest) -> ClairDaemonControlResponse
    private let condition = NSCondition()
    private var source: DispatchSourceRead?
    private var cancelSignal: DispatchSemaphore?
    private var descriptor: Int32?
    private var socketIdentity: FileIdentity?
    private var stopped = true

    init(
      paths: ClairDaemonPaths,
      frameLimits: FrameLimits,
      handler: @escaping @Sendable (ClairDaemonControlRequest) -> ClairDaemonControlResponse
    ) {
      self.paths = paths
      self.frameLimits = frameLimits
      self.handler = handler
    }

    func start() throws {
      condition.lock()
      guard stopped else {
        condition.unlock()
        throw ClairDaemonError.alreadyRunning
      }
      condition.unlock()

      try ClairDaemonSocketSupport.ensurePrivateDirectory(at: paths.directoryURL)
      try ClairDaemonSocketSupport.validateSocket(at: paths.socketURL, allowMissing: true)
      try ClairDaemonSocketSupport.removeSocketIfPresent(at: paths.socketURL)
      let listener = try ClairDaemonSocketSupport.openListener(at: paths.socketURL)
      let newSource = DispatchSource.makeReadSource(
        fileDescriptor: listener.descriptor,
        queue: DispatchQueue.global(qos: .utility)
      )
      newSource.setEventHandler { [weak self] in
        self?.acceptAvailable()
      }
      let cancelled = DispatchSemaphore(value: 0)
      newSource.setCancelHandler {
        Darwin.close(listener.descriptor)
        cancelled.signal()
      }

      condition.lock()
      descriptor = listener.descriptor
      socketIdentity = listener.identity
      source = newSource
      cancelSignal = cancelled
      stopped = false
      condition.unlock()
      newSource.resume()
    }

    func stop() throws {
      condition.lock()
      guard !stopped else {
        condition.unlock()
        return
      }
      stopped = true
      let source = self.source
      let cancelSignal = self.cancelSignal
      let identity = socketIdentity
      self.source = nil
      self.cancelSignal = nil
      descriptor = nil
      socketIdentity = nil
      condition.unlock()

      if let source {
        source.cancel()
        cancelSignal?.wait()
      }
      if let identity {
        try ClairDaemonSocketSupport.removeSocketIfOwned(
          at: paths.socketURL,
          identity: identity
        )
      }
    }

    func stopWithoutThrowing() {
      try? stop()
    }

    private func acceptAvailable() {
      condition.lock()
      guard !stopped, let descriptor else {
        condition.unlock()
        return
      }
      condition.unlock()

      while true {
        let client = Darwin.accept(descriptor, nil, nil)
        if client >= 0 {
          guard ClairDaemonSocketSupport.setBlocking(client) else {
            Darwin.close(client)
            continue
          }
          ClairDaemonSocketSupport.setNoSigPipe(client)
          ClairDaemonSocketSupport.setSocketTimeout(
            client,
            timeout: ClairDaemonSocketSupport.controlTimeout
          )
          DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handle(client: client)
          }
          continue
        }
        if errno == EINTR {
          continue
        }
        break
      }
    }

    private func handle(client: Int32) {
      defer { Darwin.close(client) }

      let response: ClairDaemonControlResponse
      do {
        let frames = try ClairDaemonSocketSupport.readFrames(
          from: client,
          limits: frameLimits,
          direction: .request
        )
        guard frames.count == 1 else {
          throw ClairDaemonError.malformedRequest
        }
        let request: ClairDaemonControlRequest
        do {
          request = try ProtocolCodec.decode(
            ClairDaemonControlRequest.self,
            from: frames[0].payload,
            limits: frameLimits
          )
        } catch let error as ProtocolError {
          throw ClairDaemonError.invalidFrame(error)
        } catch {
          throw ClairDaemonError.malformedRequest
        }
        response = handler(request)
      } catch let error as ClairDaemonError {
        response = .failure(error.controlFailure)
      } catch {
        response = .failure(ClairDaemonControlFailure(code: .internalFailure))
      }

      do {
        let payload = try ProtocolCodec.encode(response)
        let frame = try BoundedFrame(payload: payload, limits: frameLimits).encoded
        try ClairDaemonSocketSupport.writeAll(frame, to: client)
      } catch {
        return
      }
    }
  }

#endif

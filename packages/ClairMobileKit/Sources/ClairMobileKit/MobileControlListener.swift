#if canImport(Network)
  import Foundation
  @preconcurrency import Network

  public struct MobileControlListenerConfiguration: Equatable, Sendable {
    public let port: UInt16

    public init(port: UInt16 = 47_831) {
      self.port = port
    }
  }

  /// Localhost-only listener for the mobile host core.
  ///
  /// A private-network adapter such as Tailscale Serve or Cloudflare Tunnel
  /// should proxy to this listener. It deliberately binds to 127.0.0.1 and
  /// never opens the PTY broker socket. TLS/route policy lives outside this
  /// protocol package; application authentication still happens here.
  public final class MobileControlListener: @unchecked Sendable {
    private let host: MobileControlHost
    private let configuration: MobileControlListenerConfiguration
    private let queue = DispatchQueue(label: "com.diwamoto.clair.mobile-host")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var clients: [UUID: MobileControlListenerClient] = [:]

    public var onReady: ((UInt16) -> Void)?
    public var onError: ((Error) -> Void)?

    public init(
      host: MobileControlHost,
      configuration: MobileControlListenerConfiguration = .init()
    ) {
      self.host = host
      self.configuration = configuration
    }

    deinit {
      stop()
    }

    public func start() throws {
      stateLock.lock()
      defer { stateLock.unlock() }
      guard listener == nil else {
        return
      }
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
        host: NWEndpoint.Host("127.0.0.1"),
        port: NWEndpoint.Port(rawValue: configuration.port) ?? .any
      )
      let listener = try NWListener(
        using: parameters,
        on: NWEndpoint.Port(rawValue: configuration.port) ?? .any
      )
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          if let port = listener.port?.rawValue {
            self.onReady?(port)
          }
        case .failed(let error):
          self.onError?(error)
          self.stop()
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      self.listener = listener
      listener.start(queue: queue)
    }

    public func stop() {
      let clients: [MobileControlListenerClient] = stateLock.withLock {
        listener?.cancel()
        listener = nil
        let clients = Array(self.clients.values)
        self.clients.removeAll()
        return clients
      }
      for client in clients {
        client.stop()
      }
    }

    private func accept(_ connection: NWConnection) {
      let client = MobileControlListenerClient(
        connection: connection,
        host: host,
        onError: { [weak self] error in self?.onError?(error) },
        onClose: { [weak self] id in self?.removeClient(id) }
      )
      stateLock.withLock {
        clients[client.id] = client
      }
      client.start()
    }

    private func removeClient(_ id: UUID) {
      stateLock.withLock {
        clients[id] = nil
      }
    }
  }

  private final class MobileControlListenerClient: @unchecked Sendable {
    let id = UUID()

    private let connection: NWConnection
    private let control: MobileControlConnection
    private let host: MobileControlHost
    private let reportError: (Error) -> Void
    private let onClose: (UUID) -> Void
    private let queue = DispatchQueue(label: "com.diwamoto.clair.mobile-client")
    private var decoder = MobileTransportFrameDecoder()
    private var subscriptions: Set<UUID> = []
    private var stopped = false

    init(
      connection: NWConnection,
      host: MobileControlHost,
      onError: @escaping (Error) -> Void,
      onClose: @escaping (UUID) -> Void
    ) {
      self.connection = connection
      self.control = host.makeConnection()
      self.host = host
      self.reportError = onError
      self.onClose = onClose
    }

    func start() {
      connection.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        if case .failed = state {
          stop()
        }
      }
      connection.start(queue: queue)
      receive()
      poll()
    }

    func stop() {
      guard !stopped else { return }
      stopped = true
      connection.cancel()
      control.close()
      onClose(id)
    }

    private func receive() {
      guard !stopped else { return }
      connection.receive(
        minimumIncompleteLength: 1,
        maximumLength: MobileTransportFrameDecoder.maximumReceiveLength
      ) { [weak self] data, _, isComplete, error in
        guard let self else { return }
        if let error {
          reportError(error)
          stop()
          return
        }
        if let data, !data.isEmpty {
          do {
            let frames = try decoder.append(data)
            for frame in frames {
              try handle(frame)
            }
          } catch {
            send(
              MobileControlResponse.failure(
                id: "transport",
                code: "malformed_frame",
                message: error.localizedDescription
              )
            )
            stop()
            return
          }
        }
        if isComplete {
          stop()
        } else {
          receive()
        }
      }
    }

    private func handle(_ frame: MobileTransportFrame) throws {
      guard frame.kind == .control else {
        throw MobileTransportError.invalidTerminalFrame
      }
      let request = try MobileControlMessageCodec.decode(
        MobileControlRequest.self,
        from: frame
      )
      let response = control.handle(request)
      send(response)
      if request.method == .sessionSubscribe,
        let result = response.result,
        let metadata = try? result.decode(MobileSessionSubscribeMetadata.self)
      {
        subscriptions.insert(metadata.subscriptionID)
        sendEvents(control.takeInitialEvents(for: metadata.subscriptionID))
      } else if request.method == .sessionUnsubscribe, response.error == nil,
        let parameters = try? request.decodeParameters(MobileUnsubscribeRequest.self)
      {
        subscriptions.remove(parameters.subscriptionID)
      }
    }

    private func poll() {
      guard !stopped else { return }
      queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
        guard let self else { return }
        for subscriptionID in subscriptions {
          guard let events = try? host.takeSubscriptionEvents(subscriptionID) else {
            continue
          }
          sendEvents(events)
        }
        poll()
      }
    }

    private func send(_ response: MobileControlResponse) {
      guard let frame = try? MobileControlMessageCodec.encode(response) else {
        return
      }
      send(frame)
    }

    private func send(_ frame: MobileTransportFrame) {
      guard !stopped else { return }
      connection.send(
        content: frame.encoded,
        completion: .contentProcessed { [weak self] error in
          if let error {
            self?.reportError(error)
            self?.stop()
          }
        })
    }

    private func sendEvents(_ events: [MobileHostStreamEvent]) {
      for event in events {
        switch event {
        case .output(let frame):
          guard let transport = try? MobileTransportFrame.terminal(frame) else { continue }
          send(transport)
        case .gap(let gap):
          sendNotification(MobileStreamNotification(gap: gap))
        case .exit(let exit):
          sendNotification(MobileStreamNotification(exit: exit))
        }
      }
    }

    private func sendNotification(_ notification: MobileStreamNotification) {
      guard let frame = try? MobileControlMessageCodec.encode(notification) else {
        return
      }
      send(frame)
    }

  }

  extension MobileTransportFrameDecoder {
    fileprivate static let maximumReceiveLength =
      MobileTransportFrame.maximumTerminalPayloadLength + MobileTransportFrame.headerLength
  }

  extension NSLock {
    fileprivate func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
      lock()
      defer { unlock() }
      return try body()
    }
  }
#endif

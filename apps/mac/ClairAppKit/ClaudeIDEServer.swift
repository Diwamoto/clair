#if os(macOS)
  import ClairWorkspace
  import Foundation
  import Network

  /// ADR-0022: the localhost WebSocket Claude Code connects to. Bound to 127.0.0.1 only; the upgrade is refused
  /// unless it carries the lock file's token in `x-claude-code-ide-authorization`. Messages arrive and leave on the
  /// main queue, where the store answers them.
  @MainActor final class ClaudeIDEServer {
    let token = ClaudeIDE.newToken()
    private(set) var port: UInt16?
    private var listener: NWListener?
    /// Bumped per listener, so a late state change of a replaced one is ignored.
    private var generation = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// One text message from a client and how to answer it.
    var onMessage: ((String, @escaping @MainActor (String) -> Void) -> Void)?
    var onReady: ((UInt16) -> Void)?
    var hasClients: Bool { !connections.isEmpty }

    /// Listens on `preferred` (so shells kept by the daemon across restarts still point here), else any free port.
    func start(preferred: UInt16?) {
      stop()
      let token = self.token
      let ws = NWProtocolWebSocket.Options()
      ws.autoReplyPing = true
      ws.setClientRequestHandler(DispatchQueue.main) { subprotocols, headers in
        let ok = headers.contains { $0.name.lowercased() == "x-claude-code-ide-authorization" && ClaudeIDE.tokenMatches($0.value, token) }
        guard ok else { return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil) }
        return NWProtocolWebSocket.Response(status: .accept, subprotocol: ClaudeIDE.subprotocol(offered: subprotocols))
      }
      let params = NWParameters.tcp
      params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
      params.allowLocalEndpointReuse = true
      let port = preferred.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
      params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
      guard let listener = try? NWListener(using: params) else {
        if preferred != nil { start(preferred: nil) }
        return
      }
      self.listener = listener
      generation += 1
      let current = generation
      listener.stateUpdateHandler = { [weak self] state in
        MainActor.assumeIsolated {
          guard let self, self.generation == current, let listener = self.listener else { return }
          switch state {
          case .ready:
            guard let bound = listener.port?.rawValue else { return }
            self.port = bound
            self.onReady?(bound)
          case .failed:
            // The remembered port is taken: fall back to any free one.
            self.listener = nil
            listener.cancel()
            if preferred != nil { self.start(preferred: nil) }
          default: break
          }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        MainActor.assumeIsolated { self?.accept(connection) }
      }
      listener.start(queue: .main)
    }

    func stop() {
      listener?.cancel()
      listener = nil
      for c in connections.values { c.cancel() }
      connections = [:]
      port = nil
    }

    private func accept(_ connection: NWConnection) {
      let id = ObjectIdentifier(connection)
      connections[id] = connection
      connection.stateUpdateHandler = { [weak self] state in
        MainActor.assumeIsolated {
          switch state {
          case .failed, .cancelled: self?.connections[id] = nil
          default: break
          }
        }
      }
      connection.start(queue: .main)
      receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
      connection.receiveMessage { [weak self] data, context, _, error in
        MainActor.assumeIsolated {
          guard let self else { return }
          if let data, let text = String(data: data, encoding: .utf8),
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
            meta.opcode == .text
          {
            self.onMessage?(text) { [weak self, weak connection] reply in
              guard let connection else { return }
              self?.send(reply, on: connection)
            }
          }
          if error == nil, self.connections[ObjectIdentifier(connection)] != nil {
            self.receive(on: connection)
          } else {
            self.connections[ObjectIdentifier(connection)] = nil
            connection.cancel()
          }
        }
      }
    }

    private func send(_ text: String, on connection: NWConnection) {
      let meta = NWProtocolWebSocket.Metadata(opcode: .text)
      let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
      connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// A notification to every connected Claude Code session.
    func broadcast(_ text: String) {
      for c in connections.values { send(text, on: c) }
    }
  }
#endif

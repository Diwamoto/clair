#if canImport(Network)
  import Foundation
  @preconcurrency import Network

  public enum MobileControlClientConnectionError: Error, Equatable, LocalizedError, Sendable {
    case invalidAddress
    case alreadyClosed
    case notConnected
    case duplicateRequestID(String)
    case malformedResponse
    case hostIdentityMismatch
    case remote(code: String, message: String)
    case transport(String)

    public var errorDescription: String? {
      switch self {
      case .invalidAddress:
        "The mobile endpoint address is invalid."
      case .alreadyClosed:
        "The mobile connection is closed."
      case .notConnected:
        "The mobile connection is not ready."
      case .duplicateRequestID(let id):
        "A mobile request is already pending for ID \(id)."
      case .malformedResponse:
        "The mobile host returned a malformed response."
      case .hostIdentityMismatch:
        "The mobile host identity does not match the pinned identity."
      case .remote(let code, let message):
        "Mobile host error [\(code)]: \(message)"
      case .transport(let message):
        "Mobile transport failed: \(message)"
      }
    }
  }

  /// Network.framework client for the raw, framed mobile control endpoint.
  ///
  /// The endpoint can be loopback or a private-network route. Route providers
  /// remain outside this type; after they expose the same TCP address, request
  /// authentication and terminal stream handling are identical.
  public final class MobileControlClientConnection: @unchecked Sendable {
    public let endpoint: MobileControlEndpoint

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.diwamoto.clair.mobile-client-connection")
    private let expectedHostIdentity: MobileHostIdentity?
    private var decoder = MobileTransportFrameDecoder()
    private var pending: [String: CheckedContinuation<MobileControlResponse, Error>] = [:]
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    private var started = false
    private var ready = false
    private var closed = false

    public var onStreamEvent: (@Sendable (MobileHostStreamEvent) -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    public init(
      endpoint: MobileControlEndpoint,
      expectedHostIdentity: MobileHostIdentity? = nil
    ) throws {
      self.endpoint = endpoint
      self.expectedHostIdentity = expectedHostIdentity
      let (host, port) = try Self.socketAddress(for: endpoint.address)
      connection = NWConnection(
        host: host,
        port: port,
        using: .tcp
      )
    }

    deinit {
      close()
    }

    public func connect() async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        queue.async { [weak self] in
          guard let self else {
            continuation.resume(throwing: MobileControlClientConnectionError.alreadyClosed)
            return
          }
          if self.ready {
            continuation.resume()
            return
          }
          if self.closed {
            continuation.resume(throwing: MobileControlClientConnectionError.alreadyClosed)
            return
          }
          self.connectWaiters.append(continuation)
          guard !self.started else {
            return
          }
          self.started = true
          self.connection.stateUpdateHandler = { [weak self] state in
            self?.receiveState(state)
          }
          self.connection.start(queue: self.queue)
          self.receive()
        }
      }
    }

    public func close() {
      queue.async { [weak self] in
        guard let self, !self.closed else { return }
        self.fail(MobileControlClientConnectionError.alreadyClosed, cancelConnection: true)
      }
    }

    public func request(
      _ request: MobileControlRequest
    ) async throws -> MobileControlResponse {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { [weak self] in
          guard let self else {
            continuation.resume(throwing: MobileControlClientConnectionError.alreadyClosed)
            return
          }
          guard self.ready, !self.closed else {
            continuation.resume(
              throwing: self.closed
                ? MobileControlClientConnectionError.alreadyClosed
                : MobileControlClientConnectionError.notConnected)
            return
          }
          guard self.pending[request.id] == nil else {
            continuation.resume(
              throwing: MobileControlClientConnectionError.duplicateRequestID(request.id)
            )
            return
          }
          guard let frame = try? MobileControlMessageCodec.encode(request) else {
            continuation.resume(throwing: MobileControlClientConnectionError.malformedResponse)
            return
          }
          self.pending[request.id] = continuation
          self.connection.send(
            content: frame.encoded,
            completion: .contentProcessed { [weak self] error in
              guard let self, let error else { return }
              let message = error.localizedDescription
              self.queue.async { [weak self] in
                self?.fail(MobileControlClientConnectionError.transport(message))
              }
            }
          )
        }
      }
    }

    public func initialize(
      hello: MobileClientHello
    ) async throws -> MobileInitializeResult {
      let requestMessage = try MobileControlRequestFactory.initialize(hello: hello)
      let response = try await request(requestMessage)
      let result: MobileInitializeResult = try Self.decodeResult(response)
      if let expectedHostIdentity, result.hostIdentity != expectedHostIdentity {
        throw MobileControlClientConnectionError.hostIdentityMismatch
      }
      return result
    }

    public static func decodeResult<Value: Decodable>(
      _ response: MobileControlResponse
    ) throws -> Value {
      if let error = response.error {
        throw MobileControlClientConnectionError.remote(
          code: error.code,
          message: error.message
        )
      }
      guard let result = response.result else {
        throw MobileControlClientConnectionError.malformedResponse
      }
      do {
        return try result.decode(Value.self)
      } catch {
        throw MobileControlClientConnectionError.malformedResponse
      }
    }

    private func receiveState(_ state: NWConnection.State) {
      switch state {
      case .ready:
        ready = true
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters {
          waiter.resume()
        }
      case .failed(let error):
        fail(MobileControlClientConnectionError.transport(error.localizedDescription))
      case .cancelled:
        fail(MobileControlClientConnectionError.alreadyClosed, cancelConnection: false)
      default:
        break
      }
    }

    private func receive() {
      guard !closed else { return }
      connection.receive(
        minimumIncompleteLength: 1,
        maximumLength: MobileTransportFrame.maximumTerminalPayloadLength
          + MobileTransportFrame.headerLength
      ) { [weak self] data, _, isComplete, error in
        guard let self else { return }
        if let error {
          self.fail(MobileControlClientConnectionError.transport(error.localizedDescription))
          return
        }
        do {
          if let data, !data.isEmpty {
            let frames = try self.decoder.append(data)
            for frame in frames {
              try self.handle(frame)
            }
          }
          if isComplete {
            try self.decoder.finish()
            self.fail(MobileControlClientConnectionError.alreadyClosed, cancelConnection: false)
          } else {
            self.receive()
          }
        } catch {
          self.fail(error)
        }
      }
    }

    private func handle(_ frame: MobileTransportFrame) throws {
      switch frame.kind {
      case .terminal:
        let terminal = try MobileTerminalFrame.decode(frame.payload)
        onStreamEvent?(.output(terminal))
      case .control:
        if let response = try? MobileControlMessageCodec.decode(
          MobileControlResponse.self,
          from: frame
        ) {
          guard let continuation = pending.removeValue(forKey: response.id) else {
            throw MobileControlClientConnectionError.malformedResponse
          }
          continuation.resume(returning: response)
        } else {
          let notification = try MobileControlMessageCodec.decode(
            MobileStreamNotification.self,
            from: frame
          )
          let event: MobileHostStreamEvent
          switch notification.kind {
          case .gap:
            guard let startOffset = notification.startOffset,
              let endOffset = notification.endOffset
            else {
              throw MobileControlClientConnectionError.malformedResponse
            }
            event = .gap(
              MobileTerminalGap(
                streamID: notification.streamID,
                sessionEpoch: notification.sessionEpoch,
                startOffset: startOffset,
                endOffset: endOffset
              )
            )
          case .exit:
            guard let status = notification.status, let offset = notification.endOffset else {
              throw MobileControlClientConnectionError.malformedResponse
            }
            event = .exit(
              MobileTerminalExit(
                streamID: notification.streamID,
                sessionEpoch: notification.sessionEpoch,
                status: status,
                offset: offset
              )
            )
          }
          onStreamEvent?(event)
        }
      }
    }

    private func fail(_ error: Error, cancelConnection: Bool = true) {
      guard !closed || !connectWaiters.isEmpty || !pending.isEmpty else {
        return
      }
      closed = true
      ready = false
      if cancelConnection {
        connection.cancel()
      }
      let waiters = connectWaiters
      connectWaiters.removeAll()
      for waiter in waiters {
        waiter.resume(throwing: error)
      }
      let requests = pending.values
      pending.removeAll()
      for request in requests {
        request.resume(throwing: error)
      }
      onError?(error)
    }

    private static func socketAddress(
      for address: String
    ) throws -> (NWEndpoint.Host, NWEndpoint.Port) {
      let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
      if let components = URLComponents(string: normalized),
        let host = components.host,
        let rawPort = components.port,
        let port = NWEndpoint.Port(rawValue: UInt16(rawPort))
      {
        return (NWEndpoint.Host(host), port)
      }

      if normalized.hasPrefix("[") {
        guard let closeBracket = normalized.firstIndex(of: "]") else {
          throw MobileControlClientConnectionError.invalidAddress
        }
        let colon = normalized.index(after: closeBracket)
        guard colon < normalized.endIndex, normalized[colon] == ":" else {
          throw MobileControlClientConnectionError.invalidAddress
        }
        let host = String(normalized[normalized.index(after: normalized.startIndex)..<closeBracket])
        let rawPort = String(normalized[normalized.index(after: colon)...])
        guard !host.isEmpty, let portValue = UInt16(rawPort),
          let port = NWEndpoint.Port(rawValue: portValue)
        else {
          throw MobileControlClientConnectionError.invalidAddress
        }
        return (NWEndpoint.Host(host), port)
      }
      guard let separator = normalized.lastIndex(of: ":"), separator > normalized.startIndex,
        separator < normalized.index(before: normalized.endIndex)
      else {
        throw MobileControlClientConnectionError.invalidAddress
      }
      let host = String(normalized[..<separator])
      let rawPort = String(normalized[normalized.index(after: separator)...])
      guard !host.isEmpty, let portValue = UInt16(rawPort),
        let port = NWEndpoint.Port(rawValue: portValue)
      else {
        throw MobileControlClientConnectionError.invalidAddress
      }
      return (NWEndpoint.Host(host), port)
    }
  }
#endif

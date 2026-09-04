import Foundation

/// A single authenticated projection of the mobile control protocol.
///
/// The network adapter owns bytes and connection lifetime. This object owns
/// request decoding, authentication state, and the mapping to the one host
/// core, so another transport cannot accidentally bypass the same checks.
public final class MobileControlConnection: @unchecked Sendable {
  public let id: UUID

  private let host: MobileControlHost
  private let stateLock = NSLock()
  private var authenticatedDeviceID: UUID?
  private var pendingEvents: [UUID: [MobileHostStreamEvent]] = [:]
  private var isClosed = false

  init(host: MobileControlHost, id: UUID = UUID()) {
    self.host = host
    self.id = id
  }

  deinit {
    close()
  }

  public func close() {
    let shouldClose = stateLock.withLock {
      guard !isClosed else { return false }
      isClosed = true
      authenticatedDeviceID = nil
      pendingEvents.removeAll()
      return true
    }
    if shouldClose {
      host.closeConnection(id)
    }
  }

  public func handle(
    _ request: MobileControlRequest,
    now: Date = Date()
  ) -> MobileControlResponse {
    do {
      let value: MobileJSONValue
      switch request.method {
      case .initialize:
        let client = try request.decodeParameters(MobileClientHello.self)
        let server = MobileServerHello(version: host.identity.protocolVersion)
        let negotiated = try MobileProtocolNegotiator.negotiate(client: client, server: server)
        value = try .from(
          MobileInitializeResult(
            hostIdentity: host.identity,
            negotiated: negotiated,
            isEnabled: host.isEnabled
          )
        )

      case .sessionList:
        let deviceID = try requireAuthenticated()
        value = try .from(
          MobileSessionListResult(sessions: host.visibleSessions(for: deviceID))
        )

      case .sessionSubscribe:
        let deviceID = try requireAuthenticated()
        let parameters = try request.decodeParameters(MobileSessionSubscribeRequest.self)
        let receipt = try host.subscribe(
          deviceID: deviceID,
          sessionID: parameters.sessionID,
          epoch: parameters.epoch,
          cursor: parameters.cursor,
          maximumQueueBytes: parameters.maximumQueueBytes,
          connectionID: id
        )
        stateLock.withLock {
          pendingEvents[receipt.subscriptionID] = receipt.events
        }
        value = try .from(MobileSessionSubscribeMetadata(receipt: receipt))

      case .sessionUnsubscribe:
        let deviceID = try requireAuthenticated()
        let parameters = try request.decodeParameters(MobileUnsubscribeRequest.self)
        try host.unsubscribe(parameters.subscriptionID, deviceID: deviceID)
        value = .object(["unsubscribed": .bool(true)])

      case .terminalInput, .terminalPaste:
        let deviceID = try requireAuthenticated()
        let operation = try request.decodeParameters(MobileTerminalInputOperation.self)
        guard operation.deviceID == deviceID else {
          throw MobileProtocolError.invalidScope(.writeTerminal)
        }
        value = try .from(host.acceptTerminalInput(operation))

      case .terminalInterrupt:
        let deviceID = try requireAuthenticated()
        let parameters = try request.decodeParameters(MobileTerminalInterruptRequest.self)
        guard parameters.deviceID == deviceID else {
          throw MobileProtocolError.invalidScope(.signal)
        }
        value = try .from(
          host.acceptTerminalInterrupt(
            id: parameters.operationID,
            deviceID: deviceID,
            sessionID: parameters.sessionID
          )
        )

      case .terminalSignal:
        throw MobileHostError.invalidOperation

      case .agentList:
        let deviceID = try requireAuthenticated()
        value = try .from(
          MobileAgentCatalog(
            agents: host.visibleAgents(for: deviceID),
            profiles: host.registeredProfiles()
          )
        )

      case .agentStatus:
        let deviceID = try requireAuthenticated()
        let parameters = try request.decodeParameters(MobileAgentStatusRequest.self)
        guard
          let agent = try host.visibleAgents(for: deviceID).first(where: {
            $0.id == parameters.agentID
          })
        else {
          throw MobileProtocolError.sessionNotVisible(parameters.agentID)
        }
        value = try .from(agent)

      case .agentInput:
        let deviceID = try requireAuthenticated()
        let operation = try request.decodeParameters(MobileAgentInputOperation.self)
        guard operation.deviceID == deviceID else {
          throw MobileProtocolError.invalidScope(.steerAgent)
        }
        value = try .from(host.acceptAgentInput(operation))

      case .agentInterrupt, .agentStop:
        let deviceID = try requireAuthenticated()
        let parameters = try request.decodeParameters(MobileAgentControlOperation.self)
        guard parameters.deviceID == deviceID else {
          throw MobileProtocolError.invalidScope(
            parameters.action == .interrupt ? .signal : .terminate
          )
        }
        let expectedAction: MobileAgentControlAction =
          request.method == .agentInterrupt
          ? .interrupt
          : .stop
        guard parameters.action == expectedAction else {
          throw MobileHostError.invalidOperation
        }
        value = try .from(host.acceptAgentControl(parameters))

      case .agentLaunch:
        let deviceID = try requireAuthenticated()
        let operation = try request.decodeParameters(MobileAgentLaunchOperation.self)
        guard operation.deviceID == deviceID else {
          throw MobileProtocolError.invalidScope(.spawnSession)
        }
        value = try .from(host.acceptAgentLaunch(operation))

      case .deviceList:
        _ = try host.requireScope(.manageDevices, for: id)
        value = try .from(host.devices())

      case .deviceRevoke:
        _ = try host.requireScope(.manageDevices, for: id)
        let parameters = try request.decodeParameters(MobileDeviceIDRequest.self)
        let closed = try host.revokeDevice(parameters.deviceID, now: now)
        value = .object([
          "deviceID": .string(parameters.deviceID.uuidString),
          "closedConnections": .number(Double(closed.count)),
          "revoked": .bool(true),
        ])

      case .pair:
        let parameters = try request.decodeParameters(MobilePairRequest.self)
        guard parameters.confirmedFingerprint == host.identity.fingerprint else {
          throw MobileHostError.invalidHostIdentity
        }
        value = try .from(
          host.pair(
            link: parameters.link,
            displayName: parameters.displayName,
            devicePublicKey: parameters.devicePublicKey,
            now: now
          )
        )

      case .challenge:
        let parameters = try request.decodeParameters(MobileChallengeRequest.self)
        value = try .from(host.issueChallenge(for: parameters.deviceID, now: now))

      case .authenticate:
        let parameters = try request.decodeParameters(MobileAuthenticateRequest.self)
        let deviceConnection = try host.authenticate(
          deviceID: parameters.deviceID,
          token: parameters.token,
          challenge: parameters.challenge,
          signature: parameters.signature,
          now: now,
          connectionID: id
        )
        stateLock.withLock {
          authenticatedDeviceID = parameters.deviceID
        }
        value = .object([
          "connectionID": .string(deviceConnection.uuidString),
          "authenticated": .bool(true),
        ])
      }
      return MobileControlResponse(id: request.id, result: value, error: nil)
    } catch {
      return MobileControlResponse.failure(
        id: request.id,
        code: Self.errorCode(for: error),
        message: error.localizedDescription
      )
    }
  }

  public func takeInitialEvents(
    for subscriptionID: UUID
  ) -> [MobileHostStreamEvent] {
    stateLock.withLock {
      pendingEvents.removeValue(forKey: subscriptionID) ?? []
    }
  }

  private func requireAuthenticated() throws -> UUID {
    let deviceID = stateLock.withLock { authenticatedDeviceID }
    guard let deviceID else {
      throw MobileHostError.authenticationFailed
    }
    _ = try host.deviceID(for: id)
    return deviceID
  }

  private static func errorCode(for error: Error) -> String {
    switch error {
    case MobileHostError.disabled:
      "disabled"
    case MobileHostError.pairingExpired, MobileHostError.pairingAlreadyUsed:
      "pairing_expired"
    case MobileHostError.invalidHostIdentity:
      "host_identity_mismatch"
    case MobileHostError.revokedDevice, MobileProtocolError.revokedDevice:
      "revoked"
    case MobileProtocolError.invalidScope:
      "scope_denied"
    case MobileProtocolError.sessionNotVisible:
      "session_not_visible"
    case MobileProtocolError.operationIDReuse:
      "operation_replay"
    case MobileTransportError.frameTooLarge, MobileProtocolError.frameTooLarge:
      "frame_too_large"
    default:
      "request_failed"
    }
  }
}

extension NSLock {
  fileprivate func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock()
    defer { unlock() }
    return try body()
  }
}

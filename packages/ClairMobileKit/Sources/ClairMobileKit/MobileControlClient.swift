import Foundation

public struct MobileClientHostRecord: Codable, Equatable, Sendable {
  public let endpoint: MobileControlEndpoint
  public let hostIdentity: MobileHostIdentity
  public let credential: MobileDeviceCredential

  public init(
    endpoint: MobileControlEndpoint,
    hostIdentity: MobileHostIdentity,
    credential: MobileDeviceCredential
  ) throws {
    guard hostIdentity == credential.hostIdentity else {
      throw MobileHostError.invalidHostIdentity
    }
    self.endpoint = endpoint
    self.hostIdentity = hostIdentity
    self.credential = credential
  }
}

public struct MobileClientViewport: Codable, Equatable, Sendable {
  public let rows: UInt16
  public let columns: UInt16

  public init(rows: UInt16, columns: UInt16) throws {
    guard rows > 0, columns > 0 else {
      throw MobileHostError.invalidOperation
    }
    self.rows = rows
    self.columns = columns
  }
}

public struct MobileClientSessionState: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let descriptor: MobileSessionDescriptor
  public let subscriptionID: UUID
  public let streamID: UInt32
  public let epoch: UInt64
  public private(set) var cursor: UInt64
  public private(set) var scrollback: Data
  public private(set) var isGap: Bool
  public private(set) var isExited: Bool
  public private(set) var exitStatus: Int?

  init(
    descriptor: MobileSessionDescriptor,
    subscriptionID: UUID,
    streamID: UInt32,
    epoch: UInt64,
    cursor: UInt64,
    scrollback: Data,
    isGap: Bool = false,
    isExited: Bool = false,
    exitStatus: Int? = nil
  ) {
    id = descriptor.id
    self.descriptor = descriptor
    self.subscriptionID = subscriptionID
    self.streamID = streamID
    self.epoch = epoch
    self.cursor = cursor
    self.scrollback = scrollback
    self.isGap = isGap
    self.isExited = isExited
    self.exitStatus = exitStatus
  }

  mutating func apply(
    _ event: MobileHostStreamEvent,
    maximumScrollbackBytes: Int
  ) throws -> MobileClientStreamEvent {
    switch event {
    case .output(let frame):
      guard frame.streamID == streamID, frame.sessionEpoch == epoch else {
        throw MobileHostError.outputEpochMismatch
      }
      let frameEnd = frame.startOffset &+ UInt64(frame.payload.count)
      guard frameEnd > cursor else {
        return .duplicateOutput(sessionID: id, cursor: cursor)
      }
      guard frame.startOffset <= cursor else {
        throw MobileHostError.outputOffsetDiscontinuity(expected: cursor, actual: frame.startOffset)
      }
      let trim = Int(cursor - frame.startOffset)
      let payload = trim == 0 ? frame.payload : Data(frame.payload.dropFirst(trim))
      guard !payload.isEmpty else {
        return .duplicateOutput(sessionID: id, cursor: cursor)
      }
      scrollback.append(payload)
      let limit = max(1, maximumScrollbackBytes)
      if scrollback.count > limit {
        scrollback = Data(scrollback.suffix(limit))
      }
      cursor = frameEnd
      isGap = false
      return .output(sessionID: id, data: payload, cursor: cursor)

    case .gap(let gap):
      guard gap.streamID == streamID, gap.sessionEpoch == epoch else {
        throw MobileHostError.outputEpochMismatch
      }
      guard gap.endOffset >= gap.startOffset else {
        throw MobileHostError.invalidCursor
      }
      scrollback.removeAll(keepingCapacity: true)
      cursor = gap.endOffset
      isGap = true
      return .gap(
        sessionID: id,
        startOffset: gap.startOffset,
        endOffset: gap.endOffset
      )

    case .exit(let exit):
      guard exit.streamID == streamID, exit.sessionEpoch == epoch else {
        throw MobileHostError.outputEpochMismatch
      }
      guard exit.offset >= cursor else {
        return .duplicateExit(sessionID: id, status: exit.status)
      }
      cursor = exit.offset
      isExited = true
      exitStatus = exit.status
      return .exit(sessionID: id, status: exit.status, cursor: cursor)
    }
  }
}

public enum MobileClientStreamEvent: Equatable, Sendable {
  case output(sessionID: UUID, data: Data, cursor: UInt64)
  case gap(sessionID: UUID, startOffset: UInt64, endOffset: UInt64)
  case exit(sessionID: UUID, status: Int, cursor: UInt64)
  case duplicateOutput(sessionID: UUID, cursor: UInt64)
  case duplicateExit(sessionID: UUID, status: Int)
}

/// Shared client-side state for iPhone/iPad and macOS test clients.
///
/// It deliberately stores only bounded raw terminal bytes. A UI can render
/// `scrollback` locally and keep its own viewport without ever sending a
/// resize operation to the host PTY.
public final class MobileControlClientModel: @unchecked Sendable {
  public static let defaultMaximumScrollbackBytes = 256 * 1024

  private let lock = NSLock()
  private let maximumScrollbackBytes: Int
  private var sessions: [UUID: MobileClientSessionState] = [:]
  private var viewport: MobileClientViewport?

  public init(
    maximumScrollbackBytes: Int = MobileControlClientModel.defaultMaximumScrollbackBytes
  ) {
    self.maximumScrollbackBytes = max(1, maximumScrollbackBytes)
  }

  public var localViewport: MobileClientViewport? {
    lock.withLock { viewport }
  }

  public func setLocalViewport(_ viewport: MobileClientViewport?) {
    lock.withLock {
      self.viewport = viewport
    }
  }

  public func replaceSessionCatalog(_ descriptors: [MobileSessionDescriptor]) {
    lock.withLock {
      let visibleIDs = Set(descriptors.map(\.id))
      sessions = sessions.filter { visibleIDs.contains($0.key) }
    }
  }

  @discardableResult
  public func attach(
    descriptor: MobileSessionDescriptor,
    receipt: MobileSubscriptionReceipt
  ) throws -> MobileClientSessionState {
    guard receipt.session.sessionID == descriptor.id else {
      throw MobileHostError.sessionNotFound(receipt.session.sessionID)
    }
    let state = try lock.withLock {
      let initialCursor =
        receipt.events.compactMap { event -> UInt64? in
          switch event {
          case .output(let frame):
            return frame.startOffset
          case .gap(let gap):
            return gap.startOffset
          case .exit:
            return nil
          }
        }.first ?? receipt.session.currentOffset
      var state = MobileClientSessionState(
        descriptor: descriptor,
        subscriptionID: receipt.subscriptionID,
        streamID: receipt.streamID,
        epoch: receipt.session.epoch,
        cursor: initialCursor,
        scrollback: Data(),
        isExited: receipt.session.isExited
      )
      guard state.streamID > 0 else {
        throw MobileHostError.invalidOperation
      }
      for event in receipt.events {
        _ = try state.apply(event, maximumScrollbackBytes: maximumScrollbackBytes)
      }
      sessions[descriptor.id] = state
      return state
    }
    return state
  }

  public func state(for sessionID: UUID) -> MobileClientSessionState? {
    lock.withLock { sessions[sessionID] }
  }

  @discardableResult
  public func apply(
    _ event: MobileHostStreamEvent,
    sessionID: UUID
  ) throws -> MobileClientStreamEvent {
    try lock.withLock {
      guard var state = sessions[sessionID] else {
        throw MobileHostError.sessionNotFound(sessionID)
      }
      let result = try state.apply(event, maximumScrollbackBytes: maximumScrollbackBytes)
      sessions[sessionID] = state
      return result
    }
  }

  public func remove(sessionID: UUID) {
    lock.withLock {
      sessions[sessionID] = nil
    }
  }
}

public enum MobileControlRequestFactory {
  public static func initialize(
    id: String = UUID().uuidString,
    hello: MobileClientHello
  ) throws -> MobileControlRequest {
    try MobileControlRequest(id: id, method: .initialize, parameters: hello)
  }

  public static func pair(
    id: String = UUID().uuidString,
    request: MobilePairRequest
  ) throws -> MobileControlRequest {
    try MobileControlRequest(id: id, method: .pair, parameters: request)
  }

  public static func challenge(
    id: String = UUID().uuidString,
    deviceID: UUID
  ) throws -> MobileControlRequest {
    try MobileControlRequest(
      id: id,
      method: .challenge,
      parameters: MobileChallengeRequest(deviceID: deviceID)
    )
  }

  public static func authenticate(
    id: String = UUID().uuidString,
    request: MobileAuthenticateRequest
  ) throws -> MobileControlRequest {
    try MobileControlRequest(id: id, method: .authenticate, parameters: request)
  }

  public static func sessionList(id: String = UUID().uuidString) -> MobileControlRequest {
    MobileControlRequest(id: id, method: .sessionList)
  }

  public static func subscribe(
    id: String = UUID().uuidString,
    request: MobileSessionSubscribeRequest
  ) throws -> MobileControlRequest {
    try MobileControlRequest(id: id, method: .sessionSubscribe, parameters: request)
  }

  public static func terminalInput(
    id: String = UUID().uuidString,
    operation: MobileTerminalInputOperation
  ) throws -> MobileControlRequest {
    try MobileControlRequest(id: id, method: .terminalInput, parameters: operation)
  }

  public static func terminalInterrupt(
    id: String = UUID().uuidString,
    request: MobileTerminalInterruptRequest
  ) throws -> MobileControlRequest {
    try MobileControlRequest(id: id, method: .terminalInterrupt, parameters: request)
  }

  public static func agentList(id: String = UUID().uuidString) -> MobileControlRequest {
    MobileControlRequest(id: id, method: .agentList)
  }

  public static func agentLaunch(
    id: String = UUID().uuidString,
    operation: MobileAgentLaunchOperation
  ) throws -> MobileControlRequest {
    try MobileControlRequest(id: id, method: .agentLaunch, parameters: operation)
  }
}

extension NSLock {
  fileprivate func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock()
    defer { unlock() }
    return try body()
  }
}

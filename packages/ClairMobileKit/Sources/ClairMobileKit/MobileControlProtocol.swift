import Foundation

public enum MobileControlScope: String, CaseIterable, Codable, Hashable, Sendable {
  case view
  case writeTerminal = "write_terminal"
  case steerAgent = "steer_agent"
  case approve
  case signal
  case terminate
  case spawnSession = "spawn_session"
  case manageDevices = "manage_devices"
}

public enum MobileCapability: String, CaseIterable, Codable, Hashable, Sendable {
  case rawTerminal = "raw_terminal"
  case terminalInput = "terminal_input"
  case terminalInterrupt = "terminal_interrupt"
  case agentCatalog = "agent_catalog"
  case agentStatus = "agent_status"
  case agentControl = "agent_control"
  case agentLaunch = "agent_launch"
  case attentionNotifications = "attention_notifications"
}

public struct MobileProtocolVersion: Codable, Equatable, Hashable, Sendable {
  public let major: UInt8
  public let minor: UInt8

  public init(major: UInt8, minor: UInt8) {
    self.major = major
    self.minor = minor
  }
}

public struct MobileClientHello: Codable, Equatable, Sendable {
  public let clientName: String
  public let version: MobileProtocolVersion
  public let maxFramePayload: Int
  public let capabilities: Set<MobileCapability>

  public init(
    clientName: String,
    version: MobileProtocolVersion = .init(major: 1, minor: 0),
    maxFramePayload: Int = MobileTerminalFrame.defaultMaximumPayloadLength,
    capabilities: Set<MobileCapability> = Set(MobileCapability.allCases)
  ) {
    self.clientName = clientName
    self.version = version
    self.maxFramePayload = maxFramePayload
    self.capabilities = capabilities
  }
}

public struct MobileServerHello: Codable, Equatable, Sendable {
  public let version: MobileProtocolVersion
  public let maxFramePayload: Int
  public let capabilities: Set<MobileCapability>

  public init(
    version: MobileProtocolVersion = .init(major: 1, minor: 0),
    maxFramePayload: Int = MobileTerminalFrame.defaultMaximumPayloadLength,
    capabilities: Set<MobileCapability> = Set(MobileCapability.allCases)
  ) {
    self.version = version
    self.maxFramePayload = maxFramePayload
    self.capabilities = capabilities
  }
}

public struct MobileNegotiatedSession: Codable, Equatable, Sendable {
  public let version: MobileProtocolVersion
  public let maxFramePayload: Int
  public let capabilities: Set<MobileCapability>

  public init(
    version: MobileProtocolVersion,
    maxFramePayload: Int,
    capabilities: Set<MobileCapability>
  ) {
    self.version = version
    self.maxFramePayload = maxFramePayload
    self.capabilities = capabilities
  }
}

public enum MobileProtocolError: Error, Equatable, LocalizedError, Sendable {
  case invalidClientName
  case invalidFramePayloadLength(Int)
  case invalidMagic
  case unsupportedMajor(expected: UInt8, actual: UInt8)
  case unknownFrameKind(UInt8)
  case frameTooLarge(Int)
  case truncatedFrame
  case trailingFrameBytes(Int)
  case invalidFrameFlags(UInt8)
  case invalidStreamID
  case invalidSessionEpoch
  case invalidScope(MobileControlScope)
  case revokedDevice
  case sessionNotVisible(UUID)
  case operationIDReuse(UUID)
  case invalidAgentProfile
  case invalidOperationPayload

  public var errorDescription: String? {
    switch self {
    case .invalidClientName:
      "Mobile client name must not be empty."
    case .invalidFramePayloadLength(let length):
      "Mobile terminal frame payload has an invalid length: \(length)."
    case .invalidMagic:
      "Mobile terminal frame has invalid magic bytes."
    case .unsupportedMajor(let expected, let actual):
      "Mobile protocol major version \(actual) is not supported; expected \(expected)."
    case .unknownFrameKind(let kind):
      "Mobile terminal frame kind 0x\(String(kind, radix: 16)) is unknown."
    case .frameTooLarge(let length):
      "Mobile terminal frame payload is too large: \(length) bytes."
    case .truncatedFrame:
      "Mobile terminal frame is truncated."
    case .trailingFrameBytes(let length):
      "Mobile terminal frame has \(length) trailing bytes."
    case .invalidFrameFlags(let flags):
      "Mobile terminal frame has unsupported flags: 0x\(String(flags, radix: 16))."
    case .invalidStreamID:
      "Mobile terminal frame stream ID must be non-zero."
    case .invalidSessionEpoch:
      "Mobile terminal frame session epoch must be non-zero."
    case .invalidScope(let scope):
      "Mobile device is missing the \(scope.rawValue) scope."
    case .revokedDevice:
      "The mobile device has been revoked."
    case .sessionNotVisible(let sessionID):
      "The mobile device cannot access session \(sessionID.uuidString)."
    case .operationIDReuse(let operationID):
      "Operation ID was reused with different input: \(operationID.uuidString)."
    case .invalidAgentProfile:
      "The requested agent profile is not registered by Clair."
    case .invalidOperationPayload:
      "Mobile terminal input payload must not be empty."
    }
  }
}

public enum MobileProtocolNegotiator {
  public static func negotiate(
    client: MobileClientHello,
    server: MobileServerHello
  ) throws -> MobileNegotiatedSession {
    guard !client.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MobileProtocolError.invalidClientName
    }
    guard client.version.major == server.version.major else {
      throw MobileProtocolError.unsupportedMajor(
        expected: server.version.major,
        actual: client.version.major
      )
    }

    let maximumPayload = min(
      min(client.maxFramePayload, server.maxFramePayload),
      MobileTerminalFrame.defaultMaximumPayloadLength
    )
    guard maximumPayload > 0 else {
      throw MobileProtocolError.invalidFramePayloadLength(maximumPayload)
    }
    return MobileNegotiatedSession(
      version: .init(
        major: server.version.major,
        minor: min(client.version.minor, server.version.minor)
      ),
      maxFramePayload: maximumPayload,
      capabilities: client.capabilities.intersection(server.capabilities)
    )
  }
}

public enum MobileControlMethod: String, CaseIterable, Codable, Sendable {
  case initialize
  case pair = "device/pair"
  case challenge = "device/challenge"
  case authenticate = "device/authenticate"
  case sessionList = "session/list"
  case sessionSubscribe = "session/subscribe"
  case sessionUnsubscribe = "session/unsubscribe"
  case terminalInput = "terminal/input"
  case terminalPaste = "terminal/paste"
  case terminalInterrupt = "terminal/interrupt"
  case terminalSignal = "terminal/signal"
  case agentList = "agent/list"
  case agentStatus = "agent/status"
  case agentInput = "agent/input"
  case agentInterrupt = "agent/interrupt"
  case agentStop = "agent/stop"
  case agentLaunch = "agent/launch"
  case deviceList = "device/list"
  case deviceRevoke = "device/revoke"
}

public enum MobileTerminalFrameKind: UInt8, Codable, Sendable {
  case output = 1
  case snapshot = 2
}

public struct MobileTerminalFrame: Equatable, Sendable {
  public static let defaultMaximumPayloadLength = 64 * 1024
  public static let headerLength = 30

  private static let magic: [UInt8] = [0x4d, 0x43]

  public let version: MobileProtocolVersion
  public let kind: MobileTerminalFrameKind
  public let flags: UInt8
  public let streamID: UInt32
  public let sessionEpoch: UInt64
  public let startOffset: UInt64
  public let payload: Data

  public init(
    kind: MobileTerminalFrameKind,
    version: MobileProtocolVersion = .init(major: 1, minor: 0),
    flags: UInt8 = 0,
    streamID: UInt32,
    sessionEpoch: UInt64,
    startOffset: UInt64,
    payload: Data,
    maximumPayloadLength: Int = Self.defaultMaximumPayloadLength
  ) throws {
    guard version.major == 1 else {
      throw MobileProtocolError.unsupportedMajor(expected: 1, actual: version.major)
    }
    guard flags == 0 else {
      throw MobileProtocolError.invalidFrameFlags(flags)
    }
    guard streamID > 0 else {
      throw MobileProtocolError.invalidStreamID
    }
    guard sessionEpoch > 0 else {
      throw MobileProtocolError.invalidSessionEpoch
    }
    guard !payload.isEmpty else {
      throw MobileProtocolError.invalidFramePayloadLength(payload.count)
    }
    guard payload.count <= min(maximumPayloadLength, Self.defaultMaximumPayloadLength) else {
      throw MobileProtocolError.frameTooLarge(payload.count)
    }
    self.version = version
    self.kind = kind
    self.flags = flags
    self.streamID = streamID
    self.sessionEpoch = sessionEpoch
    self.startOffset = startOffset
    self.payload = payload
  }

  public var encoded: Data {
    var data = Data(Self.magic)
    data.append(version.major)
    data.append(version.minor)
    data.append(kind.rawValue)
    data.append(flags)
    Self.appendUInt32(streamID, to: &data)
    Self.appendUInt64(sessionEpoch, to: &data)
    Self.appendUInt64(startOffset, to: &data)
    Self.appendUInt32(UInt32(payload.count), to: &data)
    data.append(payload)
    return data
  }

  public static func decode(
    _ data: Data,
    maximumPayloadLength: Int = Self.defaultMaximumPayloadLength
  ) throws -> MobileTerminalFrame {
    guard data.count >= headerLength else {
      throw MobileProtocolError.truncatedFrame
    }
    let bytes = Array(data)
    guard Array(bytes.prefix(2)) == magic else {
      throw MobileProtocolError.invalidMagic
    }
    guard bytes[2] == 1 else {
      throw MobileProtocolError.unsupportedMajor(expected: 1, actual: bytes[2])
    }
    guard let kind = MobileTerminalFrameKind(rawValue: bytes[4]) else {
      throw MobileProtocolError.unknownFrameKind(bytes[4])
    }
    let flags = bytes[5]
    guard flags == 0 else {
      throw MobileProtocolError.invalidFrameFlags(flags)
    }
    let streamID = readUInt32(bytes, from: 6)
    let sessionEpoch = readUInt64(bytes, from: 10)
    let startOffset = readUInt64(bytes, from: 18)
    let payloadLength = Int(readUInt32(bytes, from: 26))
    guard payloadLength <= maximumPayloadLength else {
      throw MobileProtocolError.frameTooLarge(payloadLength)
    }
    let expectedLength = headerLength + payloadLength
    guard data.count >= expectedLength else {
      throw MobileProtocolError.truncatedFrame
    }
    guard data.count == expectedLength else {
      throw MobileProtocolError.trailingFrameBytes(data.count - expectedLength)
    }
    return try MobileTerminalFrame(
      kind: kind,
      version: .init(major: bytes[2], minor: bytes[3]),
      flags: flags,
      streamID: streamID,
      sessionEpoch: sessionEpoch,
      startOffset: startOffset,
      payload: Data(bytes[headerLength..<expectedLength]),
      maximumPayloadLength: maximumPayloadLength
    )
  }

  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func appendUInt64(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
      data.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
  }

  private static func readUInt32(_ bytes: [UInt8], from offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24
      | UInt32(bytes[offset + 1]) << 16
      | UInt32(bytes[offset + 2]) << 8
      | UInt32(bytes[offset + 3])
  }

  private static func readUInt64(_ bytes: [UInt8], from offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { result, index in
      (result << 8) | UInt64(bytes[offset + index])
    }
  }
}

public enum MobileSessionLifecycle: String, Codable, Sendable {
  case starting
  case running
  case exited
  case unavailable
}

public enum MobileAgentState: String, Codable, CaseIterable, Sendable {
  case starting
  case running
  case attention
  case exited
  case unavailable
}

public struct MobileAgentDescriptor: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let projectID: UUID
  public let worktreeID: UUID?
  public let profileID: String
  public let title: String
  public let cwd: String
  public let lifecycle: MobileSessionLifecycle
  public let state: MobileAgentState
  public let attention: Bool
  public let lastActivityAt: Date?
  public let capabilities: Set<MobileCapability>

  public init(
    id: UUID,
    projectID: UUID,
    worktreeID: UUID? = nil,
    profileID: String,
    title: String,
    cwd: String,
    lifecycle: MobileSessionLifecycle,
    state: MobileAgentState,
    attention: Bool = false,
    lastActivityAt: Date? = nil,
    capabilities: Set<MobileCapability>
  ) {
    self.id = id
    self.projectID = projectID
    self.worktreeID = worktreeID
    self.profileID = profileID
    self.title = title
    self.cwd = cwd
    self.lifecycle = lifecycle
    self.state = state
    self.attention = attention
    self.lastActivityAt = lastActivityAt
    self.capabilities = capabilities
  }
}

public struct MobileAgentProfileDescriptor: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let capabilities: Set<MobileCapability>

  public init(
    id: String,
    title: String,
    capabilities: Set<MobileCapability> = [.agentLaunch]
  ) {
    self.id = id
    self.title = title
    self.capabilities = capabilities
  }
}

public struct MobileAgentCatalog: Codable, Equatable, Sendable {
  public let agents: [MobileAgentDescriptor]
  public let profiles: [MobileAgentProfileDescriptor]

  public init(
    agents: [MobileAgentDescriptor],
    profiles: [MobileAgentProfileDescriptor]
  ) {
    self.agents = agents
    self.profiles = profiles
  }
}

public struct MobileAgentLaunchOperation: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let deviceID: UUID
  public let projectID: UUID
  public let profileID: String
  public let worktreeID: UUID?

  public init(
    id: UUID = UUID(),
    deviceID: UUID,
    projectID: UUID,
    profileID: String,
    worktreeID: UUID? = nil
  ) {
    self.id = id
    self.deviceID = deviceID
    self.projectID = projectID
    self.profileID = profileID
    self.worktreeID = worktreeID
  }
}

public struct MobileAcceptedAgentLaunch: Codable, Equatable, Sendable {
  public let operationID: UUID
  public let projectID: UUID
  public let profileID: String
  public let worktreeID: UUID?

  public init(
    operationID: UUID,
    projectID: UUID,
    profileID: String,
    worktreeID: UUID?
  ) {
    self.operationID = operationID
    self.projectID = projectID
    self.profileID = profileID
    self.worktreeID = worktreeID
  }
}

public enum MobileAgentLaunchAuthorizer {
  public static func authorize(
    _ operation: MobileAgentLaunchOperation,
    registeredProfiles: Set<String>,
    grant: MobileDeviceGrant
  ) throws -> MobileAcceptedAgentLaunch {
    guard !grant.isRevoked else {
      throw MobileProtocolError.revokedDevice
    }
    guard grant.deviceID == operation.deviceID else {
      throw MobileProtocolError.invalidScope(.spawnSession)
    }
    guard grant.scopes.contains(.view), grant.scopes.contains(.spawnSession) else {
      throw MobileProtocolError.invalidScope(.spawnSession)
    }
    guard registeredProfiles.contains(operation.profileID) else {
      throw MobileProtocolError.invalidAgentProfile
    }
    if let allowedWorktreeIDs = grant.allowedWorktreeIDs {
      guard let worktreeID = operation.worktreeID,
        allowedWorktreeIDs.contains(worktreeID)
      else {
        throw MobileProtocolError.sessionNotVisible(operation.projectID)
      }
    }
    return MobileAcceptedAgentLaunch(
      operationID: operation.id,
      projectID: operation.projectID,
      profileID: operation.profileID,
      worktreeID: operation.worktreeID
    )
  }
}

public struct MobileAgentInputOperation: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let deviceID: UUID
  public let agentID: UUID
  public let payload: Data

  public init(
    id: UUID = UUID(),
    deviceID: UUID,
    agentID: UUID,
    payload: Data
  ) {
    self.id = id
    self.deviceID = deviceID
    self.agentID = agentID
    self.payload = payload
  }
}

public struct MobileAcceptedAgentInput: Codable, Equatable, Sendable {
  public let operationID: UUID
  public let agentID: UUID
  public let payload: Data

  public init(operationID: UUID, agentID: UUID, payload: Data) {
    self.operationID = operationID
    self.agentID = agentID
    self.payload = payload
  }
}

public enum MobileAgentInputAuthorizer {
  public static func authorize(
    _ operation: MobileAgentInputOperation,
    agent: MobileAgentDescriptor,
    grant: MobileDeviceGrant
  ) throws -> MobileAcceptedAgentInput {
    guard !grant.isRevoked else {
      throw MobileProtocolError.revokedDevice
    }
    guard grant.deviceID == operation.deviceID else {
      throw MobileProtocolError.invalidScope(.steerAgent)
    }
    guard operation.agentID == agent.id else {
      throw MobileProtocolError.sessionNotVisible(operation.agentID)
    }
    guard grant.canAccess(agent) else {
      throw MobileProtocolError.sessionNotVisible(agent.id)
    }
    guard grant.scopes.contains(.steerAgent) else {
      throw MobileProtocolError.invalidScope(.steerAgent)
    }
    guard agent.capabilities.contains(.agentControl),
      agent.capabilities.contains(.terminalInput)
    else {
      throw MobileProtocolError.invalidScope(.steerAgent)
    }
    guard !operation.payload.isEmpty else {
      throw MobileProtocolError.invalidOperationPayload
    }
    return MobileAcceptedAgentInput(
      operationID: operation.id,
      agentID: operation.agentID,
      payload: operation.payload
    )
  }
}

public enum MobileAgentControlAction: String, Codable, CaseIterable, Sendable {
  case interrupt
  case stop
}

public struct MobileAgentControlOperation: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let deviceID: UUID
  public let agentID: UUID
  public let action: MobileAgentControlAction

  public init(
    id: UUID = UUID(),
    deviceID: UUID,
    agentID: UUID,
    action: MobileAgentControlAction
  ) {
    self.id = id
    self.deviceID = deviceID
    self.agentID = agentID
    self.action = action
  }
}

public struct MobileAcceptedAgentControl: Codable, Equatable, Sendable {
  public let operationID: UUID
  public let agentID: UUID
  public let action: MobileAgentControlAction

  public init(operationID: UUID, agentID: UUID, action: MobileAgentControlAction) {
    self.operationID = operationID
    self.agentID = agentID
    self.action = action
  }
}

public struct MobileSessionDescriptor: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let projectID: UUID
  public let worktreeID: UUID?
  public let title: String
  public let cwd: String
  public let agentProfileID: String?
  public let lifecycle: MobileSessionLifecycle
  public let capabilities: Set<MobileCapability>

  public init(
    id: UUID,
    projectID: UUID,
    worktreeID: UUID? = nil,
    title: String,
    cwd: String,
    agentProfileID: String? = nil,
    lifecycle: MobileSessionLifecycle,
    capabilities: Set<MobileCapability>
  ) {
    self.id = id
    self.projectID = projectID
    self.worktreeID = worktreeID
    self.title = title
    self.cwd = cwd
    self.agentProfileID = agentProfileID
    self.lifecycle = lifecycle
    self.capabilities = capabilities
  }
}

public struct MobileDeviceGrant: Codable, Equatable, Sendable {
  public let deviceID: UUID
  public var scopes: Set<MobileControlScope>
  public var allowedWorktreeIDs: Set<UUID>?
  public var isRevoked: Bool

  public init(
    deviceID: UUID,
    scopes: Set<MobileControlScope> = [.view],
    allowedWorktreeIDs: Set<UUID>? = nil,
    isRevoked: Bool = false
  ) {
    self.deviceID = deviceID
    self.scopes = scopes
    self.allowedWorktreeIDs = allowedWorktreeIDs
    self.isRevoked = isRevoked
  }

  public func canAccess(_ session: MobileSessionDescriptor) -> Bool {
    guard !isRevoked, scopes.contains(.view) else {
      return false
    }
    guard let allowedWorktreeIDs else {
      return true
    }
    guard let worktreeID = session.worktreeID else {
      return false
    }
    return allowedWorktreeIDs.contains(worktreeID)
  }

  public func canAccess(_ agent: MobileAgentDescriptor) -> Bool {
    guard !isRevoked, scopes.contains(.view) else {
      return false
    }
    guard let allowedWorktreeIDs else {
      return true
    }
    guard let worktreeID = agent.worktreeID else {
      return false
    }
    return allowedWorktreeIDs.contains(worktreeID)
  }
}

public enum MobileAgentControlAuthorizer {
  public static func authorize(
    _ operation: MobileAgentControlOperation,
    agent: MobileAgentDescriptor,
    grant: MobileDeviceGrant
  ) throws -> MobileAcceptedAgentControl {
    guard !grant.isRevoked else {
      throw MobileProtocolError.revokedDevice
    }
    guard grant.deviceID == operation.deviceID else {
      throw MobileProtocolError.invalidScope(.steerAgent)
    }
    guard operation.agentID == agent.id else {
      throw MobileProtocolError.sessionNotVisible(operation.agentID)
    }
    guard grant.canAccess(agent) else {
      throw MobileProtocolError.sessionNotVisible(agent.id)
    }

    let requiredScope: MobileControlScope
    switch operation.action {
    case .interrupt:
      requiredScope = .signal
      guard agent.capabilities.contains(.terminalInterrupt) else {
        throw MobileProtocolError.invalidScope(.signal)
      }
    case .stop:
      requiredScope = .terminate
    }
    guard grant.scopes.contains(requiredScope) else {
      throw MobileProtocolError.invalidScope(requiredScope)
    }
    guard agent.capabilities.contains(.agentControl) else {
      throw MobileProtocolError.invalidScope(.steerAgent)
    }

    return MobileAcceptedAgentControl(
      operationID: operation.id,
      agentID: operation.agentID,
      action: operation.action
    )
  }
}

public struct MobileSessionCatalog: Sendable {
  public static let defaultMaximumSessionCount = 256

  private let sessions: [MobileSessionDescriptor]

  public init(
    sessions: [MobileSessionDescriptor],
    maximumSessionCount: Int = Self.defaultMaximumSessionCount
  ) {
    let limit = max(0, maximumSessionCount)
    self.sessions = Array(sessions.prefix(limit))
  }

  public func visibleSessions(for grant: MobileDeviceGrant) -> [MobileSessionDescriptor] {
    sessions.filter(grant.canAccess)
  }
}

public struct MobileTerminalInputOperation: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let deviceID: UUID
  public let sessionID: UUID
  public let payload: Data

  public init(
    id: UUID = UUID(),
    deviceID: UUID,
    sessionID: UUID,
    payload: Data
  ) {
    self.id = id
    self.deviceID = deviceID
    self.sessionID = sessionID
    self.payload = payload
  }
}

public struct MobileAcceptedInput: Codable, Equatable, Sendable {
  public let operationID: UUID
  public let deviceID: UUID
  public let sessionID: UUID
  public let arrivalSequence: UInt64
  public let isDuplicate: Bool
  public let payload: Data

  public init(
    operationID: UUID,
    deviceID: UUID,
    sessionID: UUID,
    arrivalSequence: UInt64,
    isDuplicate: Bool,
    payload: Data
  ) {
    self.operationID = operationID
    self.deviceID = deviceID
    self.sessionID = sessionID
    self.arrivalSequence = arrivalSequence
    self.isDuplicate = isDuplicate
    self.payload = payload
  }
}

/// Serializes writes at the broker boundary. Call `accept` from the broker's
/// serialized operation path; the returned sequence is the authoritative
/// order shared by desktop and mobile clients.
public struct MobileInputSequencer: Sendable {
  private struct RememberedOperation: Sendable {
    let deviceID: UUID
    let sessionID: UUID
    let payload: Data
    let acceptance: MobileAcceptedInput
  }

  public let maximumRememberedOperations: Int
  private var nextArrivalSequence: UInt64 = 0
  private var remembered: [UUID: RememberedOperation] = [:]
  private var rememberedOrder: [UUID] = []

  public init(maximumRememberedOperations: Int = 512) {
    self.maximumRememberedOperations = max(1, maximumRememberedOperations)
  }

  public mutating func accept(
    _ operation: MobileTerminalInputOperation,
    grant: MobileDeviceGrant,
    visibleSessionIDs: Set<UUID>,
    requiredScope: MobileControlScope = .writeTerminal
  ) throws -> MobileAcceptedInput {
    guard !grant.isRevoked else {
      throw MobileProtocolError.revokedDevice
    }
    guard grant.deviceID == operation.deviceID else {
      throw MobileProtocolError.invalidScope(requiredScope)
    }
    guard grant.scopes.contains(requiredScope) else {
      throw MobileProtocolError.invalidScope(requiredScope)
    }
    guard visibleSessionIDs.contains(operation.sessionID) else {
      throw MobileProtocolError.sessionNotVisible(operation.sessionID)
    }
    guard !operation.payload.isEmpty else {
      throw MobileProtocolError.invalidOperationPayload
    }

    if let previous = remembered[operation.id] {
      guard
        previous.deviceID == operation.deviceID,
        previous.sessionID == operation.sessionID,
        previous.payload == operation.payload
      else {
        throw MobileProtocolError.operationIDReuse(operation.id)
      }
      return MobileAcceptedInput(
        operationID: previous.acceptance.operationID,
        deviceID: previous.acceptance.deviceID,
        sessionID: previous.acceptance.sessionID,
        arrivalSequence: previous.acceptance.arrivalSequence,
        isDuplicate: true,
        payload: previous.acceptance.payload
      )
    }

    nextArrivalSequence = nextArrivalSequence == UInt64.max ? 1 : nextArrivalSequence + 1
    let acceptance = MobileAcceptedInput(
      operationID: operation.id,
      deviceID: operation.deviceID,
      sessionID: operation.sessionID,
      arrivalSequence: nextArrivalSequence,
      isDuplicate: false,
      payload: operation.payload
    )
    remembered[operation.id] = RememberedOperation(
      deviceID: operation.deviceID,
      sessionID: operation.sessionID,
      payload: operation.payload,
      acceptance: acceptance
    )
    rememberedOrder.append(operation.id)
    while rememberedOrder.count > maximumRememberedOperations {
      let evictedID = rememberedOrder.removeFirst()
      remembered[evictedID] = nil
    }
    return acceptance
  }
}

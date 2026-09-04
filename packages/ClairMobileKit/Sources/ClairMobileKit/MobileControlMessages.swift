import Foundation

public enum MobileJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([MobileJSONValue])
  case object([String: MobileJSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([MobileJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: MobileJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  public static func from<Value: Encodable>(_ value: Value) throws -> Self {
    let encoder = JSONEncoder()
    return try JSONDecoder().decode(Self.self, from: encoder.encode(value))
  }

  public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
    let data = try JSONEncoder().encode(self)
    return try JSONDecoder().decode(type, from: data)
  }
}

public struct MobileControlRequest: Codable, Equatable, Sendable {
  public let id: String
  public let method: MobileControlMethod
  public let params: MobileJSONValue

  public init(
    id: String = UUID().uuidString,
    method: MobileControlMethod,
    params: MobileJSONValue = .object([:])
  ) {
    self.id = id
    self.method = method
    self.params = params
  }

  public init<Parameters: Encodable>(
    id: String = UUID().uuidString,
    method: MobileControlMethod,
    parameters: Parameters
  ) throws {
    self.init(id: id, method: method, params: try .from(parameters))
  }

  public func decodeParameters<Parameters: Decodable>(
    _ type: Parameters.Type
  ) throws -> Parameters {
    try params.decode(type)
  }
}

public struct MobileControlRPCError: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct MobileControlResponse: Codable, Equatable, Sendable {
  public let id: String
  public let result: MobileJSONValue?
  public let error: MobileControlRPCError?

  public init(
    id: String,
    result: MobileJSONValue?,
    error: MobileControlRPCError?
  ) {
    self.id = id
    self.result = result
    self.error = error
  }

  public static func success<Value: Encodable>(
    id: String,
    value: Value
  ) throws -> Self {
    Self(id: id, result: try .from(value), error: nil)
  }

  public static func failure(
    id: String,
    code: String,
    message: String
  ) -> Self {
    Self(
      id: id,
      result: nil,
      error: MobileControlRPCError(code: code, message: message)
    )
  }
}

public struct MobileInitializeResult: Codable, Equatable, Sendable {
  public let hostIdentity: MobileHostIdentity
  public let negotiated: MobileNegotiatedSession
  public let isEnabled: Bool

  public init(
    hostIdentity: MobileHostIdentity,
    negotiated: MobileNegotiatedSession,
    isEnabled: Bool
  ) {
    self.hostIdentity = hostIdentity
    self.negotiated = negotiated
    self.isEnabled = isEnabled
  }
}

public struct MobilePairRequest: Codable, Equatable, Sendable {
  public let link: MobilePairingLink
  public let displayName: String
  public let devicePublicKey: Data
  public let confirmedFingerprint: String

  public init(
    link: MobilePairingLink,
    displayName: String,
    devicePublicKey: Data,
    confirmedFingerprint: String
  ) {
    self.link = link
    self.displayName = displayName
    self.devicePublicKey = devicePublicKey
    self.confirmedFingerprint = confirmedFingerprint
  }
}

public struct MobileChallengeRequest: Codable, Equatable, Sendable {
  public let deviceID: UUID

  public init(deviceID: UUID) {
    self.deviceID = deviceID
  }
}

public struct MobileAuthenticateRequest: Codable, Equatable, Sendable {
  public let deviceID: UUID
  public let token: String
  public let challenge: MobileAuthenticationChallenge
  public let signature: Data

  public init(
    deviceID: UUID,
    token: String,
    challenge: MobileAuthenticationChallenge,
    signature: Data
  ) {
    self.deviceID = deviceID
    self.token = token
    self.challenge = challenge
    self.signature = signature
  }
}

public struct MobileSessionSubscribeRequest: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let epoch: UInt64?
  public let cursor: UInt64
  public let maximumQueueBytes: Int

  public init(
    sessionID: UUID,
    epoch: UInt64? = nil,
    cursor: UInt64 = 0,
    maximumQueueBytes: Int = MobileControlHost.defaultSubscriberQueueBytes
  ) {
    self.sessionID = sessionID
    self.epoch = epoch
    self.cursor = cursor
    self.maximumQueueBytes = maximumQueueBytes
  }
}

public struct MobileTerminalInterruptRequest: Codable, Equatable, Sendable {
  public let operationID: UUID
  public let deviceID: UUID
  public let sessionID: UUID

  public init(
    operationID: UUID = UUID(),
    deviceID: UUID,
    sessionID: UUID
  ) {
    self.operationID = operationID
    self.deviceID = deviceID
    self.sessionID = sessionID
  }
}

public struct MobileSessionSubscribeResult: Equatable, Sendable {
  public let subscriptionID: UUID
  public let session: MobileSessionStreamSnapshot
  public let events: [MobileHostStreamEvent]

  public init(receipt: MobileSubscriptionReceipt) {
    subscriptionID = receipt.subscriptionID
    session = receipt.session
    events = receipt.events
  }
}

public struct MobileSessionListResult: Codable, Equatable, Sendable {
  public let sessions: [MobileSessionDescriptor]

  public init(sessions: [MobileSessionDescriptor]) {
    self.sessions = sessions
  }
}

public struct MobileAgentStatusRequest: Codable, Equatable, Sendable {
  public let agentID: UUID

  public init(agentID: UUID) {
    self.agentID = agentID
  }
}

public struct MobileDeviceIDRequest: Codable, Equatable, Sendable {
  public let deviceID: UUID

  public init(deviceID: UUID) {
    self.deviceID = deviceID
  }
}

public struct MobileSessionSubscribeMetadata: Codable, Equatable, Sendable {
  public let subscriptionID: UUID
  public let streamID: UInt32
  public let session: MobileSessionStreamSnapshot

  public init(receipt: MobileSubscriptionReceipt) {
    subscriptionID = receipt.subscriptionID
    streamID = receipt.streamID
    session = receipt.session
  }
}

public struct MobileStreamNotification: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case gap
    case exit
  }

  public let kind: Kind
  public let streamID: UInt32
  public let sessionEpoch: UInt64
  public let startOffset: UInt64?
  public let endOffset: UInt64?
  public let status: Int?

  public init(gap: MobileTerminalGap) {
    kind = .gap
    streamID = gap.streamID
    sessionEpoch = gap.sessionEpoch
    startOffset = gap.startOffset
    endOffset = gap.endOffset
    status = nil
  }

  public init(exit: MobileTerminalExit) {
    kind = .exit
    streamID = exit.streamID
    sessionEpoch = exit.sessionEpoch
    startOffset = nil
    endOffset = exit.offset
    status = exit.status
  }
}

public struct MobileUnsubscribeRequest: Codable, Equatable, Sendable {
  public let subscriptionID: UUID

  public init(subscriptionID: UUID) {
    self.subscriptionID = subscriptionID
  }
}

public struct MobileAgentOperationResult: Codable, Equatable, Sendable {
  public let operationID: UUID
  public let accepted: Bool

  public init(operationID: UUID, accepted: Bool = true) {
    self.operationID = operationID
    self.accepted = accepted
  }
}

public enum MobileControlMessageCodec {
  public static func encode<Value: Encodable>(_ value: Value) throws -> MobileTransportFrame {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try .control(encoder.encode(value))
  }

  public static func decode<Value: Decodable>(
    _ type: Value.Type,
    from frame: MobileTransportFrame
  ) throws -> Value {
    guard frame.kind == .control else {
      throw MobileTransportError.emptyControlFrame
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: frame.payload)
  }
}

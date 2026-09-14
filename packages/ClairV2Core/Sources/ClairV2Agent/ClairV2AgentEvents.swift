import ClairV2Shared
import CryptoKit
import Foundation

/// The provider-independent event families emitted by the H05 normalizer.
public enum ClairV2AgentNormalizedEventKind: String, Codable, CaseIterable, Sendable {
  case conversation
  case toolCall = "tool_call"
  case attention
  case completion
  case usage

  var wireKind: EventKind {
    try! EventKind("agent.\(rawValue)")
  }
}

public enum ClairV2AgentConversationRole: String, Codable, Equatable, Sendable {
  case user
  case assistant
  case system
  case tool
  case unknown
}

public struct ClairV2AgentConversationEvent: Codable, Equatable, Sendable {
  public let role: ClairV2AgentConversationRole
  public let text: String
  public let isDelta: Bool

  public init(
    role: ClairV2AgentConversationRole,
    text: String,
    isDelta: Bool = true
  ) {
    self.role = role
    self.text = text
    self.isDelta = isDelta
  }

  private enum CodingKeys: String, CodingKey {
    case role
    case text
    case isDelta = "is_delta"
  }
}

public enum ClairV2AgentToolCallStatus: String, Codable, Equatable, Sendable {
  case started
  case running
  case completed
  case failed
  case cancelled
  case unknown
}

public struct ClairV2AgentToolCallEvent: Codable, Equatable, Sendable {
  /// A stable digest of the provider call identity. Provider IDs are never
  /// copied into the normalized event model.
  public let toolID: String
  public let name: String
  public let status: ClairV2AgentToolCallStatus

  public init(
    toolID: String,
    name: String,
    status: ClairV2AgentToolCallStatus
  ) {
    self.toolID = toolID
    self.name = name
    self.status = status
  }

  private enum CodingKeys: String, CodingKey {
    case toolID = "tool_id"
    case name
    case status
  }
}

public enum ClairV2AgentAttentionKind: String, Codable, Equatable, Sendable {
  case approval
  case question
  case authentication
  case input
  case informational
}

public enum ClairV2AgentAttentionStatus: String, Codable, Equatable, Sendable {
  case pending
  case resolved
  case unknown
}

public struct ClairV2AgentAttentionEvent: Codable, Equatable, Sendable {
  /// A stable digest of the provider request identity.
  public let kind: ClairV2AgentAttentionKind
  public let requestID: String
  public let status: ClairV2AgentAttentionStatus

  public init(
    kind: ClairV2AgentAttentionKind,
    requestID: String,
    status: ClairV2AgentAttentionStatus = .unknown
  ) {
    self.kind = kind
    self.requestID = requestID
    self.status = status
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      kind: try container.decode(ClairV2AgentAttentionKind.self, forKey: .kind),
      requestID: try container.decode(String.self, forKey: .requestID),
      status: try container.decodeIfPresent(ClairV2AgentAttentionStatus.self, forKey: .status)
        ?? .unknown
    )
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case requestID = "request_id"
    case status
  }
}

public enum ClairV2AgentCompletionStatus: String, Codable, Equatable, Sendable {
  case succeeded
  case failed
  case cancelled
  case stopped
  case unknown
}

public struct ClairV2AgentCompletionEvent: Codable, Equatable, Sendable {
  public let status: ClairV2AgentCompletionStatus

  public init(status: ClairV2AgentCompletionStatus) {
    self.status = status
  }
}

public struct ClairV2AgentUsageEvent: Codable, Equatable, Sendable {
  public let inputTokens: UInt64
  public let outputTokens: UInt64
  public let totalTokens: UInt64
  public let cacheReadTokens: UInt64
  public let cacheWriteTokens: UInt64

  public init(
    inputTokens: UInt64,
    outputTokens: UInt64,
    totalTokens: UInt64,
    cacheReadTokens: UInt64 = 0,
    cacheWriteTokens: UInt64 = 0
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheWriteTokens = cacheWriteTokens
  }

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case totalTokens = "total_tokens"
    case cacheReadTokens = "cache_read_tokens"
    case cacheWriteTokens = "cache_write_tokens"
  }
}

/// Only allowlisted, provider-independent values cross the normalization
/// boundary. Unknown provider objects and raw event bytes are intentionally
/// not representable here.
public enum ClairV2AgentEventPayload: Codable, Equatable, Sendable {
  case conversation(ClairV2AgentConversationEvent)
  case toolCall(ClairV2AgentToolCallEvent)
  case attention(ClairV2AgentAttentionEvent)
  case completion(ClairV2AgentCompletionEvent)
  case usage(ClairV2AgentUsageEvent)

  public var kind: ClairV2AgentNormalizedEventKind {
    switch self {
    case .conversation:
      .conversation
    case .toolCall:
      .toolCall
    case .attention:
      .attention
    case .completion:
      .completion
    case .usage:
      .usage
    }
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case payload
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(ClairV2AgentNormalizedEventKind.self, forKey: .type)
    switch type {
    case .conversation:
      self = .conversation(
        try container.decode(ClairV2AgentConversationEvent.self, forKey: .payload)
      )
    case .toolCall:
      self = .toolCall(
        try container.decode(ClairV2AgentToolCallEvent.self, forKey: .payload)
      )
    case .attention:
      self = .attention(
        try container.decode(ClairV2AgentAttentionEvent.self, forKey: .payload)
      )
    case .completion:
      self = .completion(
        try container.decode(ClairV2AgentCompletionEvent.self, forKey: .payload)
      )
    case .usage:
      self = .usage(
        try container.decode(ClairV2AgentUsageEvent.self, forKey: .payload)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .type)
    switch self {
    case .conversation(let payload):
      try container.encode(payload, forKey: .payload)
    case .toolCall(let payload):
      try container.encode(payload, forKey: .payload)
    case .attention(let payload):
      try container.encode(payload, forKey: .payload)
    case .completion(let payload):
      try container.encode(payload, forKey: .payload)
    case .usage(let payload):
      try container.encode(payload, forKey: .payload)
    }
  }
}

public typealias ClairV2AgentNormalizedEvent = EventEnvelope<ClairV2AgentEventPayload>

public enum ClairV2AgentStreamError: Error, Equatable, LocalizedError, Sendable {
  case invalidLimits
  case inputTooLarge
  case eventLimitExceeded
  case invalidEventField
  case conflictingDuplicate
  case eventAfterCompletion
  case streamFinished
  case streamFailed
  case providerOutputTruncated

  public var errorDescription: String? {
    switch self {
    case .invalidLimits:
      "The agent event stream limits are invalid."
    case .inputTooLarge:
      "The agent event stream input exceeds its bounded retention limit."
    case .eventLimitExceeded:
      "The agent event stream exceeds its bounded event limit."
    case .invalidEventField:
      "The provider event contains an invalid normalized field."
    case .conflictingDuplicate:
      "The provider reused an event identity with different content."
    case .eventAfterCompletion:
      "The provider emitted an event after completion."
    case .streamFinished:
      "The agent event stream has already finished."
    case .streamFailed:
      "The agent event stream has failed closed."
    case .providerOutputTruncated:
      "The provider output was truncated before normalization."
    }
  }
}

public struct ClairV2AgentEventStreamLimits: Codable, Equatable, Sendable {
  public static let hardMaximumInputBytes = ClairV2AgentLaunchLimits.hardMaximumOutputBytes
  public static let hardMaximumEvents = 4_096
  public static let hardMaximumTextBytes = FrameLimits.hardMaximumPayloadBytes
  public static let hardMaximumIdentifierBytes = 256

  public let frameLimits: FrameLimits
  public let maximumInputBytes: Int
  public let maximumEvents: Int
  public let maximumTextBytes: Int
  public let maximumIdentifierBytes: Int

  public static let standard = try! Self(
    frameLimits: .standard,
    maximumInputBytes: ClairV2AgentLaunchLimits.standard.maximumOutputBytes,
    maximumEvents: 1_024,
    maximumTextBytes: 16 * 1024,
    maximumIdentifierBytes: 256
  )

  public init(
    frameLimits: FrameLimits = .standard,
    maximumInputBytes: Int = Self.standard.maximumInputBytes,
    maximumEvents: Int = Self.standard.maximumEvents,
    maximumTextBytes: Int = Self.standard.maximumTextBytes,
    maximumIdentifierBytes: Int = Self.standard.maximumIdentifierBytes
  ) throws {
    guard maximumInputBytes > 0,
      maximumInputBytes <= Self.hardMaximumInputBytes,
      maximumEvents > 0,
      maximumEvents <= Self.hardMaximumEvents,
      maximumTextBytes > 0,
      maximumTextBytes <= min(Self.hardMaximumTextBytes, frameLimits.maximumPayloadBytes),
      maximumIdentifierBytes > 0,
      maximumIdentifierBytes <= Self.hardMaximumIdentifierBytes
    else {
      throw ClairV2AgentStreamError.invalidLimits
    }
    self.frameLimits = frameLimits
    self.maximumInputBytes = maximumInputBytes
    self.maximumEvents = maximumEvents
    self.maximumTextBytes = maximumTextBytes
    self.maximumIdentifierBytes = maximumIdentifierBytes
  }

  private enum CodingKeys: String, CodingKey {
    case frameLimits = "frame_limits"
    case maximumInputBytes = "maximum_input_bytes"
    case maximumEvents = "maximum_events"
    case maximumTextBytes = "maximum_text_bytes"
    case maximumIdentifierBytes = "maximum_identifier_bytes"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      frameLimits: try container.decode(FrameLimits.self, forKey: .frameLimits),
      maximumInputBytes: try container.decode(Int.self, forKey: .maximumInputBytes),
      maximumEvents: try container.decode(Int.self, forKey: .maximumEvents),
      maximumTextBytes: try container.decode(Int.self, forKey: .maximumTextBytes),
      maximumIdentifierBytes: try container.decode(Int.self, forKey: .maximumIdentifierBytes)
    )
  }
}

/// Incrementally decodes OpenCode's newline/SSE JSON stream into the v2 event
/// envelope. It is deliberately independent from the process lifecycle actor:
/// H04 supplies bytes, while H06/H08 and clients decide what to do with the
/// normalized envelopes later.
public struct ClairV2OpenCodeStreamNormalizer: Sendable {
  public let identity: ClairV2AgentSessionIdentity
  public let epoch: SessionEpoch
  public let limits: ClairV2AgentEventStreamLimits

  public private(set) var revision: Revision
  public private(set) var unknownEventCount = 0

  private var buffer = Data()
  private var inputBytes = 0
  private var emittedEventCount = 0
  private var seenEvents: [String: Data] = [:]
  private var pendingSSEEventID: String?
  private var pendingCompletion: (eventID: EventID, payload: ClairV2AgentCompletionEvent)?
  private var usageWasEmitted = false
  private var completionWasEmitted = false
  private var finished = false
  private var failed = false

  public init(
    identity: ClairV2AgentSessionIdentity,
    epoch: SessionEpoch,
    startingRevision: Revision = .zero,
    limits: ClairV2AgentEventStreamLimits = .standard
  ) {
    self.identity = identity
    self.epoch = epoch
    self.revision = startingRevision
    self.limits = limits
  }

  public var hasPartialRecord: Bool {
    !buffer.isEmpty
  }

  public var hasPendingCompletion: Bool {
    pendingCompletion != nil
  }

  public static func normalize(
    stdout: Data,
    identity: ClairV2AgentSessionIdentity,
    epoch: SessionEpoch,
    startingRevision: Revision = .zero,
    limits: ClairV2AgentEventStreamLimits = .standard
  ) throws -> [ClairV2AgentNormalizedEvent] {
    var normalizer = Self(
      identity: identity,
      epoch: epoch,
      startingRevision: startingRevision,
      limits: limits
    )
    var events = try normalizer.append(stdout)
    events.append(contentsOf: try normalizer.finish())
    return events
  }

  /// Appends a raw stdout chunk. Chunks may split UTF-8 and JSON records.
  public mutating func append(_ data: Data) throws -> [ClairV2AgentNormalizedEvent] {
    try ensureOpen()
    do {
      return try appendChunk(data)
    } catch {
      failClosed()
      throw error
    }
  }

  /// H04 owns the combined stdout/stderr retention bound. Only stdout is
  /// eligible for provider event decoding; stderr is intentionally ignored.
  public mutating func append(
    rawOutput: ClairV2AgentRawOutput
  ) throws -> [ClairV2AgentNormalizedEvent] {
    try ensureOpen()
    guard !rawOutput.isTruncated else {
      failClosed()
      throw ClairV2AgentStreamError.providerOutputTruncated
    }
    return try append(rawOutput.stdout)
  }

  /// Completes the stream. A pending completion is emitted here when the
  /// provider did not send usage before its completion marker.
  public mutating func finish() throws -> [ClairV2AgentNormalizedEvent] {
    try ensureOpen()
    do {
      guard buffer.isEmpty else {
        throw ProtocolError.truncatedFrame
      }
      var events: [ClairV2AgentNormalizedEvent] = []
      if let pendingCompletion {
        events.append(
          try emit(
            eventID: pendingCompletion.eventID,
            payload: .completion(pendingCompletion.payload)
          )
        )
        self.pendingCompletion = nil
        completionWasEmitted = true
      }
      finished = true
      return events
    } catch {
      failClosed()
      throw error
    }
  }

  private mutating func ensureOpen() throws {
    if finished {
      throw ClairV2AgentStreamError.streamFinished
    }
    guard !failed else { throw ClairV2AgentStreamError.streamFailed }
  }

  private mutating func appendChunk(_ data: Data) throws -> [ClairV2AgentNormalizedEvent] {
    guard !data.isEmpty else { return [] }
    guard data.count <= limits.maximumInputBytes - inputBytes else {
      throw ClairV2AgentStreamError.inputTooLarge
    }
    inputBytes += data.count

    let maximumLineBytes = limits.frameLimits.maximumPayloadBytes + 8
    var partial = buffer
    buffer.removeAll(keepingCapacity: false)
    var events: [ClairV2AgentNormalizedEvent] = []
    var index = data.startIndex
    while index < data.endIndex {
      if let newline = data[index..<data.endIndex].firstIndex(of: 0x0A) {
        let fragment = data[index..<newline]
        try append(fragment, to: &partial, maximumBytes: maximumLineBytes)
        events.append(contentsOf: try consume(line: partial))
        partial.removeAll(keepingCapacity: false)
        index = data.index(after: newline)
      } else {
        try append(data[index..<data.endIndex], to: &partial, maximumBytes: maximumLineBytes)
        index = data.endIndex
      }
    }
    buffer = partial
    return events
  }

  private func append(
    _ fragment: Data.SubSequence,
    to value: inout Data,
    maximumBytes: Int
  ) throws {
    guard fragment.count <= maximumBytes - value.count else {
      throw ProtocolError.frameTooLarge(value.count + fragment.count)
    }
    value.append(fragment)
  }

  private mutating func failClosed() {
    failed = true
    buffer.removeAll(keepingCapacity: false)
    pendingSSEEventID = nil
    pendingCompletion = nil
  }

  private mutating func consume(line originalLine: Data) throws -> [ClairV2AgentNormalizedEvent] {
    var line = originalLine
    if line.last == 0x0D {
      line.removeLast()
    }
    guard !line.isEmpty else { return [] }
    guard line.count <= limits.frameLimits.maximumPayloadBytes + 8 else {
      throw ProtocolError.frameTooLarge(line.count)
    }

    if line.starts(with: Data("event:".utf8)) || line.starts(with: Data("retry:".utf8)) {
      return []
    }
    if line.starts(with: Data("id:".utf8)) {
      let value = line.dropFirst(3)
      guard let string = String(data: value, encoding: .utf8) else {
        throw ProtocolError.malformedPayload
      }
      let trimmed = string.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty,
        trimmed.utf8.count <= limits.maximumIdentifierBytes,
        !trimmed.contains("\0")
      else {
        throw ClairV2AgentStreamError.invalidEventField
      }
      pendingSSEEventID = digestHex(Data(trimmed.utf8))
      return []
    }

    var payload = line
    if line.starts(with: Data("data:".utf8)) {
      payload = Data(line.dropFirst(5))
      while payload.first == 0x20 || payload.first == 0x09 {
        payload.removeFirst()
      }
    }
    guard !payload.isEmpty else { return [] }
    guard payload.count <= limits.frameLimits.maximumPayloadBytes else {
      throw ProtocolError.frameTooLarge(payload.count)
    }

    if payload == Data("[DONE]".utf8) {
      let sseID = pendingSSEEventID ?? "done"
      let eventID = try makeEventID(key: "sse:\(sseID)", suffix: "completion")
      pendingSSEEventID = nil
      return try accept(
        providerKey: "sse:\(sseID)",
        fingerprint: digestData(payload),
        semantics: [.completion(ClairV2AgentCompletionEvent(status: .succeeded))],
        eventIDs: [eventID]
      )
    }

    guard String(data: payload, encoding: .utf8) != nil else {
      throw ProtocolError.malformedPayload
    }
    let raw: H05RawEvent
    do {
      raw = try JSONDecoder().decode(H05RawEvent.self, from: payload)
    } catch {
      throw ProtocolError.malformedPayload
    }
    let canonical: Data
    do {
      canonical = try ProtocolCodec.encode(raw.fields)
    } catch {
      throw ProtocolError.malformedPayload
    }
    let explicitID = try raw.string(
      paths: [
        ["event_id"],
        ["eventId"],
        ["eventID"],
        ["sequence"],
        ["seq"],
        ["id"],
      ],
      maximumBytes: limits.maximumIdentifierBytes
    )
    let sseEventID = pendingSSEEventID
    pendingSSEEventID = nil
    let providerKey: String
    if let explicitID {
      providerKey = "provider-id:\(digestHex(Data(explicitID.utf8)))"
    } else if let sseEventID {
      providerKey = "provider-id:\(sseEventID)"
    } else {
      providerKey = "record:\(digestHex(canonical))"
    }

    let semantics = try raw.semantics(limits: limits)
    guard !semantics.isEmpty else {
      unknownEventCount += 1
      return []
    }
    let eventIDs = try semantics.enumerated().map { index, semantic in
      try makeEventID(key: providerKey, suffix: "\(index):\(semantic.kind.rawValue)")
    }
    return try accept(
      providerKey: providerKey,
      fingerprint: digestData(canonical),
      semantics: semantics,
      eventIDs: eventIDs
    )
  }

  private mutating func accept(
    providerKey: String,
    fingerprint: Data,
    semantics: [H05Semantic],
    eventIDs: [EventID]
  ) throws -> [ClairV2AgentNormalizedEvent] {
    if let existing = seenEvents[providerKey] {
      guard existing == fingerprint else {
        throw ClairV2AgentStreamError.conflictingDuplicate
      }
      return []
    }
    seenEvents[providerKey] = fingerprint

    // Input order is authoritative for every non-terminal semantic. The only
    // permitted relocation is moving a completion marker after usage when a
    // single provider record carries both in the reverse order.
    var orderedSemantics = Array(semantics.enumerated())
    while let completionIndex = orderedSemantics.firstIndex(
      where: { $0.element.kind == .completion }
    ) {
      guard
        orderedSemantics.indices.dropFirst(completionIndex + 1).contains(where: {
          orderedSemantics[$0].element.kind == .usage
        })
      else {
        break
      }
      let completion = orderedSemantics.remove(at: completionIndex)
      guard
        let lastUsageIndex = orderedSemantics.indices.last(where: {
          orderedSemantics[$0].element.kind == .usage
        })
      else {
        break
      }
      orderedSemantics.insert(completion, at: lastUsageIndex + 1)
    }

    var events: [ClairV2AgentNormalizedEvent] = []
    for (originalIndex, semantic) in orderedSemantics {
      let eventID = eventIDs[originalIndex]
      switch semantic {
      case .usage(let payload):
        guard !completionWasEmitted else {
          throw ClairV2AgentStreamError.eventAfterCompletion
        }
        events.append(try emit(eventID: eventID, payload: .usage(payload)))
        usageWasEmitted = true
        if let pendingCompletion {
          events.append(
            try emit(
              eventID: pendingCompletion.eventID,
              payload: .completion(pendingCompletion.payload)
            )
          )
          self.pendingCompletion = nil
          completionWasEmitted = true
        }
      case .completion(let payload):
        guard !completionWasEmitted else {
          throw ClairV2AgentStreamError.eventAfterCompletion
        }
        guard pendingCompletion == nil else {
          throw ClairV2AgentStreamError.eventAfterCompletion
        }
        if usageWasEmitted {
          events.append(try emit(eventID: eventID, payload: .completion(payload)))
          completionWasEmitted = true
        } else {
          pendingCompletion = (eventID: eventID, payload: payload)
        }
      case .conversation(let payload):
        guard pendingCompletion == nil, !completionWasEmitted else {
          throw ClairV2AgentStreamError.eventAfterCompletion
        }
        events.append(try emit(eventID: eventID, payload: .conversation(payload)))
      case .toolCall(let payload):
        guard pendingCompletion == nil, !completionWasEmitted else {
          throw ClairV2AgentStreamError.eventAfterCompletion
        }
        events.append(try emit(eventID: eventID, payload: .toolCall(payload)))
      case .attention(let payload):
        guard pendingCompletion == nil, !completionWasEmitted else {
          throw ClairV2AgentStreamError.eventAfterCompletion
        }
        events.append(try emit(eventID: eventID, payload: .attention(payload)))
      }
    }
    return events
  }

  private mutating func emit(
    eventID: EventID,
    payload: ClairV2AgentEventPayload
  ) throws -> ClairV2AgentNormalizedEvent {
    guard emittedEventCount < limits.maximumEvents else {
      throw ClairV2AgentStreamError.eventLimitExceeded
    }
    let nextRevision = try revision.next()
    let event = try EventEnvelope(
      eventID: eventID,
      kind: payload.kind.wireKind,
      scope: identity.sessionScope,
      epoch: epoch,
      revision: nextRevision,
      payload: payload
    )
    revision = nextRevision
    emittedEventCount += 1
    return event
  }

  private func makeEventID(key: String, suffix: String) throws -> EventID {
    try EventID("agent-\(digestHex(Data("\(key):\(suffix)".utf8)))")
  }

  private func digestData(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  private func digestHex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private enum H05Semantic: Sendable, Equatable {
  case conversation(ClairV2AgentConversationEvent)
  case toolCall(ClairV2AgentToolCallEvent)
  case attention(ClairV2AgentAttentionEvent)
  case completion(ClairV2AgentCompletionEvent)
  case usage(ClairV2AgentUsageEvent)

  var kind: ClairV2AgentNormalizedEventKind {
    switch self {
    case .conversation:
      .conversation
    case .toolCall:
      .toolCall
    case .attention:
      .attention
    case .completion:
      .completion
    case .usage:
      .usage
    }
  }
}

private indirect enum H05JSONValue: Codable, Equatable, Sendable {
  case object([String: H05JSONValue])
  case array([H05JSONValue])
  case string(String)
  case integer(Int64)
  case double(Double)
  case boolean(Bool)
  case null

  init(from decoder: Decoder) throws {
    if let object = try? decoder.singleValueContainer().decode([String: H05JSONValue].self) {
      self = .object(object)
      return
    }
    if let array = try? decoder.singleValueContainer().decode([H05JSONValue].self) {
      self = .array(array)
      return
    }
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      throw ProtocolError.malformedPayload
    }
  }

  func encode(to encoder: Encoder) throws {
    switch self {
    case .object(let object):
      var container = encoder.container(keyedBy: H05CodingKey.self)
      for (key, value) in object {
        try container.encode(value, forKey: H05CodingKey(key))
      }
    case .array(let array):
      var container = encoder.unkeyedContainer()
      for value in array {
        try container.encode(value)
      }
    case .string(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .integer(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .double(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .boolean(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .null:
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    }
  }
}

private struct H05CodingKey: CodingKey, Hashable {
  let stringValue: String
  let intValue: Int?

  init(_ stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}

private struct H05RawEvent: Decodable, Sendable {
  let fields: [String: H05JSONValue]

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    fields = try container.decode([String: H05JSONValue].self)
  }

  func value(paths: [[String]]) -> H05JSONValue? {
    for path in paths {
      var current: H05JSONValue = .object(fields)
      var found = true
      for component in path {
        guard case .object(let object) = current, let next = object[component] else {
          found = false
          break
        }
        current = next
      }
      if found { return current }
    }
    return nil
  }

  func string(
    paths: [[String]],
    maximumBytes: Int
  ) throws -> String? {
    guard let value = value(paths: paths) else { return nil }
    guard case .string(let string) = value else {
      throw ClairV2AgentStreamError.invalidEventField
    }
    guard string.utf8.count <= maximumBytes, !string.contains("\0") else {
      throw ClairV2AgentStreamError.invalidEventField
    }
    return string
  }

  func semantics(limits: ClairV2AgentEventStreamLimits) throws -> [H05Semantic] {
    let type = try string(
      paths: [
        ["type"],
        ["event"],
        ["payload", "type"],
        ["properties", "type"],
        ["properties", "event"],
        ["data", "type"],
      ],
      maximumBytes: limits.maximumIdentifierBytes
    )?.lowercased()
    let partType = try string(
      paths: [
        ["part", "type"],
        ["payload", "part", "type"],
        ["properties", "part", "type"],
      ],
      maximumBytes: limits.maximumIdentifierBytes
    )?.lowercased()
    let canonicalType = type ?? partType ?? ""
    guard !canonicalType.isEmpty else { return [] }

    var semantics: [H05Semantic] = []
    if isAttention(canonicalType) {
      semantics.append(.attention(try attentionEvent(type: canonicalType, limits: limits)))
    } else if isToolCall(canonicalType, partType: partType) {
      semantics.append(.toolCall(try toolCallEvent(limits: limits)))
    } else if isConversation(canonicalType, partType: partType) {
      semantics.append(.conversation(try conversationEvent(type: canonicalType, limits: limits)))
    }

    if let usage = try usageEvent(type: canonicalType, limits: limits) {
      semantics.append(.usage(usage))
    }

    if isCompletion(canonicalType) {
      semantics.append(.completion(try completionEvent(type: canonicalType, limits: limits)))
    }
    return semantics
  }

  private func isAttention(_ type: String) -> Bool {
    switch type {
    case "permission.asked", "permission.updated", "permission.replied",
      "approval.asked", "approval.updated", "approval.replied",
      "question.asked", "question.updated", "question.replied",
      "attention.asked", "attention.updated", "attention.required",
      "input_required", "auth_required":
      true
    default:
      false
    }
  }

  private func isToolCall(_ type: String, partType: String?) -> Bool {
    switch type {
    case "tool", "tool_call", "tool_use",
      "tool.started", "tool.running", "tool.completed", "tool.failed", "tool.cancelled",
      "tool_call.started", "tool_call.running", "tool_call.completed", "tool_call.failed",
      "command", "command.started", "command.running", "command.completed", "command.failed":
      true
    case "message.part.updated":
      partType == "tool" || partType == "tool_call"
    default:
      false
    }
  }

  private func isConversation(_ type: String, partType: String?) -> Bool {
    switch type {
    case "text", "text.delta", "message.text.delta":
      true
    case "message.part.updated":
      partType == "text" || partType == "reasoning"
    case "message.updated":
      value(paths: [["text"], ["content"], ["message", "text"]]) != nil
    default:
      false
    }
  }

  private func isCompletion(_ type: String) -> Bool {
    if type == "session.status" {
      let status = stringValue(
        paths: [
          ["status", "type"],
          ["properties", "status", "type"],
          ["status"],
          ["properties", "status"],
        ]
      )?.lowercased()
      return status == "idle"
        || status == "completed"
        || status == "complete"
        || status == "done"
        || status == "failed"
        || status == "error"
    }
    switch type {
    case "[done]", "done", "complete", "completed", "finish", "finished",
      "step_finish", "step-finish", "step.finish", "session.idle",
      "session.completed", "message.completed", "error":
      return true
    default:
      return false
    }
  }

  private func conversationEvent(
    type: String,
    limits: ClairV2AgentEventStreamLimits
  ) throws -> ClairV2AgentConversationEvent {
    let delta = try string(
      paths: [
        ["delta"],
        ["properties", "delta"],
        ["payload", "delta"],
      ],
      maximumBytes: limits.maximumTextBytes
    )
    let text: String?
    if let delta {
      text = delta
    } else {
      text = try string(
        paths: [
          ["text"],
          ["content"],
          ["part", "text"],
          ["payload", "text"],
          ["payload", "part", "text"],
          ["properties", "part", "text"],
          ["message", "text"],
        ],
        maximumBytes: limits.maximumTextBytes
      )
    }
    guard let text, !text.isEmpty else {
      throw ClairV2AgentStreamError.invalidEventField
    }
    let roleValue = try string(
      paths: [
        ["role"],
        ["part", "role"],
        ["message", "role"],
        ["properties", "part", "role"],
      ],
      maximumBytes: limits.maximumIdentifierBytes
    )?.lowercased()
    let role = ClairV2AgentConversationRole(rawValue: roleValue ?? "assistant") ?? .unknown
    return ClairV2AgentConversationEvent(
      role: role,
      text: text,
      isDelta: delta != nil || type == "text.delta" || type == "message.text.delta"
    )
  }

  private func toolCallEvent(
    limits: ClairV2AgentEventStreamLimits
  ) throws -> ClairV2AgentToolCallEvent {
    let name = try string(
      paths: [
        ["tool_name"],
        ["name"],
        ["part", "tool"],
        ["part", "name"],
        ["properties", "part", "tool"],
        ["properties", "part", "name"],
        ["tool"],
      ],
      maximumBytes: limits.maximumIdentifierBytes
    )
    guard let name, !name.isEmpty else {
      throw ClairV2AgentStreamError.invalidEventField
    }
    let rawToolID =
      try string(
        paths: [
          ["tool_call_id"],
          ["toolCallId"],
          ["call_id"],
          ["callId"],
          ["part", "callID"],
          ["part", "id"],
          ["id"],
        ],
        maximumBytes: limits.maximumIdentifierBytes
      ) ?? name
    return ClairV2AgentToolCallEvent(
      toolID: digestIdentifier(rawToolID),
      name: name,
      status: try toolStatus(limits: limits)
    )
  }

  private func toolStatus(
    limits: ClairV2AgentEventStreamLimits
  ) throws -> ClairV2AgentToolCallStatus {
    let value = try string(
      paths: [
        ["state", "status"],
        ["part", "state", "status"],
        ["properties", "part", "state", "status"],
        ["status"],
        ["state"],
        ["part", "state"],
        ["properties", "part", "state"],
      ],
      maximumBytes: limits.maximumIdentifierBytes
    )?.lowercased()
    guard let value else { return .unknown }
    switch value {
    case "start", "started", "pending":
      return .started
    case "running", "in_progress", "in-progress":
      return .running
    case "completed", "complete", "success", "succeeded", "done":
      return .completed
    case "failed", "error":
      return .failed
    case "cancelled", "canceled", "interrupted":
      return .cancelled
    default:
      return .unknown
    }
  }

  private func attentionEvent(
    type: String,
    limits: ClairV2AgentEventStreamLimits
  ) throws -> ClairV2AgentAttentionEvent {
    let kind: ClairV2AgentAttentionKind
    if [
      "permission.asked", "permission.updated", "permission.replied",
      "approval.asked", "approval.updated", "approval.replied",
    ].contains(type) {
      kind = .approval
    } else if ["question.asked", "question.updated", "question.replied"].contains(type) {
      kind = .question
    } else if type == "auth_required" {
      kind = .authentication
    } else if type == "input_required" {
      kind = .input
    } else {
      kind = .informational
    }
    let rawRequestID = try string(
      paths: [
        ["request_id"],
        ["requestId"],
        ["permission_id"],
        ["permissionId"],
        ["question_id"],
        ["questionId"],
        ["permission", "id"],
        ["properties", "permission", "id"],
        ["question", "id"],
        ["properties", "question", "id"],
        ["id"],
      ],
      maximumBytes: limits.maximumIdentifierBytes
    )
    if kind == .approval, rawRequestID?.isEmpty != false {
      // Never create an executable approval for an event that cannot be tied
      // to a provider request. A response without an ID is retained as a
      // resolved, uncorrelated event so H06 can invalidate pending approvals.
      guard type.hasSuffix(".replied") else {
        throw ClairV2AgentStreamError.invalidEventField
      }
    }
    return ClairV2AgentAttentionEvent(
      kind: kind,
      requestID: digestIdentifier(rawRequestID ?? type),
      status: type.hasSuffix(".replied") ? .resolved : .pending
    )
  }

  private func completionEvent(
    type: String,
    limits: ClairV2AgentEventStreamLimits
  ) throws -> ClairV2AgentCompletionEvent {
    let status = try string(
      paths: [
        ["status", "type"],
        ["properties", "status", "type"],
        ["properties", "status"],
        ["status"],
        ["state"],
        ["reason"],
        ["finish_reason"],
        ["finishReason"],
      ],
      maximumBytes: limits.maximumIdentifierBytes
    )?.lowercased()
    if type == "error" || status == "error" || status == "failed" || status == "failure" {
      return ClairV2AgentCompletionEvent(status: .failed)
    }
    if status == "cancelled" || status == "canceled" || status == "interrupt" {
      return ClairV2AgentCompletionEvent(status: .cancelled)
    }
    if status == "stopped" || status == "stop" {
      return ClairV2AgentCompletionEvent(status: .stopped)
    }
    if status == "success" || status == "succeeded" || status == "completed"
      || status == "complete" || status == "idle" || status == "done"
      || type == "done" || type == "complete" || type == "session.idle"
    {
      return ClairV2AgentCompletionEvent(status: .succeeded)
    }
    return ClairV2AgentCompletionEvent(status: .unknown)
  }

  private func usageEvent(
    type: String,
    limits: ClairV2AgentEventStreamLimits
  ) throws -> ClairV2AgentUsageEvent? {
    let usagePaths = [
      ["usage"],
      ["tokens"],
      ["part", "tokens"],
      ["part", "usage"],
      ["properties", "usage"],
      ["properties", "part", "tokens"],
      ["properties", "part", "usage"],
      ["payload", "usage"],
      ["payload", "part", "tokens"],
      ["info", "usage"],
    ]
    let hasUsageType: Bool
    switch type {
    case "usage", "token_usage", "tokens", "message.usage", "session.usage", "response.usage":
      hasUsageType = true
    default:
      hasUsageType = false
    }
    let hasUsageCarrierFields = type == "message.part.updated" || type == "message.updated"
    let hasUsageFields =
      hasUsageCarrierFields
      && (value(paths: usagePaths) != nil
        || value(paths: [["input_tokens"], ["inputTokens"], ["prompt_tokens"]]) != nil
        || value(paths: [["output_tokens"], ["outputTokens"], ["completion_tokens"]]) != nil)
    guard hasUsageType || hasUsageFields else { return nil }

    func number(_ names: [[String]]) throws -> UInt64? {
      let paths = usagePaths.flatMap { usagePath in names.map { usagePath + $0 } } + names
      guard let value = value(paths: paths) else { return nil }
      return try unsignedInteger(value, maximumBytes: limits.maximumTextBytes)
    }

    let inputTokenValue =
      try number([["input_tokens"], ["inputTokens"], ["prompt_tokens"], ["input"]])
    let outputTokenValue =
      try number([["output_tokens"], ["outputTokens"], ["completion_tokens"], ["output"]])
    let totalTokenValue = try number([["total_tokens"], ["totalTokens"], ["total"]])
    let cacheReadTokenValue =
      try number([
        ["cache_read_tokens"],
        ["cacheReadTokens"],
        ["cache_read"],
        ["cache", "read"],
      ])
    let cacheWriteTokenValue =
      try number([
        ["cache_write_tokens"],
        ["cacheWriteTokens"],
        ["cache_write"],
        ["cache", "write"],
      ])
    guard
      inputTokenValue != nil || outputTokenValue != nil || totalTokenValue != nil
        || cacheReadTokenValue != nil || cacheWriteTokenValue != nil
    else {
      throw ClairV2AgentStreamError.invalidEventField
    }
    let inputTokens = inputTokenValue ?? 0
    let outputTokens = outputTokenValue ?? 0
    let totalTokens = totalTokenValue
    let cacheReadTokens = cacheReadTokenValue ?? 0
    let cacheWriteTokens = cacheWriteTokenValue ?? 0
    let calculatedTotal = inputTokens.addingReportingOverflow(outputTokens)
    guard !calculatedTotal.overflow else {
      throw ClairV2AgentStreamError.invalidEventField
    }
    let resolvedTotal = totalTokens ?? calculatedTotal.partialValue
    guard resolvedTotal >= calculatedTotal.partialValue else {
      throw ClairV2AgentStreamError.invalidEventField
    }
    return ClairV2AgentUsageEvent(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      totalTokens: resolvedTotal,
      cacheReadTokens: cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens
    )
  }

  private func stringValue(paths: [[String]]) -> String? {
    guard let value = value(paths: paths), case .string(let string) = value else {
      return nil
    }
    return string
  }

  private func unsignedInteger(
    _ value: H05JSONValue,
    maximumBytes: Int
  ) throws -> UInt64 {
    switch value {
    case .integer(let value):
      guard value >= 0 else { throw ClairV2AgentStreamError.invalidEventField }
      return UInt64(value)
    case .double(let value):
      let upperBound = 18_446_744_073_709_551_616.0
      guard value.isFinite, value >= 0, value.rounded() == value,
        value < upperBound
      else {
        throw ClairV2AgentStreamError.invalidEventField
      }
      return UInt64(value)
    case .string(let value):
      guard value.utf8.count <= maximumBytes, let result = UInt64(value), !value.isEmpty else {
        throw ClairV2AgentStreamError.invalidEventField
      }
      return result
    default:
      throw ClairV2AgentStreamError.invalidEventField
    }
  }

  private func digestIdentifier(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

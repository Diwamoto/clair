import CryptoKit
import Foundation

private func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
  let index = data.index(data.startIndex, offsetBy: offset)
  return UInt32(data[index]) << 24
    | UInt32(data[data.index(index, offsetBy: 1)]) << 16
    | UInt32(data[data.index(index, offsetBy: 2)]) << 8
    | UInt32(data[data.index(index, offsetBy: 3)])
}

private func readBigEndianUInt32(_ data: Data, startingAt index: Data.Index) -> UInt32 {
  return UInt32(data[index]) << 24
    | UInt32(data[data.index(index, offsetBy: 1)]) << 16
    | UInt32(data[data.index(index, offsetBy: 2)]) << 8
    | UInt32(data[data.index(index, offsetBy: 3)])
}

/// Errors raised while validating a protocol value or applying a protocol invariant.
public enum ProtocolError: Error, Equatable, LocalizedError, Sendable {
  case invalidIdentifier(IdentityKind)
  case invalidScope
  case invalidRevision
  case invalidEpoch
  case invalidVersion
  case unsupportedMajor(expected: UInt16, actual: UInt16)
  case noCompatibleVersion
  case invalidFrameLength(Int)
  case frameTooLarge(Int)
  case truncatedFrame
  case trailingFrameBytes(Int)
  case malformedPayload
  case invalidEnvelope
  case revisionOverflow
  case epochMismatch(expected: SessionEpoch, actual: SessionEpoch)
  case replayGap(expected: Revision, actual: Revision)
  case replayRegression(previous: Revision, actual: Revision)
  case invalidReplayWindow
  case eventIDReuse(EventID)
  case operationIDReuse(OperationID)
  case operationSequenceOverflow
  case invalidOperationCapacity
  case capabilityDenied(Capability)
  case capabilityMismatch(expected: Capability, actual: Capability)
  case unknownOperationKind(OperationKind)
  case scopeDenied

  public var errorDescription: String? {
    switch self {
    case .invalidIdentifier(let kind):
      "The \(kind.rawValue) identifier is empty, too long, or contains control characters."
    case .invalidScope:
      "The protocol scope is not a valid project, worktree, or session scope."
    case .invalidRevision:
      "The protocol revision is invalid."
    case .invalidEpoch:
      "The session epoch must be greater than zero."
    case .invalidVersion:
      "The protocol version or version range is invalid."
    case .unsupportedMajor(let expected, let actual):
      "Protocol major \(actual) is not supported; expected major \(expected)."
    case .noCompatibleVersion:
      "The protocol version ranges do not overlap."
    case .invalidFrameLength(let length):
      "The protocol frame length is invalid: \(length) bytes."
    case .frameTooLarge(let length):
      "The protocol frame is too large: \(length) bytes."
    case .truncatedFrame:
      "The protocol frame is truncated."
    case .trailingFrameBytes(let length):
      "The protocol frame has \(length) trailing bytes."
    case .malformedPayload:
      "The protocol payload is malformed."
    case .invalidEnvelope:
      "The protocol envelope violates its field invariants."
    case .revisionOverflow:
      "The protocol revision cannot be advanced beyond its maximum value."
    case .epochMismatch(let expected, let actual):
      "The session epoch \(actual) does not match the expected epoch \(expected)."
    case .replayGap(let expected, let actual):
      "Replay expected revision \(expected) but received revision \(actual)."
    case .replayRegression(let previous, let actual):
      "Replay regressed from revision \(previous) to revision \(actual)."
    case .invalidReplayWindow:
      "The replay history window is outside the supported bounds."
    case .eventIDReuse:
      "An event ID was reused with a different event."
    case .operationIDReuse:
      "An operation ID was reused with a different operation."
    case .operationSequenceOverflow:
      "The operation arrival sequence cannot be advanced."
    case .invalidOperationCapacity:
      "The operation idempotency window is outside the supported bounds."
    case .capabilityDenied(let capability):
      "The required capability is not granted: \(capability.rawValue)."
    case .capabilityMismatch(let expected, let actual):
      "The operation declared capability \(actual.rawValue), but requires \(expected.rawValue)."
    case .unknownOperationKind(let kind):
      "The operation kind is not supported: \(kind.rawValue)."
    case .scopeDenied:
      "The requested resource is outside the authorized scope."
    }
  }
}

public enum IdentityKind: String, Codable, CaseIterable, Sendable {
  case project
  case worktree
  case session
  case operation
  case event
}

private enum IdentifierValidation {
  static let maximumUTF8Length = 256

  static func validate(_ rawValue: String, kind: IdentityKind) throws {
    guard !rawValue.isEmpty,
      rawValue.utf8.count <= maximumUTF8Length,
      rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.unicodeScalars.contains(where: { scalar in
        scalar.value < 0x20 || scalar.value == 0x7f
      })
    else {
      throw ProtocolError.invalidIdentifier(kind)
    }
  }

  static func validateWireName(_ rawValue: String) throws {
    guard !rawValue.isEmpty,
      rawValue.utf8.count <= maximumUTF8Length,
      rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.unicodeScalars.contains(where: { scalar in
        scalar.value < 0x20 || scalar.value == 0x7f
      })
    else {
      throw ProtocolError.invalidEnvelope
    }
  }
}

public struct ProjectID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try IdentifierValidation.validate(rawValue, kind: .project)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct WorktreeID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try IdentifierValidation.validate(rawValue, kind: .worktree)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct SessionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try IdentifierValidation.validate(rawValue, kind: .session)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct OperationID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try IdentifierValidation.validate(rawValue, kind: .operation)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct EventID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try IdentifierValidation.validate(rawValue, kind: .event)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct Revision: Codable, Equatable, Hashable, Comparable, Sendable, CustomStringConvertible
{
  public let value: UInt64

  public init(_ value: UInt64) {
    self.value = value
  }

  public static let zero = Self(0)

  public func next() throws -> Self {
    guard value < UInt64.max else { throw ProtocolError.revisionOverflow }
    return Self(value + 1)
  }

  public var description: String { String(value) }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.value < rhs.value
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(UInt64.self)
    self.init(value)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public struct SessionEpoch: Codable, Equatable, Hashable, Comparable, Sendable,
  CustomStringConvertible
{
  public let value: UInt64

  public init(_ value: UInt64) throws {
    guard value > 0 else { throw ProtocolError.invalidEpoch }
    self.value = value
  }

  public var description: String { String(value) }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.value < rhs.value
  }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(UInt64.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

/// A hierarchical target. A project scope contains all of its worktrees;
/// a worktree scope contains its sessions; a session scope is exact, including
/// whether it is project-owned or attached to a particular worktree.
public struct ResourceScope: Codable, Equatable, Hashable, Sendable {
  public let projectID: ProjectID
  public let worktreeID: WorktreeID?
  public let sessionID: SessionID?

  public init(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    sessionID: SessionID? = nil
  ) throws {
    // A session may be project-owned without a managed worktree. The
    // identity remains explicit and cannot be confused with another ID type.
    self.projectID = projectID
    self.worktreeID = worktreeID
    self.sessionID = sessionID
  }

  public var isProjectScope: Bool { worktreeID == nil && sessionID == nil }
  public var isWorktreeScope: Bool { worktreeID != nil && sessionID == nil }
  public var isSessionScope: Bool { sessionID != nil }

  public func contains(_ child: ResourceScope) -> Bool {
    guard projectID == child.projectID else { return false }
    if let sessionID {
      return worktreeID == child.worktreeID && sessionID == child.sessionID
    }
    if let worktreeID {
      return worktreeID == child.worktreeID
    }
    return true
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case worktreeID = "worktree_id"
    case sessionID = "session_id"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      projectID: container.decode(ProjectID.self, forKey: .projectID),
      worktreeID: container.decodeIfPresent(WorktreeID.self, forKey: .worktreeID),
      sessionID: container.decodeIfPresent(SessionID.self, forKey: .sessionID)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(projectID, forKey: .projectID)
    try container.encodeIfPresent(worktreeID, forKey: .worktreeID)
    try container.encodeIfPresent(sessionID, forKey: .sessionID)
  }
}

public struct SessionPosition: Codable, Equatable, Hashable, Sendable {
  public let epoch: SessionEpoch
  public let revision: Revision

  public init(epoch: SessionEpoch, revision: Revision) {
    self.epoch = epoch
    self.revision = revision
  }
}

/// Capabilities are open-ended wire names. Unknown values survive decoding so
/// a newer peer can advertise a capability without breaking an older peer.
public struct Capability: RawRepresentable, Codable, Hashable, Comparable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try IdentifierValidation.validateWireName(rawValue)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  public static let view = Self(unchecked: "view")
  public static let writeTerminal = Self(unchecked: "write_terminal")
  public static let steerAgent = Self(unchecked: "steer_agent")
  public static let approve = Self(unchecked: "approve")
  public static let signal = Self(unchecked: "signal")
  public static let terminate = Self(unchecked: "terminate")
  public static let spawnSession = Self(unchecked: "spawn_session")
  public static let manageDevices = Self(unchecked: "manage_devices")
  public static let rawTerminal = Self(unchecked: "raw_terminal")
  public static let terminalInput = Self(unchecked: "terminal_input")
  public static let terminalInterrupt = Self(unchecked: "terminal_interrupt")
  public static let agentCatalog = Self(unchecked: "agent_catalog")
  public static let agentStatus = Self(unchecked: "agent_status")
  public static let agentControl = Self(unchecked: "agent_control")
  public static let agentLaunch = Self(unchecked: "agent_launch")
  public static let attentionNotifications = Self(unchecked: "attention_notifications")

  public static let allKnown: [Self] = [
    .view,
    .writeTerminal,
    .steerAgent,
    .approve,
    .signal,
    .terminate,
    .spawnSession,
    .manageDevices,
    .rawTerminal,
    .terminalInput,
    .terminalInterrupt,
    .agentCatalog,
    .agentStatus,
    .agentControl,
    .agentLaunch,
    .attentionNotifications,
  ]

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct CapabilitySet: Codable, Equatable, Hashable, Sendable, Sequence {
  public let values: [Capability]

  public init<S: Sequence>(_ capabilities: S) throws where S.Element == Capability {
    let unique = Set(capabilities)
    guard unique.count <= 128 else { throw ProtocolError.invalidEnvelope }
    self.values = unique.sorted()
  }

  private init(unchecked values: [Capability]) {
    self.values = values
  }

  public static let empty = Self(unchecked: [])
  public static let allKnown = Self(unchecked: Capability.allKnown.sorted())

  public func contains(_ capability: Capability) -> Bool {
    values.contains(capability)
  }

  public func intersection(_ other: Self) -> Self {
    let otherValues = Set(other.values)
    return Self(unchecked: values.filter { otherValues.contains($0) })
  }

  public func makeIterator() -> IndexingIterator<[Capability]> {
    values.makeIterator()
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.singleValueContainer().decode([Capability].self)
    try self.init(values)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(values)
  }
}

public struct ProtocolVersion: Codable, Equatable, Hashable, Comparable, Sendable {
  public let major: UInt16
  public let minor: UInt16

  public init(major: UInt16, minor: UInt16) throws {
    guard major > 0 else { throw ProtocolError.invalidVersion }
    self.major = major
    self.minor = minor
  }

  public static let current = try! Self(major: 1, minor: 0)

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.major == rhs.major ? lhs.minor < rhs.minor : lhs.major < rhs.major
  }

  private enum CodingKeys: String, CodingKey {
    case major
    case minor
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      major: container.decode(UInt16.self, forKey: .major),
      minor: container.decode(UInt16.self, forKey: .minor)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(major, forKey: .major)
    try container.encode(minor, forKey: .minor)
  }
}

public struct ProtocolVersionRange: Codable, Equatable, Hashable, Sendable {
  public let major: UInt16
  public let minimumMinor: UInt16
  public let maximumMinor: UInt16

  public init(
    major: UInt16,
    minimumMinor: UInt16,
    maximumMinor: UInt16
  ) throws {
    guard major > 0, minimumMinor <= maximumMinor else {
      throw ProtocolError.invalidVersion
    }
    self.major = major
    self.minimumMinor = minimumMinor
    self.maximumMinor = maximumMinor
  }

  public init(major: UInt16, minor: UInt16) throws {
    try self.init(major: major, minimumMinor: minor, maximumMinor: minor)
  }

  public func intersects(_ other: Self) -> Bool {
    guard major == other.major else { return false }
    return max(minimumMinor, other.minimumMinor) <= min(maximumMinor, other.maximumMinor)
  }

  public func negotiatedMinor(with other: Self) throws -> UInt16 {
    guard intersects(other) else { throw ProtocolError.noCompatibleVersion }
    return min(maximumMinor, other.maximumMinor)
  }

  private enum CodingKeys: String, CodingKey {
    case major
    case minimumMinor = "minimum_minor"
    case maximumMinor = "maximum_minor"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      major: container.decode(UInt16.self, forKey: .major),
      minimumMinor: container.decode(UInt16.self, forKey: .minimumMinor),
      maximumMinor: container.decode(UInt16.self, forKey: .maximumMinor)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(major, forKey: .major)
    try container.encode(minimumMinor, forKey: .minimumMinor)
    try container.encode(maximumMinor, forKey: .maximumMinor)
  }
}

public struct FrameLimits: Codable, Equatable, Sendable {
  public static let defaultMaximumPayloadBytes = 64 * 1024
  public static let hardMaximumPayloadBytes = 16 * 1024 * 1024

  public let maximumPayloadBytes: Int

  public init(maximumPayloadBytes: Int = Self.defaultMaximumPayloadBytes) throws {
    guard maximumPayloadBytes > 0,
      maximumPayloadBytes <= Self.hardMaximumPayloadBytes
    else {
      throw ProtocolError.invalidFrameLength(maximumPayloadBytes)
    }
    self.maximumPayloadBytes = maximumPayloadBytes
  }

  private init(unchecked maximumPayloadBytes: Int) {
    self.maximumPayloadBytes = maximumPayloadBytes
  }

  public static let standard = Self(unchecked: Self.defaultMaximumPayloadBytes)
  public var maximumFrameBytes: Int { maximumPayloadBytes + BoundedFrame.lengthPrefixBytes }

  public func validatePayloadLength(_ length: Int) throws {
    guard length > 0 else { throw ProtocolError.invalidFrameLength(length) }
    guard length <= maximumPayloadBytes else { throw ProtocolError.frameTooLarge(length) }
  }

  private enum CodingKeys: String, CodingKey {
    case maximumPayloadBytes = "maximum_payload_bytes"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumPayloadBytes: container.decode(Int.self, forKey: .maximumPayloadBytes)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(maximumPayloadBytes, forKey: .maximumPayloadBytes)
  }
}

public struct ProtocolOffer: Codable, Equatable, Sendable {
  public let versionRanges: [ProtocolVersionRange]
  public let maximumFramePayloadBytes: Int
  public let capabilities: CapabilitySet

  public init(
    versionRanges: [ProtocolVersionRange],
    maximumFramePayloadBytes: Int = FrameLimits.defaultMaximumPayloadBytes,
    capabilities: CapabilitySet = .empty
  ) throws {
    guard !versionRanges.isEmpty else { throw ProtocolError.invalidVersion }
    let majors = versionRanges.map(\.major)
    guard Set(majors).count == majors.count else { throw ProtocolError.invalidVersion }
    _ = try FrameLimits(maximumPayloadBytes: maximumFramePayloadBytes)
    self.versionRanges = versionRanges.sorted { $0.major < $1.major }
    self.maximumFramePayloadBytes = maximumFramePayloadBytes
    self.capabilities = capabilities
  }

  public static let current: Self = {
    try! Self(
      versionRanges: [try! ProtocolVersionRange(major: 1, minor: 0)],
      maximumFramePayloadBytes: FrameLimits.defaultMaximumPayloadBytes,
      capabilities: .allKnown
    )
  }()

  private enum CodingKeys: String, CodingKey {
    case versionRanges = "version_ranges"
    case maximumFramePayloadBytes = "maximum_frame_payload_bytes"
    case capabilities
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      versionRanges: container.decode([ProtocolVersionRange].self, forKey: .versionRanges),
      maximumFramePayloadBytes: container.decode(Int.self, forKey: .maximumFramePayloadBytes),
      capabilities: container.decode(CapabilitySet.self, forKey: .capabilities)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(versionRanges, forKey: .versionRanges)
    try container.encode(maximumFramePayloadBytes, forKey: .maximumFramePayloadBytes)
    try container.encode(capabilities, forKey: .capabilities)
  }
}

public struct NegotiatedProtocol: Codable, Equatable, Sendable {
  public let version: ProtocolVersion
  public let maximumFramePayloadBytes: Int
  public let capabilities: CapabilitySet

  public init(
    version: ProtocolVersion,
    maximumFramePayloadBytes: Int,
    capabilities: CapabilitySet
  ) throws {
    _ = try FrameLimits(maximumPayloadBytes: maximumFramePayloadBytes)
    self.version = version
    self.maximumFramePayloadBytes = maximumFramePayloadBytes
    self.capabilities = capabilities
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case maximumFramePayloadBytes = "maximum_frame_payload_bytes"
    case capabilities
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      version: container.decode(ProtocolVersion.self, forKey: .version),
      maximumFramePayloadBytes: container.decode(Int.self, forKey: .maximumFramePayloadBytes),
      capabilities: container.decode(CapabilitySet.self, forKey: .capabilities)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(maximumFramePayloadBytes, forKey: .maximumFramePayloadBytes)
    try container.encode(capabilities, forKey: .capabilities)
  }
}

public enum ProtocolNegotiator {
  public static func negotiate(
    client: ProtocolOffer,
    server: ProtocolOffer
  ) throws -> NegotiatedProtocol {
    let clientMajors = Set(client.versionRanges.map(\.major))
    let serverMajors = Set(server.versionRanges.map(\.major))
    let sharedMajors = clientMajors.intersection(serverMajors)

    guard !sharedMajors.isEmpty else {
      throw ProtocolError.unsupportedMajor(
        expected: server.versionRanges.map(\.major).max() ?? 0,
        actual: client.versionRanges.map(\.major).max() ?? 0
      )
    }

    let candidates: [(ProtocolVersionRange, ProtocolVersionRange)] =
      sharedMajors
      .sorted(by: >)
      .compactMap { major -> (ProtocolVersionRange, ProtocolVersionRange)? in
        guard
          let clientRange = client.versionRanges.first(where: { $0.major == major }),
          let serverRange = server.versionRanges.first(where: { $0.major == major }),
          clientRange.intersects(serverRange)
        else {
          return nil
        }
        return (clientRange, serverRange)
      }
    guard let selected = candidates.first else {
      throw ProtocolError.noCompatibleVersion
    }

    let version = try ProtocolVersion(
      major: selected.0.major,
      minor: selected.0.negotiatedMinor(with: selected.1)
    )
    let maximumFramePayloadBytes = min(
      client.maximumFramePayloadBytes,
      server.maximumFramePayloadBytes
    )
    return try NegotiatedProtocol(
      version: version,
      maximumFramePayloadBytes: maximumFramePayloadBytes,
      capabilities: client.capabilities.intersection(server.capabilities)
    )
  }
}

public struct BoundedFrame: Equatable, Sendable {
  public static let lengthPrefixBytes = 4

  public let payload: Data

  public init(
    payload: Data,
    limits: FrameLimits = .standard
  ) throws {
    try limits.validatePayloadLength(payload.count)
    self.payload = payload
  }

  public var encoded: Data {
    var data = Data()
    Self.appendUInt32(UInt32(payload.count), to: &data)
    data.append(payload)
    return data
  }

  public static func decode(
    _ data: Data,
    limits: FrameLimits = .standard
  ) throws -> Self {
    guard data.count >= lengthPrefixBytes else { throw ProtocolError.truncatedFrame }
    let payloadLength = Int(readBigEndianUInt32(data, at: 0))
    try limits.validatePayloadLength(payloadLength)
    let expectedLength = lengthPrefixBytes + payloadLength
    guard data.count >= expectedLength else { throw ProtocolError.truncatedFrame }
    guard data.count == expectedLength else {
      throw ProtocolError.trailingFrameBytes(data.count - expectedLength)
    }
    let payloadStart = data.index(data.startIndex, offsetBy: lengthPrefixBytes)
    let payloadEnd = data.index(payloadStart, offsetBy: payloadLength)
    return try Self(payload: Data(data[payloadStart..<payloadEnd]), limits: limits)
  }

  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }
}

public struct BoundedFrameDecoder: Sendable {
  private var buffer = Data()
  private let limits: FrameLimits

  public init(limits: FrameLimits = .standard) {
    self.limits = limits
  }

  public var hasPartialFrame: Bool { !buffer.isEmpty }

  public mutating func append(_ data: Data) throws -> [BoundedFrame] {
    guard !data.isEmpty else { return [] }
    var frames: [BoundedFrame] = []
    var inputIndex = data.startIndex

    while inputIndex < data.endIndex {
      if buffer.isEmpty {
        let inputBytes = data.distance(from: inputIndex, to: data.endIndex)
        guard inputBytes >= BoundedFrame.lengthPrefixBytes else {
          buffer.append(data[inputIndex..<data.endIndex])
          break
        }

        let payloadLength = Int(readBigEndianUInt32(data, startingAt: inputIndex))
        try limits.validatePayloadLength(payloadLength)
        let totalLength = BoundedFrame.lengthPrefixBytes + payloadLength
        if inputBytes >= totalLength {
          let payloadStart = data.index(inputIndex, offsetBy: BoundedFrame.lengthPrefixBytes)
          let payloadEnd = data.index(inputIndex, offsetBy: totalLength)
          frames.append(
            try BoundedFrame(
              payload: Data(data[payloadStart..<payloadEnd]),
              limits: limits
            )
          )
          inputIndex = payloadEnd
          continue
        }

        buffer.append(data[inputIndex..<data.endIndex])
        break
      }

      if buffer.count < BoundedFrame.lengthPrefixBytes {
        let headerBytesNeeded = BoundedFrame.lengthPrefixBytes - buffer.count
        let inputBytes = data.distance(from: inputIndex, to: data.endIndex)
        let bytesToAppend = min(headerBytesNeeded, inputBytes)
        let nextIndex = data.index(inputIndex, offsetBy: bytesToAppend)
        buffer.append(data[inputIndex..<nextIndex])
        inputIndex = nextIndex
        if buffer.count < BoundedFrame.lengthPrefixBytes {
          break
        }
      }

      let payloadLength = Int(readBigEndianUInt32(buffer, at: 0))
      try limits.validatePayloadLength(payloadLength)
      let totalLength = BoundedFrame.lengthPrefixBytes + payloadLength
      let bytesNeeded = totalLength - buffer.count
      let inputBytes = data.distance(from: inputIndex, to: data.endIndex)
      let bytesToAppend = min(bytesNeeded, inputBytes)
      if bytesToAppend > 0 {
        let nextIndex = data.index(inputIndex, offsetBy: bytesToAppend)
        buffer.append(data[inputIndex..<nextIndex])
        inputIndex = nextIndex
      }

      guard buffer.count >= totalLength else { break }
      frames.append(try BoundedFrame.decode(buffer, limits: limits))
      buffer = Data()
    }
    return frames
  }

  public mutating func finish() throws {
    guard buffer.isEmpty else { throw ProtocolError.truncatedFrame }
  }
}

public enum ProtocolCodec {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      return try encoder.encode(value)
    } catch let error as ProtocolError {
      throw error
    } catch {
      throw ProtocolError.malformedPayload
    }
  }

  public static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    limits: FrameLimits = .standard
  ) throws -> T {
    try limits.validatePayloadLength(data.count)
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch let error as ProtocolError {
      throw error
    } catch {
      throw ProtocolError.malformedPayload
    }
  }

  public static func encodeFrame<T: Encodable>(
    _ value: T,
    limits: FrameLimits = .standard
  ) throws -> Data {
    try BoundedFrame(payload: encode(value), limits: limits).encoded
  }

  public static func decodeFrame<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    limits: FrameLimits = .standard
  ) throws -> T {
    try decode(
      type,
      from: BoundedFrame.decode(data, limits: limits).payload,
      limits: limits
    )
  }
}

public struct EventKind: RawRepresentable, Codable, Hashable, Comparable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try IdentifierValidation.validateWireName(rawValue)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  public static let sessionSnapshot = Self(unchecked: "session.snapshot")
  public static let sessionOutput = Self(unchecked: "session.output")
  public static let sessionState = Self(unchecked: "session.state")
  public static let attention = Self(unchecked: "attention")
  public static let operationResult = Self(unchecked: "operation.result")

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct OperationKind: RawRepresentable, Codable, Hashable, Comparable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try IdentifierValidation.validateWireName(rawValue)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  public static let terminalInput = Self(unchecked: "terminal.input")
  public static let terminalInterrupt = Self(unchecked: "terminal.interrupt")
  public static let agentInput = Self(unchecked: "agent.input")
  public static let agentApprove = Self(unchecked: "agent.approve")
  public static let agentDeny = Self(unchecked: "agent.deny")
  public static let agentInterrupt = Self(unchecked: "agent.interrupt")
  public static let agentStop = Self(unchecked: "agent.stop")
  public static let reviewApply = Self(unchecked: "review.apply")

  /// The server-side capability required for each known mutating operation.
  /// Unknown operation kinds intentionally have no implicit capability.
  public var requiredCapability: Capability? {
    switch rawValue {
    case Self.terminalInput.rawValue:
      .writeTerminal
    case Self.terminalInterrupt.rawValue:
      .signal
    case Self.agentInput.rawValue:
      .steerAgent
    case Self.agentApprove.rawValue, Self.agentDeny.rawValue:
      .approve
    case Self.agentInterrupt.rawValue:
      .signal
    case Self.agentStop.rawValue:
      .terminate
    case Self.reviewApply.rawValue:
      .approve
    default:
      nil
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct OperationRequest<Payload: Codable & Sendable>: Codable, Sendable {
  public let operationID: OperationID
  public let scope: ResourceScope
  public let kind: OperationKind
  public let baseRevision: Revision?
  public let capability: Capability
  public let payload: Payload

  public init(
    operationID: OperationID,
    scope: ResourceScope,
    kind: OperationKind,
    baseRevision: Revision? = nil,
    capability: Capability,
    payload: Payload
  ) {
    self.operationID = operationID
    self.scope = scope
    self.kind = kind
    self.baseRevision = baseRevision
    self.capability = capability
    self.payload = payload
  }

  private enum CodingKeys: String, CodingKey {
    case operationID = "operation_id"
    case scope
    case kind
    case baseRevision = "base_revision"
    case capability
    case payload
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.operationID = try container.decode(OperationID.self, forKey: .operationID)
    self.scope = try container.decode(ResourceScope.self, forKey: .scope)
    self.kind = try container.decode(OperationKind.self, forKey: .kind)
    self.baseRevision = try container.decodeIfPresent(Revision.self, forKey: .baseRevision)
    self.capability = try container.decode(Capability.self, forKey: .capability)
    self.payload = try container.decode(Payload.self, forKey: .payload)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(operationID, forKey: .operationID)
    try container.encode(scope, forKey: .scope)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(baseRevision, forKey: .baseRevision)
    try container.encode(capability, forKey: .capability)
    try container.encode(payload, forKey: .payload)
  }
}

extension OperationRequest: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "OperationRequest(<redacted>)" }

  public var debugDescription: String { description }
}

public enum OperationDisposition: String, Codable, Sendable {
  case accepted
  case duplicate
}

public struct OperationReceipt: Codable, Equatable, Sendable {
  public let operationID: OperationID
  public let arrivalSequence: UInt64
  public let disposition: OperationDisposition

  public init(
    operationID: OperationID,
    arrivalSequence: UInt64,
    disposition: OperationDisposition
  ) {
    self.operationID = operationID
    self.arrivalSequence = arrivalSequence
    self.disposition = disposition
  }

  private enum CodingKeys: String, CodingKey {
    case operationID = "operation_id"
    case arrivalSequence = "arrival_sequence"
    case disposition
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      operationID: try container.decode(OperationID.self, forKey: .operationID),
      arrivalSequence: try container.decode(UInt64.self, forKey: .arrivalSequence),
      disposition: try container.decode(OperationDisposition.self, forKey: .disposition)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(operationID, forKey: .operationID)
    try container.encode(arrivalSequence, forKey: .arrivalSequence)
    try container.encode(disposition, forKey: .disposition)
  }
}

/// A bounded, single-boundary idempotency window. The first arrival of an
/// operation receives the sequence number; retries return that same number.
public struct OperationLedger: Sendable {
  public static let defaultCapacity = 256
  public static let maximumCapacity = 4_096

  public let capacity: Int
  private var nextArrivalSequence: UInt64 = 1
  private var fingerprints: [OperationID: Data] = [:]
  private var sequences: [OperationID: UInt64] = [:]
  private var order: [OperationID] = []

  public init(capacity: Int = Self.defaultCapacity) throws {
    guard capacity > 0, capacity <= Self.maximumCapacity else {
      throw ProtocolError.invalidOperationCapacity
    }
    self.capacity = capacity
  }

  public mutating func register<Payload: Codable & Sendable>(
    _ operation: OperationRequest<Payload>
  ) throws -> OperationReceipt {
    let canonical = try ProtocolCodec.encode(
      OperationFingerprint(
        scope: operation.scope,
        kind: operation.kind,
        baseRevision: operation.baseRevision,
        capability: operation.capability,
        payload: operation.payload
      )
    )

    // Keep only a digest: canonical command bodies can contain private prompts.
    let fingerprint = Data(SHA256.hash(data: canonical))
    if let existing = fingerprints[operation.operationID] {
      guard existing == fingerprint, let sequence = sequences[operation.operationID] else {
        throw ProtocolError.operationIDReuse(operation.operationID)
      }
      return OperationReceipt(
        operationID: operation.operationID,
        arrivalSequence: sequence,
        disposition: .duplicate
      )
    }

    guard nextArrivalSequence < UInt64.max else {
      throw ProtocolError.operationSequenceOverflow
    }
    let sequence = nextArrivalSequence
    nextArrivalSequence += 1
    fingerprints[operation.operationID] = fingerprint
    sequences[operation.operationID] = sequence
    order.append(operation.operationID)

    if order.count > capacity {
      let evicted = order.removeFirst()
      fingerprints.removeValue(forKey: evicted)
      sequences.removeValue(forKey: evicted)
    }

    return OperationReceipt(
      operationID: operation.operationID,
      arrivalSequence: sequence,
      disposition: .accepted
    )
  }

  private struct OperationFingerprint<Payload: Encodable>: Encodable {
    let scope: ResourceScope
    let kind: OperationKind
    let baseRevision: Revision?
    let capability: Capability
    let payload: Payload

    private enum CodingKeys: String, CodingKey {
      case scope
      case kind
      case baseRevision = "base_revision"
      case capability
      case payload
    }
  }
}

/// The authorization boundary is deliberately separate from transport. An
/// empty visible-scope list denies everything, and scope containment is based
/// on typed IDs rather than path or branch strings.
public struct AccessBoundary: Codable, Equatable, Hashable, Sendable {
  public let capabilities: CapabilitySet
  public let visibleScopes: [ResourceScope]

  public init(
    capabilities: CapabilitySet,
    visibleScopes: [ResourceScope]
  ) throws {
    guard visibleScopes.count <= 256 else { throw ProtocolError.invalidEnvelope }
    self.capabilities = capabilities
    self.visibleScopes = visibleScopes
  }

  public func authorize(
    scope: ResourceScope,
    requiring capability: Capability
  ) throws {
    guard capabilities.contains(capability) else {
      throw ProtocolError.capabilityDenied(capability)
    }
    guard visibleScopes.contains(where: { $0.contains(scope) }) else {
      throw ProtocolError.scopeDenied
    }
  }

  public func authorize<Payload: Codable & Sendable>(
    _ operation: OperationRequest<Payload>
  ) throws {
    guard let requiredCapability = operation.kind.requiredCapability else {
      throw ProtocolError.unknownOperationKind(operation.kind)
    }
    guard operation.capability == requiredCapability else {
      throw ProtocolError.capabilityMismatch(
        expected: requiredCapability,
        actual: operation.capability
      )
    }
    try authorize(scope: operation.scope, requiring: requiredCapability)
  }
}

public struct EventEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
  public let eventID: EventID
  public let kind: EventKind
  public let scope: ResourceScope
  public let epoch: SessionEpoch?
  public let revision: Revision?
  public let operationID: OperationID?
  public let payload: Payload

  public init(
    eventID: EventID,
    kind: EventKind,
    scope: ResourceScope,
    epoch: SessionEpoch? = nil,
    revision: Revision? = nil,
    operationID: OperationID? = nil,
    payload: Payload
  ) throws {
    let hasPosition = epoch != nil || revision != nil
    guard scope.sessionID != nil ? (epoch != nil && revision != nil) : !hasPosition else {
      throw ProtocolError.invalidEnvelope
    }
    self.eventID = eventID
    self.kind = kind
    self.scope = scope
    self.epoch = epoch
    self.revision = revision
    self.operationID = operationID
    self.payload = payload
  }

  public var position: SessionPosition? {
    guard let epoch, let revision else { return nil }
    return SessionPosition(epoch: epoch, revision: revision)
  }

  private enum CodingKeys: String, CodingKey {
    case eventID = "event_id"
    case kind = "type"
    case scope
    case epoch
    case revision
    case operationID = "operation_id"
    case payload
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      eventID: container.decode(EventID.self, forKey: .eventID),
      kind: container.decode(EventKind.self, forKey: .kind),
      scope: container.decode(ResourceScope.self, forKey: .scope),
      epoch: container.decodeIfPresent(SessionEpoch.self, forKey: .epoch),
      revision: container.decodeIfPresent(Revision.self, forKey: .revision),
      operationID: container.decodeIfPresent(OperationID.self, forKey: .operationID),
      payload: container.decode(Payload.self, forKey: .payload)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(eventID, forKey: .eventID)
    try container.encode(kind, forKey: .kind)
    try container.encode(scope, forKey: .scope)
    try container.encodeIfPresent(epoch, forKey: .epoch)
    try container.encodeIfPresent(revision, forKey: .revision)
    try container.encodeIfPresent(operationID, forKey: .operationID)
    try container.encode(payload, forKey: .payload)
  }
}

extension EventEnvelope: Equatable where Payload: Equatable {}

public struct ReplayCursor: Codable, Equatable, Hashable, Sendable {
  public let scope: ResourceScope
  public let epoch: SessionEpoch
  public let revision: Revision

  public init(
    scope: ResourceScope,
    epoch: SessionEpoch,
    revision: Revision = .zero
  ) throws {
    guard scope.sessionID != nil else { throw ProtocolError.invalidScope }
    self.scope = scope
    self.epoch = epoch
    self.revision = revision
  }

  public func nextRevision() throws -> Revision {
    try revision.next()
  }

  private enum CodingKeys: String, CodingKey {
    case scope
    case epoch
    case revision
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      scope: container.decode(ResourceScope.self, forKey: .scope),
      epoch: container.decode(SessionEpoch.self, forKey: .epoch),
      revision: container.decode(Revision.self, forKey: .revision)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(scope, forKey: .scope)
    try container.encode(epoch, forKey: .epoch)
    try container.encode(revision, forKey: .revision)
  }
}

public enum ReplayDisposition: String, Codable, Sendable {
  case applied
  case duplicate
}

/// Applies an in-order session stream. A gap, regression, epoch change, or
/// conflicting reuse is surfaced as a typed failure; no event is silently
/// skipped or applied out of order.
public struct ReplayState: Sendable {
  public static let defaultEventHistory = 256
  public static let maximumEventHistory = 4_096

  public private(set) var cursor: ReplayCursor
  private let maximumEventHistory: Int
  private var fingerprints: [EventID: Data] = [:]
  private var order: [EventID] = []

  public init(
    cursor: ReplayCursor,
    maximumEventHistory: Int = Self.defaultEventHistory
  ) throws {
    guard maximumEventHistory > 0, maximumEventHistory <= Self.maximumEventHistory else {
      throw ProtocolError.invalidReplayWindow
    }
    self.cursor = cursor
    self.maximumEventHistory = maximumEventHistory
  }

  public mutating func apply<Payload: Codable & Sendable>(
    _ event: EventEnvelope<Payload>
  ) throws -> ReplayDisposition {
    guard event.scope == cursor.scope else { throw ProtocolError.scopeDenied }
    guard let eventEpoch = event.epoch, let eventRevision = event.revision else {
      throw ProtocolError.invalidEnvelope
    }

    let fingerprint = try ProtocolCodec.encode(event)
    if let existing = fingerprints[event.eventID] {
      guard existing == fingerprint else { throw ProtocolError.eventIDReuse(event.eventID) }
      return .duplicate
    }

    guard eventEpoch == cursor.epoch else {
      throw ProtocolError.epochMismatch(expected: cursor.epoch, actual: eventEpoch)
    }
    let expectedRevision = try cursor.nextRevision()
    if eventRevision < expectedRevision {
      throw ProtocolError.replayRegression(previous: cursor.revision, actual: eventRevision)
    }
    guard eventRevision == expectedRevision else {
      throw ProtocolError.replayGap(expected: expectedRevision, actual: eventRevision)
    }

    cursor = try ReplayCursor(
      scope: cursor.scope,
      epoch: eventEpoch,
      revision: eventRevision
    )
    fingerprints[event.eventID] = fingerprint
    order.append(event.eventID)
    if order.count > maximumEventHistory {
      let evicted = order.removeFirst()
      fingerprints.removeValue(forKey: evicted)
    }
    return .applied
  }
}

public struct ProtocolErrorCode: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    try IdentifierValidation.validateWireName(rawValue)
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }

  public static let invalidIdentifier = Self(unchecked: "invalid_identifier")
  public static let invalidScope = Self(unchecked: "invalid_scope")
  public static let invalidRevision = Self(unchecked: "invalid_revision")
  public static let invalidEpoch = Self(unchecked: "invalid_epoch")
  public static let invalidVersion = Self(unchecked: "invalid_version")
  public static let unsupportedMajor = Self(unchecked: "unsupported_major")
  public static let noCompatibleVersion = Self(unchecked: "no_compatible_version")
  public static let invalidFrameLength = Self(unchecked: "invalid_frame_length")
  public static let frameTooLarge = Self(unchecked: "frame_too_large")
  public static let truncatedFrame = Self(unchecked: "truncated_frame")
  public static let trailingFrameBytes = Self(unchecked: "trailing_frame_bytes")
  public static let malformedPayload = Self(unchecked: "malformed_payload")
  public static let invalidEnvelope = Self(unchecked: "invalid_envelope")
  public static let revisionOverflow = Self(unchecked: "revision_overflow")
  public static let epochMismatch = Self(unchecked: "epoch_mismatch")
  public static let replayGap = Self(unchecked: "replay_gap")
  public static let replayRegression = Self(unchecked: "replay_regression")
  public static let invalidReplayWindow = Self(unchecked: "invalid_replay_window")
  public static let eventIDReuse = Self(unchecked: "event_id_reuse")
  public static let operationIDReuse = Self(unchecked: "operation_id_reuse")
  public static let operationSequenceOverflow = Self(unchecked: "operation_sequence_overflow")
  public static let invalidOperationCapacity = Self(unchecked: "invalid_operation_capacity")
  public static let capabilityDenied = Self(unchecked: "capability_denied")
  public static let capabilityMismatch = Self(unchecked: "capability_mismatch")
  public static let unknownOperationKind = Self(unchecked: "unknown_operation_kind")
  public static let scopeDenied = Self(unchecked: "scope_denied")

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ErrorEnvelope: Codable, Equatable, Sendable {
  public let code: ProtocolErrorCode
  public let operationID: OperationID?
  public let scope: ResourceScope?
  public let revision: Revision?
  public let retryable: Bool
  public let details: [String: String]

  public init(
    code: ProtocolErrorCode,
    operationID: OperationID? = nil,
    scope: ResourceScope? = nil,
    revision: Revision? = nil,
    retryable: Bool = false,
    details: [String: String] = [:]
  ) throws {
    guard details.count <= 16,
      details.keys.allSatisfy({ key in
        key.utf8.count <= IdentifierValidation.maximumUTF8Length
          && !key.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
      }),
      details.values.allSatisfy({ value in
        value.utf8.count <= IdentifierValidation.maximumUTF8Length
          && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
      })
    else {
      throw ProtocolError.invalidEnvelope
    }
    self.code = code
    self.operationID = operationID
    self.scope = scope
    self.revision = revision
    self.retryable = retryable
    self.details = details
  }

  fileprivate init(
    uncheckedCode code: ProtocolErrorCode,
    operationID: OperationID?,
    scope: ResourceScope?,
    revision: Revision?,
    retryable: Bool,
    details: [String: String]
  ) {
    self.code = code
    self.operationID = operationID
    self.scope = scope
    self.revision = revision
    self.retryable = retryable
    self.details = details
  }

  private enum CodingKeys: String, CodingKey {
    case code
    case operationID = "operation_id"
    case scope
    case revision
    case retryable
    case details
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      code: container.decode(ProtocolErrorCode.self, forKey: .code),
      operationID: container.decodeIfPresent(OperationID.self, forKey: .operationID),
      scope: container.decodeIfPresent(ResourceScope.self, forKey: .scope),
      revision: container.decodeIfPresent(Revision.self, forKey: .revision),
      retryable: container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false,
      details: container.decodeIfPresent([String: String].self, forKey: .details) ?? [:]
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code, forKey: .code)
    try container.encodeIfPresent(operationID, forKey: .operationID)
    try container.encodeIfPresent(scope, forKey: .scope)
    try container.encodeIfPresent(revision, forKey: .revision)
    try container.encode(retryable, forKey: .retryable)
    try container.encode(details, forKey: .details)
  }
}

extension ProtocolError {
  public var code: ProtocolErrorCode {
    switch self {
    case .invalidIdentifier: .invalidIdentifier
    case .invalidScope: .invalidScope
    case .invalidRevision: .invalidRevision
    case .invalidEpoch: .invalidEpoch
    case .invalidVersion: .invalidVersion
    case .unsupportedMajor: .unsupportedMajor
    case .noCompatibleVersion: .noCompatibleVersion
    case .invalidFrameLength: .invalidFrameLength
    case .frameTooLarge: .frameTooLarge
    case .truncatedFrame: .truncatedFrame
    case .trailingFrameBytes: .trailingFrameBytes
    case .malformedPayload: .malformedPayload
    case .invalidEnvelope: .invalidEnvelope
    case .revisionOverflow: .revisionOverflow
    case .epochMismatch: .epochMismatch
    case .replayGap: .replayGap
    case .replayRegression: .replayRegression
    case .invalidReplayWindow: .invalidReplayWindow
    case .eventIDReuse: .eventIDReuse
    case .operationIDReuse: .operationIDReuse
    case .operationSequenceOverflow: .operationSequenceOverflow
    case .invalidOperationCapacity: .invalidOperationCapacity
    case .capabilityDenied: .capabilityDenied
    case .capabilityMismatch: .capabilityMismatch
    case .unknownOperationKind: .unknownOperationKind
    case .scopeDenied: .scopeDenied
    }
  }

  public func wireEnvelope(
    operationID: OperationID? = nil,
    scope: ResourceScope? = nil,
    revision: Revision? = nil
  ) -> ErrorEnvelope {
    var details: [String: String] = [:]
    switch self {
    case .invalidIdentifier(let kind):
      details["identifier_kind"] = kind.rawValue
    case .unsupportedMajor(let expected, let actual):
      details["expected_major"] = String(expected)
      details["actual_major"] = String(actual)
    case .invalidFrameLength(let length), .frameTooLarge(let length),
      .trailingFrameBytes(let length):
      details["length"] = String(length)
    case .epochMismatch(let expected, let actual):
      details["expected_epoch"] = String(expected.value)
      details["actual_epoch"] = String(actual.value)
    case .replayGap(let expected, let actual):
      details["expected_revision"] = String(expected.value)
      details["actual_revision"] = String(actual.value)
    case .replayRegression(let previous, let actual):
      details["previous_revision"] = String(previous.value)
      details["actual_revision"] = String(actual.value)
    case .capabilityDenied(let capability):
      details["capability"] = capability.rawValue
    case .capabilityMismatch(let expected, let actual):
      details["expected_capability"] = expected.rawValue
      details["actual_capability"] = actual.rawValue
    case .unknownOperationKind(let kind):
      details["operation_kind"] = kind.rawValue
    case .eventIDReuse(let eventID):
      details["event_id"] = eventID.rawValue
    case .operationIDReuse(let operationID):
      details["operation_id"] = operationID.rawValue
    default:
      break
    }
    return ErrorEnvelope(
      uncheckedCode: code,
      operationID: operationID,
      scope: scope,
      revision: revision,
      retryable: self == .truncatedFrame || self == .noCompatibleVersion,
      details: details
    )
  }
}

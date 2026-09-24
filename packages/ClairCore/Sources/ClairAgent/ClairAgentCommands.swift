import ClairShared
import Foundation

public enum ClairAgentCommandError: String, Error, Codable, LocalizedError, Sendable {
  case invalidCommand
  case invalidLimits
  case authorizationDenied
  case scopeMismatch
  case staleSession
  case staleApproval
  case conflictingOperation
  case operationCapacity
  case sessionCapacity
  case approvalCapacity
  case invalidEventStream

  public var errorDescription: String? { "Agent command rejected: \(rawValue)." }
}

/// References one occurrence of a normalized H05 approval, not a provider ID.
public struct ClairAgentApprovalReference: Codable, Equatable, Sendable {
  public let requestID: String
  public let eventID: EventID
  public let revision: Revision

  public init(requestID: String, eventID: EventID, revision: Revision) throws {
    guard requestID.utf8.count == 64,
      requestID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      revision > .zero
    else { throw ClairAgentCommandError.invalidCommand }
    self.requestID = requestID
    self.eventID = eventID
    self.revision = revision
  }

  private enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case eventID = "event_id"
    case revision
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      requestID: container.decode(String.self, forKey: .requestID),
      eventID: container.decode(EventID.self, forKey: .eventID),
      revision: container.decode(Revision.self, forKey: .revision)
    )
  }
}

public enum ClairAgentCommandKind: String, Codable, CaseIterable, Sendable {
  case prompt
  case approve
  case deny
  case interrupt
  case stop

  public var operationKind: OperationKind {
    switch self {
    case .prompt: .agentInput
    case .approve: .agentApprove
    case .deny: .agentDeny
    case .interrupt: .agentInterrupt
    case .stop: .agentStop
    }
  }

  public var capability: Capability {
    // Every case maps to an authoritative B03 operation kind.
    operationKind.requiredCapability!
  }
}

public enum ClairAgentCommandAction: Codable, Equatable, Sendable, CustomStringConvertible {
  public static let maximumPromptBytes = 16 * 1024

  case prompt(String)
  case approve(ClairAgentApprovalReference)
  case deny(ClairAgentApprovalReference)
  case interrupt
  case stop

  public var kind: ClairAgentCommandKind {
    switch self {
    case .prompt: .prompt
    case .approve: .approve
    case .deny: .deny
    case .interrupt: .interrupt
    case .stop: .stop
    }
  }

  public var approval: ClairAgentApprovalReference? {
    switch self {
    case .approve(let reference), .deny(let reference): reference
    default: nil
    }
  }

  public var description: String { "AgentCommandAction(\(kind.rawValue), <redacted>)" }

  public func validate() throws {
    if case .prompt(let text) = self {
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        text.utf8.count <= Self.maximumPromptBytes, !text.contains("\0")
      else { throw ClairAgentCommandError.invalidCommand }
    }
  }

  private enum CodingKeys: String, CodingKey { case kind, prompt, approval }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(ClairAgentCommandKind.self, forKey: .kind)
    switch kind {
    case .prompt:
      guard !container.contains(.approval) else { throw ClairAgentCommandError.invalidCommand }
      self = .prompt(try container.decode(String.self, forKey: .prompt))
    case .approve, .deny:
      guard !container.contains(.prompt) else { throw ClairAgentCommandError.invalidCommand }
      let reference = try container.decode(ClairAgentApprovalReference.self, forKey: .approval)
      self = kind == .approve ? .approve(reference) : .deny(reference)
    case .interrupt, .stop:
      guard !container.contains(.prompt), !container.contains(.approval) else {
        throw ClairAgentCommandError.invalidCommand
      }
      self = kind == .interrupt ? .interrupt : .stop
    }
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .prompt(let text): try container.encode(text, forKey: .prompt)
    case .approve(let reference), .deny(let reference):
      try container.encode(reference, forKey: .approval)
    case .interrupt, .stop: break
    }
  }
}

public struct ClairAgentCommandPayload: Codable, Equatable, Sendable, CustomStringConvertible {
  public let epoch: SessionEpoch
  public let processGeneration: UInt64
  public let action: ClairAgentCommandAction

  public init(
    epoch: SessionEpoch, processGeneration: UInt64, action: ClairAgentCommandAction
  ) throws {
    guard processGeneration > 0 else { throw ClairAgentCommandError.invalidCommand }
    try action.validate()
    self.epoch = epoch
    self.processGeneration = processGeneration
    self.action = action
  }

  public var description: String { "AgentCommandPayload(<redacted>)" }

  private enum CodingKeys: String, CodingKey {
    case epoch
    case processGeneration = "process_generation"
    case action
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      epoch: container.decode(SessionEpoch.self, forKey: .epoch),
      processGeneration: container.decode(UInt64.self, forKey: .processGeneration),
      action: container.decode(ClairAgentCommandAction.self, forKey: .action)
    )
  }
}

public typealias ClairAgentCommand = OperationRequest<ClairAgentCommandPayload>

/// A result describes the command commitment, not eventual provider completion.
/// An indeterminate outcome must never be retried with the same operation ID.
public enum ClairAgentCommandOutcome: String, Codable, Equatable, Sendable {
  case committed
  case rejected
  case indeterminate
}

/// Non-wire input to a generation-bound provider endpoint. No provider-specific
/// route, credential, path, or raw payload is supplied by the caller.
public struct ClairAgentCommandEffect: Sendable, CustomStringConvertible {
  public let identity: ClairAgentSessionIdentity
  public let operationID: OperationID
  public let payload: ClairAgentCommandPayload

  public init(
    identity: ClairAgentSessionIdentity,
    operationID: OperationID,
    payload: ClairAgentCommandPayload
  ) {
    self.identity = identity
    self.operationID = operationID
    self.payload = payload
  }

  public var description: String { "AgentCommandEffect(<redacted>)" }
}

/// Implementations must synchronously commit a bounded effect for the exact
/// identity/generation, or reject without effects. They must not block on I/O,
/// reenter the command boundary, or defer unchecked effects to another task.
/// Uncertain external outcomes return .indeterminate and are never redispatched.
public protocol ClairAgentCommandEndpoint: Sendable {
  func commit(_ effect: ClairAgentCommandEffect) -> ClairAgentCommandOutcome
}

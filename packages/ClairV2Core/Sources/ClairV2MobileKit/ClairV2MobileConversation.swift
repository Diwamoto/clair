import ClairV2Agent
import ClairV2Shared
import ClairV2Transport
import Foundation

/// Client-local decisions surfaced to the native UI when composing or
/// dispatching a scoped H06 command. The host's own `ClairV2AgentCommandBoundary`
/// authorization/generation checks remain the authoritative fail-closed
/// boundary; this layer exists so the UI never attempts a network round trip
/// for a command it can already prove is empty, duplicate, or stale.
public enum ClairV2MobileConversationError: Error, Equatable, LocalizedError, Sendable {
  case notAttached
  case emptyPrompt
  case promptTooLarge
  case staleApproval
  case transportRejected(ClairV2AgentCommandError)
  case transportFailed

  public var errorDescription: String? {
    switch self {
    case .notAttached:
      "No active agent session is attached."
    case .emptyPrompt:
      "The prompt is empty."
    case .promptTooLarge:
      "The prompt exceeds the maximum size."
    case .staleApproval:
      "This approval no longer matches the current attention."
    case .transportRejected(let error):
      error.localizedDescription
    case .transportFailed:
      "The command could not be delivered to the host."
    }
  }
}

/// One conversation message folded from a normalized H05 conversation event,
/// retained for display only. `id` is the normalized `EventID`, which is
/// already a stable digest of the provider event identity.
public struct ClairV2MobileConversationMessage: Equatable, Identifiable, Sendable {
  public let id: EventID
  public let role: ClairV2AgentConversationRole
  public let text: String
  public let isDelta: Bool
  public let revision: Revision
}

/// A pending attention item the UI can offer for approve/deny. It carries
/// exactly the fields H06 needs to build an `ClairV2AgentApprovalReference`;
/// it never carries provider-raw text or credentials.
public struct ClairV2MobileAttentionItem: Equatable, Identifiable, Sendable {
  public let requestID: String
  public let eventID: EventID
  public let revision: Revision
  public let kind: ClairV2AgentAttentionKind

  public var id: String { requestID }

  func makeReference() throws -> ClairV2AgentApprovalReference {
    try ClairV2AgentApprovalReference(requestID: requestID, eventID: eventID, revision: revision)
  }
}

/// Local, transport-neutral fold of the H05 normalized event stream for one
/// session. Applying events is idempotent and monotonic: a duplicate,
/// out-of-order, or superseded-generation event is safely dropped instead of
/// corrupting the transcript. This makes it safe to feed events regardless of
/// the app's scene lifecycle -- a response delivered while the app is
/// backgrounded folds exactly the same way it would in the foreground.
public struct ClairV2MobileConversationState: Equatable, Sendable {
  public static let maximumRetainedMessages = 500
  public static let maximumRetainedToolCalls = 256
  public static let maximumPendingApprovals = 64

  public private(set) var scope: ResourceScope?
  public private(set) var epoch: SessionEpoch?
  public private(set) var lastRevision: Revision?
  public private(set) var messages: [ClairV2MobileConversationMessage] = []
  public private(set) var toolCalls: [ClairV2AgentToolCallEvent] = []
  public private(set) var pendingApprovals: [ClairV2MobileAttentionItem] = []
  public private(set) var latestAttention: ClairV2AgentAttentionEvent?
  public private(set) var usage: ClairV2AgentUsageEvent?
  public private(set) var completion: ClairV2AgentCompletionStatus?

  public init() {}

  public var isActive: Bool { completion == nil }

  /// Resets the transcript to a fresh, empty state scoped to a (possibly new)
  /// session identity/epoch. Called on explicit attach and whenever an event
  /// proves a newer generation has started.
  public mutating func reset(scope: ResourceScope?, epoch: SessionEpoch?) {
    self.scope = scope
    self.epoch = epoch
    lastRevision = nil
    messages.removeAll()
    toolCalls.removeAll()
    pendingApprovals.removeAll()
    latestAttention = nil
    usage = nil
    completion = nil
  }

  /// Folds one normalized event. Returns `true` when the event advanced the
  /// transcript and `false` when it was safely ignored (wrong scope, a
  /// superseded generation, or an already-applied/out-of-order revision).
  @discardableResult
  public mutating func apply(_ event: ClairV2AgentNormalizedEvent) -> Bool {
    guard event.scope.isSessionScope else { return false }
    guard let eventEpoch = event.epoch, let eventRevision = event.revision else { return false }
    if let scope, scope != event.scope { return false }
    if let epoch {
      if eventEpoch < epoch { return false }
      if eventEpoch > epoch {
        // The provider process was replaced with a newer generation. Never
        // mix transcripts across generations: start clean before folding.
        reset(scope: event.scope, epoch: eventEpoch)
      }
    } else {
      reset(scope: event.scope, epoch: eventEpoch)
    }
    if let lastRevision, eventRevision <= lastRevision { return false }

    scope = event.scope
    lastRevision = eventRevision
    fold(event.payload, eventID: event.eventID, revision: eventRevision)
    return true
  }

  public mutating func removePendingApproval(requestID: String) {
    pendingApprovals.removeAll { $0.requestID == requestID }
  }

  private mutating func fold(
    _ payload: ClairV2AgentEventPayload,
    eventID: EventID,
    revision: Revision
  ) {
    switch payload {
    case .conversation(let message):
      messages.append(
        ClairV2MobileConversationMessage(
          id: eventID,
          role: message.role,
          text: message.text,
          isDelta: message.isDelta,
          revision: revision
        )
      )
      if messages.count > Self.maximumRetainedMessages {
        messages.removeFirst(messages.count - Self.maximumRetainedMessages)
      }
    case .toolCall(let toolCall):
      if let index = toolCalls.firstIndex(where: { $0.toolID == toolCall.toolID }) {
        toolCalls[index] = toolCall
      } else {
        toolCalls.append(toolCall)
        if toolCalls.count > Self.maximumRetainedToolCalls {
          toolCalls.removeFirst(toolCalls.count - Self.maximumRetainedToolCalls)
        }
      }
    case .attention(let attention):
      latestAttention = attention
      applyAttention(attention, eventID: eventID, revision: revision)
    case .completion(let completionEvent):
      completion = completionEvent.status
      pendingApprovals.removeAll()
    case .usage(let usageEvent):
      usage = usageEvent
    }
  }

  /// Mirrors the exact-once/fail-closed pending-approval invariants that
  /// `ClairV2AgentCommandBoundary.ingest` enforces on the host, so the UI
  /// never offers an approval the host would already reject as stale.
  private mutating func applyAttention(
    _ attention: ClairV2AgentAttentionEvent,
    eventID: EventID,
    revision: Revision
  ) {
    guard let requestID = attention.requestID else {
      if !(attention.kind == .approval && attention.status == .pending) {
        // An uncorrelated attention cannot identify one pending request:
        // invalidate the whole executable approval window.
        pendingApprovals.removeAll()
      }
      return
    }
    guard attention.kind == .approval else {
      // The provider reused a request identity under a different attention
      // family: that is a replacement, not an approval.
      removePendingApproval(requestID: requestID)
      return
    }
    if attention.status == .pending {
      removePendingApproval(requestID: requestID)
      pendingApprovals.append(
        ClairV2MobileAttentionItem(
          requestID: requestID, eventID: eventID, revision: revision, kind: attention.kind
        )
      )
      if pendingApprovals.count > Self.maximumPendingApprovals {
        pendingApprovals.removeFirst(pendingApprovals.count - Self.maximumPendingApprovals)
      }
    } else if pendingApprovals.contains(where: { $0.requestID == requestID }) {
      removePendingApproval(requestID: requestID)
    } else {
      // An uncorrelated resolution cannot safely identify which pending
      // request was answered. Fail closed for the whole window instead of
      // leaving a stale approval executable.
      pendingApprovals.removeAll()
    }
  }
}

/// Transport-neutral boundary for dispatching one scoped H06 command. The
/// production Network.framework/TLS adapter is a later integration boundary,
/// exactly like `ClairV2MobileTransport`; this protocol only depends on
/// `ClairV2Agent`/`ClairV2Transport` types so the mobile app never links
/// host-only daemon code.
public protocol ClairV2MobileAgentTransport: Sendable {
  func dispatch(
    _ command: ClairV2AgentCommand,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2AgentCommandOutcome
}

/// Explicit "not yet wired" boundary, mirroring
/// `ClairNetworkTLSMobileTransportBoundary`. The native app can construct a
/// conversation controller before the real transport exists; every dispatch
/// fails closed instead of silently no-oping.
public struct ClairV2MobileUnavailableAgentTransport: ClairV2MobileAgentTransport {
  public init() {}

  public func dispatch(
    _ command: ClairV2AgentCommand,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2AgentCommandOutcome {
    throw ClairMobileTransportBoundaryError.unavailable
  }
}

/// Actor-owned client-side conversation surface. It folds normalized H05
/// events for display and submits scoped H06 commands through the injected
/// transport. It is the single owner of in-flight command de-duplication so a
/// duplicated or rapid-repeat UI tap can never dispatch a command twice, and
/// it never treats scene lifecycle as a precondition for folding events.
public actor ClairV2MobileConversationController {
  /// Everything needed to address one live provider process generation. The
  /// concrete value is supplied by whatever later task establishes the live
  /// session (its wire attach/session-start handshake); this controller only
  /// consumes it.
  public struct Attachment: Equatable, Sendable {
    public let identity: ClairV2AgentSessionIdentity
    public let epoch: SessionEpoch
    public let processGeneration: UInt64
    public let connection: ClairAuthenticatedConnection

    public init(
      identity: ClairV2AgentSessionIdentity,
      epoch: SessionEpoch,
      processGeneration: UInt64,
      connection: ClairAuthenticatedConnection
    ) throws {
      guard processGeneration > 0 else { throw ClairV2AgentCommandError.invalidCommand }
      self.identity = identity
      self.epoch = epoch
      self.processGeneration = processGeneration
      self.connection = connection
    }
  }

  private let transport: any ClairV2MobileAgentTransport
  private var attachment: Attachment?
  private var stateValue = ClairV2MobileConversationState()
  private var inFlight: [String: Task<ClairV2AgentCommandOutcome, Error>] = [:]

  /// Internal (not public API) synchronous observation point, fired the
  /// instant `dispatch` decides whether a call becomes the in-flight primary
  /// or joins an existing one. Exists only so `@testable import` tests can
  /// prove genuine concurrent overlap deterministically instead of racing
  /// real scheduler timing with sleeps.
  private var dispatchObserverForTesting: (@Sendable (_ key: String, _ joined: Bool) -> Void)?

  public init(transport: any ClairV2MobileAgentTransport = ClairV2MobileUnavailableAgentTransport())
  {
    self.transport = transport
  }

  func setDispatchObserverForTesting(
    _ observer: (@Sendable (_ key: String, _ joined: Bool) -> Void)?
  ) {
    dispatchObserverForTesting = observer
  }

  public var state: ClairV2MobileConversationState { stateValue }
  public var isAttached: Bool { attachment != nil }

  /// Attaches (or re-attaches) to a live process generation and resets the
  /// transcript to a clean state scoped to it. Detaching then re-attaching is
  /// the expected shape of a background/foreground reconnect: no partial
  /// state from the previous attachment leaks into the new one.
  public func attach(_ attachment: Attachment) {
    self.attachment = attachment
    inFlight.removeAll()
    stateValue.reset(scope: attachment.identity.sessionScope, epoch: attachment.epoch)
  }

  public func detach() {
    attachment = nil
    inFlight.removeAll()
  }

  /// Folds one normalized event regardless of app lifecycle. Safe to call
  /// while the scene is backgrounded: state mutation never depends on UI
  /// visibility, so a response delivered in the background is neither lost
  /// nor corrupted, and is simply visible once the app returns to the
  /// foreground.
  @discardableResult
  public func ingest(_ event: ClairV2AgentNormalizedEvent) -> Bool {
    stateValue.apply(event)
  }

  /// Submits one prompt. The full text is taken atomically at the call site
  /// so a rapid-repeat tap can only ever join the exact prompt already in
  /// flight (via the "prompt" in-flight key below), never interleave with a
  /// separate `updateDraft` call from another queued actor turn.
  @discardableResult
  public func submitPrompt(_ text: String) async throws -> ClairV2AgentCommandOutcome {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ClairV2MobileConversationError.emptyPrompt
    }
    guard text.utf8.count <= ClairV2AgentCommandAction.maximumPromptBytes else {
      throw ClairV2MobileConversationError.promptTooLarge
    }
    return try await dispatch(.prompt(text), key: "prompt")
  }

  @discardableResult
  public func approve(requestID: String) async throws -> ClairV2AgentCommandOutcome {
    try await respond(requestID: requestID, approve: true)
  }

  @discardableResult
  public func deny(requestID: String) async throws -> ClairV2AgentCommandOutcome {
    try await respond(requestID: requestID, approve: false)
  }

  @discardableResult
  public func interrupt() async throws -> ClairV2AgentCommandOutcome {
    try await dispatch(.interrupt, key: "interrupt")
  }

  @discardableResult
  public func stop() async throws -> ClairV2AgentCommandOutcome {
    try await dispatch(.stop, key: "stop")
  }

  private func respond(requestID: String, approve: Bool) async throws -> ClairV2AgentCommandOutcome
  {
    guard let item = stateValue.pendingApprovals.first(where: { $0.requestID == requestID }) else {
      throw ClairV2MobileConversationError.staleApproval
    }
    let key = "\(approve ? "approve" : "deny"):\(requestID)"
    do {
      let reference = try item.makeReference()
      let action: ClairV2AgentCommandAction = approve ? .approve(reference) : .deny(reference)
      let outcome = try await dispatch(action, key: key)
      if outcome != .rejected {
        stateValue.removePendingApproval(requestID: requestID)
      }
      return outcome
    } catch ClairV2MobileConversationError.transportRejected(.staleApproval) {
      // The host's own generation-bound pending window already moved past
      // this request. Self-heal the local mirror instead of leaving a dead
      // approval executable in the UI.
      stateValue.removePendingApproval(requestID: requestID)
      throw ClairV2MobileConversationError.staleApproval
    }
  }

  private func dispatch(
    _ action: ClairV2AgentCommandAction,
    key: String
  ) async throws -> ClairV2AgentCommandOutcome {
    guard let attachment else { throw ClairV2MobileConversationError.notAttached }
    if let existing = inFlight[key] {
      // A duplicate or rapid-repeat tap joins the single in-flight command
      // instead of dispatching a second one.
      dispatchObserverForTesting?(key, true)
      return try await existing.value
    }
    dispatchObserverForTesting?(key, false)
    let task = Task { [transport] () async throws -> ClairV2AgentCommandOutcome in
      let operationID = try OperationID("mobile-\(UUID().uuidString.lowercased())")
      let payload = try ClairV2AgentCommandPayload(
        epoch: attachment.epoch,
        processGeneration: attachment.processGeneration,
        action: action
      )
      let command = ClairV2AgentCommand(
        operationID: operationID,
        scope: attachment.identity.sessionScope,
        kind: action.kind.operationKind,
        baseRevision: action.approval?.revision,
        capability: action.kind.capability,
        payload: payload
      )
      do {
        return try await transport.dispatch(command, on: attachment.connection)
      } catch let error as ClairV2AgentCommandError {
        throw ClairV2MobileConversationError.transportRejected(error)
      } catch {
        throw ClairV2MobileConversationError.transportFailed
      }
    }
    inFlight[key] = task
    defer { inFlight[key] = nil }
    return try await task.value
  }
}

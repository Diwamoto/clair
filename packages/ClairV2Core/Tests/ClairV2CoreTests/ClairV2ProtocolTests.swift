import Foundation
import Testing

@testable import ClairV2Shared

private struct EventPayload: Codable, Equatable, Sendable {
  let message: String
}

private struct InputPayload: Codable, Equatable, Sendable {
  let text: String
}

private func projectID(_ value: String = "project-1") throws -> ProjectID {
  try ProjectID(value)
}

private func worktreeID(_ value: String = "worktree-1") throws -> WorktreeID {
  try WorktreeID(value)
}

private func sessionID(_ value: String = "session-1") throws -> SessionID {
  try SessionID(value)
}

private func operationID(_ value: String = "operation-1") throws -> OperationID {
  try OperationID(value)
}

private func eventID(_ value: String = "event-1") throws -> EventID {
  try EventID(value)
}

private func sessionScope(
  project: String = "project-1",
  worktree: String? = "worktree-1",
  session: String = "session-1"
) throws -> ResourceScope {
  try ResourceScope(
    projectID: projectID(project),
    worktreeID: worktree.map { try! WorktreeID($0) },
    sessionID: sessionID(session)
  )
}

@Test
func protocolNegotiationChoosesTheHighestCompatibleMinorAndIntersection() throws {
  let clientCapabilities = try CapabilitySet([
    .rawTerminal,
    .terminalInput,
    try Capability("future.capability"),
  ])
  let serverCapabilities = try CapabilitySet([
    .rawTerminal,
    .agentCatalog,
    try Capability("future.capability"),
  ])
  let client = try ProtocolOffer(
    versionRanges: [
      try ProtocolVersionRange(major: 1, minimumMinor: 0, maximumMinor: 3)
    ],
    maximumFramePayloadBytes: 8 * 1024,
    capabilities: clientCapabilities
  )
  let server = try ProtocolOffer(
    versionRanges: [
      try ProtocolVersionRange(major: 1, minimumMinor: 1, maximumMinor: 2)
    ],
    maximumFramePayloadBytes: 64 * 1024,
    capabilities: serverCapabilities
  )

  let negotiated = try ProtocolNegotiator.negotiate(client: client, server: server)
  let expectedVersion = try ProtocolVersion(major: 1, minor: 2)

  #expect(negotiated.version == expectedVersion)
  #expect(negotiated.maximumFramePayloadBytes == 8 * 1024)
  #expect(negotiated.capabilities.values.map(\.rawValue) == ["future.capability", "raw_terminal"])
}

@Test
func protocolNegotiationRejectsMajorAndMinorIncompatibility() throws {
  let client = try ProtocolOffer(
    versionRanges: [try ProtocolVersionRange(major: 2, minor: 0)]
  )
  let server = try ProtocolOffer(
    versionRanges: [try ProtocolVersionRange(major: 1, minor: 0)]
  )

  #expect(throws: ProtocolError.unsupportedMajor(expected: 1, actual: 2)) {
    try ProtocolNegotiator.negotiate(client: client, server: server)
  }

  let clientMinor = try ProtocolOffer(
    versionRanges: [
      try ProtocolVersionRange(major: 1, minimumMinor: 4, maximumMinor: 5)
    ]
  )
  let serverMinor = try ProtocolOffer(
    versionRanges: [
      try ProtocolVersionRange(major: 1, minimumMinor: 0, maximumMinor: 2)
    ]
  )
  #expect(throws: ProtocolError.noCompatibleVersion) {
    try ProtocolNegotiator.negotiate(client: clientMinor, server: serverMinor)
  }
}

@Test
func eventGoldenWireIgnoresUnknownFieldsAndPreservesUnknownNames() throws {
  let fixture = Data(
    #"""
    {
      "event_id": "event-1",
      "type": "future.event",
      "scope": {
        "project_id": "project-1",
        "session_id": "session-1",
        "future_scope_field": "ignored"
      },
      "epoch": 1,
      "revision": 1,
      "payload": {
        "message": "hello",
        "future_payload_field": 42
      },
      "future_envelope_field": true
    }
    """#.utf8
  )

  let event = try ProtocolCodec.decode(
    EventEnvelope<EventPayload>.self,
    from: fixture
  )
  let encoded = try ProtocolCodec.encode(event)
  let golden =
    #"{"epoch":1,"event_id":"event-1","payload":{"message":"hello"},"revision":1,"scope":{"project_id":"project-1","session_id":"session-1"},"type":"future.event"}"#

  #expect(event.kind.rawValue == "future.event")
  #expect(encoded == Data(golden.utf8))
  #expect(!String(decoding: encoded, as: UTF8.self).contains("future_payload_field"))
}

@Test
func errorGoldenWireAcceptsUnknownErrorCodesAndTypedFailuresEncodeSafely() throws {
  let fixture = Data(
    #"{"code":"future_error","retryable":true,"details":{"reason":"later"},"future_field":"ignored"}"#
      .utf8
  )
  let decoded = try ProtocolCodec.decode(ErrorEnvelope.self, from: fixture)

  #expect(decoded.code.rawValue == "future_error")
  #expect(decoded.retryable)
  #expect(decoded.details == ["reason": "later"])
  #expect(
    try ProtocolCodec.encode(decoded)
      == Data(#"{"code":"future_error","details":{"reason":"later"},"retryable":true}"#.utf8)
  )

  let operation = try operationID()
  let wire = ProtocolError.operationIDReuse(operation).wireEnvelope(
    operationID: operation,
    scope: try sessionScope()
  )
  #expect(wire.code == .operationIDReuse)
  #expect(wire.details["operation_id"] == operation.rawValue)
  #expect(wire.operationID == operation)
}

@Test
func boundedFrameGoldenWireRejectsInvalidAndOversizedLengths() throws {
  let limits = try FrameLimits(maximumPayloadBytes: 4)
  let frame = try BoundedFrame(payload: Data([1, 2, 3, 4]), limits: limits)

  #expect(frame.encoded == Data([0, 0, 0, 4, 1, 2, 3, 4]))
  #expect(try BoundedFrame.decode(frame.encoded, limits: limits) == frame)

  #expect(throws: ProtocolError.frameTooLarge(5)) {
    try BoundedFrame(payload: Data([1, 2, 3, 4, 5]), limits: limits)
  }
  #expect(throws: ProtocolError.frameTooLarge(5)) {
    try BoundedFrame.decode(Data([0, 0, 0, 5]), limits: limits)
  }
  #expect(throws: ProtocolError.invalidFrameLength(0)) {
    try BoundedFrame.decode(Data([0, 0, 0, 0]), limits: limits)
  }
  #expect(throws: ProtocolError.invalidFrameLength(0)) {
    try BoundedFrame(payload: Data(), limits: limits)
  }
  #expect(throws: ProtocolError.truncatedFrame) {
    try BoundedFrame.decode(Data([0, 0, 0, 2, 1]), limits: limits)
  }
  #expect(throws: ProtocolError.trailingFrameBytes(1)) {
    try BoundedFrame.decode(Data([0, 0, 0, 1, 1, 2]), limits: limits)
  }

  var decoder = BoundedFrameDecoder(limits: limits)
  #expect(try decoder.append(Data(frame.encoded.prefix(2))) == [])
  #expect(try decoder.append(Data(frame.encoded.dropFirst(2))) == [frame])
  try decoder.finish()

  let secondFrame = try BoundedFrame(payload: Data([9]), limits: limits)
  var batchedDecoder = BoundedFrameDecoder(limits: limits)
  var batched = frame.encoded
  batched.append(secondFrame.encoded)
  #expect(try batchedDecoder.append(batched) == [frame, secondFrame])

  var oversizedDecoder = BoundedFrameDecoder(limits: limits)
  #expect(throws: ProtocolError.frameTooLarge(5)) {
    try oversizedDecoder.append(Data([0, 0, 0, 5]))
  }

  var boundedChunkDecoder = BoundedFrameDecoder(limits: limits)
  var validFrameWithOversizedSuffix = frame.encoded
  validFrameWithOversizedSuffix.append(Data(repeating: 0xff, count: 1_024 * 1_024))
  #expect(throws: ProtocolError.frameTooLarge(Int(UInt32.max))) {
    try boundedChunkDecoder.append(validFrameWithOversizedSuffix)
  }
  #expect(!boundedChunkDecoder.hasPartialFrame)
}

@Test
func replayStateRequiresContiguousRevisionAndRejectsConflictingReuse() throws {
  let scope = try sessionScope()
  let epoch = try SessionEpoch(1)
  let cursor = try ReplayCursor(scope: scope, epoch: epoch)
  var replay = try ReplayState(cursor: cursor)
  let first = try EventEnvelope(
    eventID: eventID(),
    kind: .sessionOutput,
    scope: scope,
    epoch: epoch,
    revision: Revision(1),
    payload: EventPayload(message: "one")
  )

  #expect(try replay.apply(first) == .applied)
  #expect(try replay.apply(first) == .duplicate)
  #expect(replay.cursor.revision == Revision(1))

  let gap = try EventEnvelope(
    eventID: eventID("event-gap"),
    kind: .sessionOutput,
    scope: scope,
    epoch: epoch,
    revision: Revision(3),
    payload: EventPayload(message: "three")
  )
  #expect(throws: ProtocolError.replayGap(expected: Revision(2), actual: Revision(3))) {
    try replay.apply(gap)
  }

  let second = try EventEnvelope(
    eventID: eventID("event-2"),
    kind: .sessionOutput,
    scope: scope,
    epoch: epoch,
    revision: Revision(2),
    payload: EventPayload(message: "two")
  )
  #expect(try replay.apply(second) == .applied)

  let regression = try EventEnvelope(
    eventID: eventID("event-regression"),
    kind: .sessionOutput,
    scope: scope,
    epoch: epoch,
    revision: Revision(1),
    payload: EventPayload(message: "regression")
  )
  #expect(throws: ProtocolError.replayRegression(previous: Revision(2), actual: Revision(1))) {
    try replay.apply(regression)
  }

  let conflictingReuse = try EventEnvelope(
    eventID: eventID(),
    kind: .sessionOutput,
    scope: scope,
    epoch: epoch,
    revision: Revision(3),
    payload: EventPayload(message: "changed")
  )
  #expect(throws: ProtocolError.eventIDReuse(try eventID())) {
    try replay.apply(conflictingReuse)
  }

  let wrongEpoch = try EventEnvelope(
    eventID: eventID("event-epoch"),
    kind: .sessionOutput,
    scope: scope,
    epoch: try SessionEpoch(2),
    revision: Revision(3),
    payload: EventPayload(message: "new epoch")
  )
  #expect(
    throws: ProtocolError.epochMismatch(
      expected: epoch,
      actual: try SessionEpoch(2)
    )
  ) {
    try replay.apply(wrongEpoch)
  }

  let wrongScope = try EventEnvelope(
    eventID: eventID("event-scope"),
    kind: .sessionOutput,
    scope: try sessionScope(project: "other-project"),
    epoch: epoch,
    revision: Revision(3),
    payload: EventPayload(message: "wrong scope")
  )
  #expect(throws: ProtocolError.scopeDenied) {
    try replay.apply(wrongScope)
  }
}

@Test
func operationLedgerAssignsArrivalOrderAndBoundsIdempotency() throws {
  let scope = try sessionScope()
  let inputKind = OperationKind.terminalInput
  let first = try OperationRequest(
    operationID: operationID(),
    scope: scope,
    kind: inputKind,
    baseRevision: Revision(0),
    capability: .writeTerminal,
    payload: InputPayload(text: "one")
  )
  let second = try OperationRequest(
    operationID: operationID("operation-2"),
    scope: scope,
    kind: inputKind,
    capability: .writeTerminal,
    payload: InputPayload(text: "two")
  )
  var ledger = try OperationLedger(capacity: 2)

  let firstReceipt = try ledger.register(first)
  let duplicateReceipt = try ledger.register(first)
  let secondReceipt = try ledger.register(second)

  #expect(firstReceipt.arrivalSequence == 1)
  #expect(firstReceipt.disposition == .accepted)
  #expect(duplicateReceipt.arrivalSequence == 1)
  #expect(duplicateReceipt.disposition == .duplicate)
  #expect(secondReceipt.arrivalSequence == 2)

  let reused = OperationRequest(
    operationID: first.operationID,
    scope: scope,
    kind: inputKind,
    baseRevision: Revision(0),
    capability: .writeTerminal,
    payload: InputPayload(text: "changed")
  )
  #expect(throws: ProtocolError.operationIDReuse(first.operationID)) {
    try ledger.register(reused)
  }

  let third = try OperationRequest(
    operationID: operationID("operation-3"),
    scope: scope,
    kind: inputKind,
    capability: .writeTerminal,
    payload: InputPayload(text: "three")
  )
  #expect(try ledger.register(third).arrivalSequence == 3)

  // The window is bounded: after eviction, a new use is a new arrival and
  // must not recover the old effect/result from unbounded memory.
  #expect(try ledger.register(first).arrivalSequence == 4)
}

@Test
func accessBoundaryUsesTypedHierarchyAndDefaultDenies() throws {
  let project = try projectID()
  let worktree = try worktreeID()
  let session = try sessionID()
  let worktreeScope = try ResourceScope(projectID: project, worktreeID: worktree)
  let sessionScope = try ResourceScope(
    projectID: project,
    worktreeID: worktree,
    sessionID: session
  )
  let otherProjectScope = try ResourceScope(
    projectID: try projectID("project-2"),
    worktreeID: worktree,
    sessionID: session
  )
  let boundary = try AccessBoundary(
    capabilities: try CapabilitySet([.writeTerminal, .signal, .terminalInput, .terminalInterrupt]),
    visibleScopes: [worktreeScope]
  )

  try boundary.authorize(scope: sessionScope, requiring: .writeTerminal)
  #expect(throws: ProtocolError.capabilityDenied(.view)) {
    try boundary.authorize(scope: sessionScope, requiring: .view)
  }
  #expect(throws: ProtocolError.scopeDenied) {
    try boundary.authorize(scope: otherProjectScope, requiring: .writeTerminal)
  }

  #expect(OperationKind.terminalInput.requiredCapability == .writeTerminal)
  #expect(OperationKind.terminalInterrupt.requiredCapability == .signal)
  #expect(OperationKind.agentInput.requiredCapability == .steerAgent)
  #expect(OperationKind.agentStop.requiredCapability == .terminate)
  #expect(OperationKind.reviewApply.requiredCapability == .approve)
  let terminalInputOperation = try OperationRequest(
    operationID: operationID("operation-terminal-input"),
    scope: sessionScope,
    kind: .terminalInput,
    capability: .writeTerminal,
    payload: InputPayload(text: "input")
  )
  try boundary.authorize(terminalInputOperation)
  let terminalInterruptOperation = try OperationRequest(
    operationID: operationID("operation-terminal-interrupt"),
    scope: sessionScope,
    kind: .terminalInterrupt,
    capability: .signal,
    payload: InputPayload(text: "interrupt")
  )
  try boundary.authorize(terminalInterruptOperation)

  let oldTerminalInputDeclaration = try OperationRequest(
    operationID: operationID("operation-old-terminal-input"),
    scope: sessionScope,
    kind: .terminalInput,
    capability: .terminalInput,
    payload: InputPayload(text: "input")
  )
  #expect(
    throws: ProtocolError.capabilityMismatch(expected: .writeTerminal, actual: .terminalInput)
  ) {
    try boundary.authorize(oldTerminalInputDeclaration)
  }
  let oldTerminalInterruptDeclaration = try OperationRequest(
    operationID: operationID("operation-old-terminal-interrupt"),
    scope: sessionScope,
    kind: .terminalInterrupt,
    capability: .terminalInterrupt,
    payload: InputPayload(text: "interrupt")
  )
  #expect(
    throws: ProtocolError.capabilityMismatch(expected: .signal, actual: .terminalInterrupt)
  ) {
    try boundary.authorize(oldTerminalInterruptDeclaration)
  }
  let legacyCapabilityOnlyBoundary = try AccessBoundary(
    capabilities: try CapabilitySet([.terminalInput, .terminalInterrupt]),
    visibleScopes: [worktreeScope]
  )
  #expect(throws: ProtocolError.capabilityDenied(.writeTerminal)) {
    try legacyCapabilityOnlyBoundary.authorize(terminalInputOperation)
  }
  #expect(throws: ProtocolError.capabilityDenied(.signal)) {
    try legacyCapabilityOnlyBoundary.authorize(terminalInterruptOperation)
  }

  let stopWithReadOnlyDeclaration = try OperationRequest(
    operationID: operationID("operation-stop-read-only"),
    scope: sessionScope,
    kind: .agentStop,
    capability: .view,
    payload: InputPayload(text: "stop")
  )
  #expect(
    throws: ProtocolError.capabilityMismatch(expected: .terminate, actual: .view)
  ) {
    try boundary.authorize(stopWithReadOnlyDeclaration)
  }

  let readOnlyBoundary = try AccessBoundary(
    capabilities: try CapabilitySet([.view]),
    visibleScopes: [worktreeScope]
  )
  let stopWithAuthoritativeDeclaration = try OperationRequest(
    operationID: operationID("operation-stop-read-only-grant"),
    scope: sessionScope,
    kind: .agentStop,
    capability: .terminate,
    payload: InputPayload(text: "stop")
  )
  #expect(throws: ProtocolError.capabilityDenied(.terminate)) {
    try readOnlyBoundary.authorize(stopWithAuthoritativeDeclaration)
  }

  let unknownKind = try OperationKind("agent.future")
  let unknownOperation = try OperationRequest(
    operationID: operationID("operation-unknown"),
    scope: sessionScope,
    kind: unknownKind,
    capability: .view,
    payload: InputPayload(text: "future")
  )
  #expect(throws: ProtocolError.unknownOperationKind(unknownKind)) {
    try boundary.authorize(unknownOperation)
  }

  let deniedByDefault = try AccessBoundary(
    capabilities: .empty,
    visibleScopes: []
  )
  #expect(throws: ProtocolError.capabilityDenied(.writeTerminal)) {
    try deniedByDefault.authorize(scope: sessionScope, requiring: .writeTerminal)
  }
}

@Test
func sessionScopeContainmentRequiresExactWorktreePresenceAndIdentity() throws {
  let project = try projectID()
  let otherProject = try projectID("project-2")
  let worktree = try worktreeID()
  let otherWorktree = try worktreeID("worktree-2")
  let session = try sessionID()
  let otherSessionID = try sessionID("session-2")

  let projectOwnedSession = try ResourceScope(
    projectID: project,
    sessionID: session
  )
  let sameProjectOwnedSession = try ResourceScope(
    projectID: project,
    sessionID: session
  )
  let managedSession = try ResourceScope(
    projectID: project,
    worktreeID: worktree,
    sessionID: session
  )
  let otherWorktreeSession = try ResourceScope(
    projectID: project,
    worktreeID: otherWorktree,
    sessionID: session
  )
  let otherSession = try ResourceScope(
    projectID: project,
    worktreeID: worktree,
    sessionID: otherSessionID
  )
  let otherProjectSession = try ResourceScope(
    projectID: otherProject,
    worktreeID: worktree,
    sessionID: session
  )
  let worktreeScope = try ResourceScope(projectID: project, worktreeID: worktree)

  #expect(projectOwnedSession.contains(sameProjectOwnedSession))
  #expect(!projectOwnedSession.contains(managedSession))
  #expect(!managedSession.contains(projectOwnedSession))
  #expect(!managedSession.contains(otherWorktreeSession))
  #expect(!managedSession.contains(otherSession))
  #expect(!managedSession.contains(otherProjectSession))
  #expect(managedSession.contains(managedSession))
  #expect(worktreeScope.contains(managedSession))
}

@Test
func envelopesRejectInvalidIdentityAndPositionCombinations() throws {
  #expect(throws: ProtocolError.invalidIdentifier(.project)) {
    try ProjectID("")
  }
  #expect(throws: ProtocolError.invalidIdentifier(.session)) {
    try SessionID(String(repeating: "x", count: 257))
  }
  #expect(throws: ProtocolError.invalidEpoch) {
    try SessionEpoch(0)
  }
  #expect(throws: ProtocolError.invalidVersion) {
    try ProtocolCodec.decode(
      ProtocolVersion.self,
      from: Data(#"{"major":0,"minor":0}"#.utf8)
    )
  }
  #expect(throws: ProtocolError.invalidFrameLength(-1)) {
    try FrameLimits(maximumPayloadBytes: -1)
  }

  let projectScope = try ResourceScope(projectID: projectID())
  #expect(
    throws: ProtocolError.invalidEnvelope
  ) {
    try EventEnvelope(
      eventID: eventID(),
      kind: .attention,
      scope: projectScope,
      epoch: try SessionEpoch(1),
      revision: Revision(1),
      payload: EventPayload(message: "invalid")
    )
  }
  #expect(throws: ProtocolError.invalidScope) {
    try ReplayCursor(
      scope: projectScope,
      epoch: try SessionEpoch(1)
    )
  }
}

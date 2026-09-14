import Foundation
import Testing

@testable import ClairV2Agent
@testable import ClairV2Shared

private func h05ProjectID(_ value: String = "project-h05") throws -> ProjectID {
  try ProjectID(value)
}

private func h05WorktreeID(_ value: String = "worktree-h05") throws -> WorktreeID {
  try WorktreeID(value)
}

private func h05SessionID(_ value: String = "session-h05") throws -> SessionID {
  try SessionID(value)
}

private func h05Identity(worktree: String? = "worktree-h05") throws -> ClairV2AgentSessionIdentity {
  try ClairV2AgentSessionIdentity(
    provider: ClairV2ProviderIdentity(
      providerID: .openCode,
      version: try ClairV2ProviderVersion("h05-fixture")
    ),
    projectID: try h05ProjectID(),
    worktreeID: worktree.map { try! h05WorktreeID($0) },
    sessionID: try h05SessionID()
  )
}

private func h05Data(_ value: String) -> Data {
  Data(value.utf8)
}

@Test
func h05MapsAllEventFamiliesAndPreservesIdentityAndRevisions() throws {
  let identity = try h05Identity()
  let input = h05Data(
    #"{"type":"message.part.updated","event_id":"conversation-1","properties":{"part":{"type":"text","role":"assistant"},"delta":"hello"},"secret":"do-not-export","path":"/private"}"#
      + "\n"
      + #"{"type":"tool_use","event_id":"tool-1","name":"search","call_id":"call-1","status":"running","arguments":{"token":"secret"}}"#
      + "\n"
      + #"{"type":"permission.asked","event_id":"attention-1","permission_id":"ask-1","prompt":"private prompt"}"#
      + "\n"
      + #"{"type":"usage","event_id":"usage-1","usage":{"input_tokens":3,"output_tokens":4}}"#
      + "\n"
      + #"{"type":"session.idle","event_id":"done-1"}"#
      + "\n"
  )

  let events = try ClairV2OpenCodeStreamNormalizer.normalize(
    stdout: input,
    identity: identity,
    epoch: try SessionEpoch(7)
  )
  let expectedEpoch = try SessionEpoch(7)

  #expect(events.count == 5)
  #expect(events.compactMap { $0.revision?.value } == [1, 2, 3, 4, 5])
  #expect(events.allSatisfy { $0.scope == identity.sessionScope })
  #expect(events.allSatisfy { $0.epoch == expectedEpoch })
  #expect(
    events.map(\.kind.rawValue) == [
      "agent.conversation",
      "agent.tool_call",
      "agent.attention",
      "agent.usage",
      "agent.completion",
    ])
  #expect(events.contains { $0.eventID.rawValue == "conversation-1" } == false)

  let wire = try ProtocolCodec.encode(events)
  let wireText = String(decoding: wire, as: UTF8.self)
  #expect(wireText.contains("do-not-export") == false)
  #expect(wireText.contains("/private") == false)
  #expect(wireText.contains("private prompt") == false)
  #expect(wireText.contains("secret") == false)

  guard case .conversation(let conversation) = events[0].payload else {
    Issue.record("Expected a conversation payload.")
    return
  }
  #expect(conversation.role == .assistant)
  #expect(conversation.text == "hello")
  #expect(conversation.isDelta)

  guard case .toolCall(let toolCall) = events[1].payload else {
    Issue.record("Expected a tool-call payload.")
    return
  }
  #expect(toolCall.name == "search")
  #expect(toolCall.status == .running)
  #expect(toolCall.toolID != "call-1")

  guard case .attention(let attention) = events[2].payload else {
    Issue.record("Expected an attention payload.")
    return
  }
  #expect(attention.kind == .approval)
  #expect(attention.requestID != "ask-1")

  guard case .usage(let usage) = events[3].payload else {
    Issue.record("Expected a usage payload.")
    return
  }
  #expect(usage.inputTokens == 3)
  #expect(usage.outputTokens == 4)
  #expect(usage.totalTokens == 7)
}

@Test
func h05PreservesProjectOwnedScopeAndStartingRevision() throws {
  let identity = try h05Identity(worktree: nil)
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(2),
    startingRevision: Revision(40)
  )

  let events = try normalizer.append(
    h05Data(#"{"type":"text","event_id":"one","delta":"ok"}"# + "\n"))
  let expectedEpoch = try SessionEpoch(2)
  #expect(events.count == 1)
  #expect(events[0].scope == identity.sessionScope)
  #expect(events[0].scope.worktreeID == nil)
  #expect(events[0].scope.sessionID == identity.sessionID)
  #expect(events[0].revision == Revision(41))
  #expect(events[0].epoch == expectedEpoch)
}

@Test
func h05BuffersSplitJSONAndUTF8ChunksUntilTheRecordIsComplete() throws {
  let identity = try h05Identity()
  let complete = h05Data(
    #"{"type":"text","event_id":"partial","delta":"こんにちは"}"# + "\n"
  )
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  var events: [ClairV2AgentNormalizedEvent] = []

  for byte in complete {
    events.append(contentsOf: try normalizer.append(Data([byte])))
  }

  #expect(events.count == 1)
  #expect(normalizer.hasPartialRecord == false)
  guard case .conversation(let conversation) = events[0].payload else {
    Issue.record("Expected a conversation payload after split chunks.")
    return
  }
  #expect(conversation.text == "こんにちは")
  #expect(try normalizer.finish().isEmpty)
}

@Test
func h05SupportsSSEMetadataAndDoneSentinel() throws {
  let identity = try h05Identity()
  let input = h05Data(
    "id: provider-1\n"
      + "event: message\n"
      + "data: {\"type\":\"text\",\"delta\":\"hi\"}\n"
      + "data: [DONE]\n"
  )
  let events = try ClairV2OpenCodeStreamNormalizer.normalize(
    stdout: input,
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  #expect(events.count == 2)
  #expect(events.compactMap { $0.revision?.value } == [1, 2])
  #expect(events.last?.kind.rawValue == "agent.completion")
}

@Test
func h05AcceptsBatchedRecordsLargerThanThePerRecordFrameBound() throws {
  let identity = try h05Identity()
  let limits = try ClairV2AgentEventStreamLimits(
    frameLimits: try FrameLimits(maximumPayloadBytes: 96),
    maximumInputBytes: 512,
    maximumEvents: 16,
    maximumTextBytes: 16,
    maximumIdentifierBytes: 16
  )
  let input = (1...4).map { index in
    #"{"type":"text","event_id":"batch-\#(index)","delta":"ok"}"# + "\n"
  }.joined()
  #expect(Data(input.utf8).count > limits.frameLimits.maximumPayloadBytes)

  let events = try ClairV2OpenCodeStreamNormalizer.normalize(
    stdout: Data(input.utf8),
    identity: identity,
    epoch: try SessionEpoch(1),
    limits: limits
  )
  #expect(events.count == 4)
  #expect(events.compactMap { $0.revision?.value } == [1, 2, 3, 4])
}

@Test
func h05DeduplicatesIdenticalEventsAndRejectsConflictingReuse() throws {
  let identity = try h05Identity()
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  let first = h05Data(#"{"type":"text","event_id":"same","delta":"hello"}"# + "\n")
  #expect(try normalizer.append(first).count == 1)
  #expect(try normalizer.append(first).isEmpty)
  #expect(normalizer.revision == Revision(1))

  let conflict = h05Data(#"{"type":"text","event_id":"same","delta":"changed"}"# + "\n")
  #expect(throws: ClairV2AgentStreamError.conflictingDuplicate) {
    try normalizer.append(conflict)
  }
}

@Test
func h05DeduplicatesIdenticalRecordsWithoutProviderIDs() throws {
  let identity = try h05Identity()
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  let record = h05Data(#"{"type":"text","delta":"same"}"# + "\n")
  #expect(try normalizer.append(record).count == 1)
  #expect(try normalizer.append(record).isEmpty)
  #expect(normalizer.revision == Revision(1))
}

@Test
func h05OrdersCompletionAfterUsageEvenWhenProviderReversesThem() throws {
  let identity = try h05Identity()
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  let completion = h05Data(#"{"type":"session.idle","event_id":"complete"}"# + "\n")
  let usage = h05Data(
    #"{"type":"usage","event_id":"usage","usage":{"input_tokens":8,"output_tokens":2}}"# + "\n")

  #expect(try normalizer.append(completion).isEmpty)
  let events = try normalizer.append(usage)
  #expect(events.map(\.kind.rawValue) == ["agent.usage", "agent.completion"])
  #expect(events.compactMap { $0.revision?.value } == [1, 2])
  #expect(try normalizer.finish().isEmpty)
}

@Test
func h05PreservesNonTerminalSemanticOrderAroundUsage() throws {
  let identity = try h05Identity()
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  let input = h05Data(
    #"{"type":"message.part.updated","event_id":"part-usage","part":{"type":"text","role":"assistant","text":"first","tokens":{"input":1,"output":2}}}"#
      + "\n"
  )

  let events = try normalizer.append(input)
  #expect(events.map(\.kind.rawValue) == ["agent.conversation", "agent.usage"])
  #expect(events.compactMap { $0.revision?.value } == [1, 2])
}

@Test
func h05MapsOpenCodeSessionStatusOnlyWhenItBecomesTerminal() throws {
  let identity = try h05Identity()
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  let busy = h05Data(
    #"{"type":"session.status","event_id":"busy","status":{"type":"busy"}}"# + "\n"
  )
  let idle = h05Data(
    #"{"type":"session.status","event_id":"idle","status":{"type":"idle"}}"# + "\n"
  )
  #expect(try normalizer.append(busy).isEmpty)
  #expect(try normalizer.append(idle).isEmpty)
  #expect(try normalizer.finish().count == 1)
}

@Test
func h05EmitsCompletionAtFinishWhenUsageIsAbsentAndRejectsPostCompletionEvents() throws {
  let identity = try h05Identity()
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  #expect(try normalizer.append(h05Data(#"{"type":"done","event_id":"done"}"# + "\n")).isEmpty)
  let completion = try normalizer.finish()
  #expect(completion.count == 1)
  #expect(completion[0].kind.rawValue == "agent.completion")
  #expect(throws: ClairV2AgentStreamError.streamFinished) {
    try normalizer.append(h05Data(#"{"type":"text","delta":"late"}"# + "\n"))
  }
}

@Test
func h05RejectsARecognizedEventAfterPublishedCompletion() throws {
  let identity = try h05Identity()
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  _ = try normalizer.append(
    h05Data(#"{"type":"usage","event_id":"usage","usage":{"total_tokens":1}}"# + "\n"))
  _ = try normalizer.append(h05Data(#"{"type":"done","event_id":"done"}"# + "\n"))
  #expect(throws: ClairV2AgentStreamError.eventAfterCompletion) {
    try normalizer.append(h05Data(#"{"type":"text","delta":"late"}"# + "\n"))
  }
}

@Test
func h05IgnoresUnknownEventsWithoutRevisionOrPayloadRetention() throws {
  let identity = try h05Identity()
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  let events = try normalizer.append(
    h05Data(
      #"{"type":"future.provider.event","secret":"credential-value","path":"/repo","prompt":"private"}"#
        + "\n"
    )
  )
  #expect(events.isEmpty)
  #expect(normalizer.revision == .zero)
  #expect(normalizer.unknownEventCount == 1)
}

@Test
func h05DropsUnknownTypeSubstringAndSuffixVariants() throws {
  let identity = try h05Identity()
  var normalizer = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  let input =
    [
      #"{"type":"future.completed","secret":"credential-value"}"#,
      #"{"type":"future.message.completed","status":"done"}"#,
      #"{"type":"future.tool","name":"private-tool"}"#,
      #"{"type":"future.text.delta","delta":"private text"}"#,
      #"{"type":"future.permission.asked","permission_id":"private-request"}"#,
      #"{"type":"future.usage","usage":{"input_tokens":1}}"#,
    ].joined(separator: "\n") + "\n"

  let events = try normalizer.append(h05Data(input))
  #expect(events.isEmpty)
  #expect(normalizer.revision == .zero)
  #expect(normalizer.unknownEventCount == 6)
  #expect(try normalizer.finish().isEmpty)
  let wire = try ProtocolCodec.encode(events)
  let wireText = String(decoding: wire, as: UTF8.self)
  #expect(wireText.contains("credential-value") == false)
  #expect(wireText.contains("private text") == false)
}

@Test
func h05RejectsMalformedAndIncompleteInput() throws {
  let identity = try h05Identity()
  var malformed = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  #expect(throws: ProtocolError.malformedPayload) {
    try malformed.append(h05Data("{not-json}\n"))
  }
  #expect(throws: ClairV2AgentStreamError.streamFailed) {
    try malformed.append(h05Data(#"{"type":"text","delta":"after-failure"}"# + "\n"))
  }

  var scalar = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  #expect(throws: ProtocolError.malformedPayload) {
    try scalar.append(h05Data("[1]\n"))
  }

  var invalidUTF8 = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  #expect(throws: ProtocolError.malformedPayload) {
    try invalidUTF8.append(Data([0x7B, 0xFF, 0x7D, 0x0A]))
  }

  var incomplete = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  _ = try incomplete.append(h05Data(#"{"type":"text","delta":"unfinished"}"#))
  #expect(throws: ProtocolError.truncatedFrame) {
    try incomplete.finish()
  }

  var emptyUsage = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  #expect(throws: ClairV2AgentStreamError.invalidEventField) {
    try emptyUsage.append(h05Data(#"{"type":"usage","usage":{}}"# + "\n"))
  }
}

@Test
func h05EnforcesInputRecordTextEventAndProviderBounds() throws {
  let identity = try h05Identity()
  let smallLimits = try ClairV2AgentEventStreamLimits(
    frameLimits: try FrameLimits(maximumPayloadBytes: 32),
    maximumInputBytes: 64,
    maximumEvents: 1,
    maximumTextBytes: 8,
    maximumIdentifierBytes: 8
  )

  var recordBound = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1),
    limits: smallLimits
  )
  #expect(throws: ProtocolError.frameTooLarge(41)) {
    try recordBound.append(Data(repeating: 0x20, count: 41))
  }

  var inputBound = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1),
    limits: try ClairV2AgentEventStreamLimits(
      frameLimits: .standard,
      maximumInputBytes: 10,
      maximumEvents: 1,
      maximumTextBytes: 8,
      maximumIdentifierBytes: 8
    )
  )
  #expect(throws: ClairV2AgentStreamError.inputTooLarge) {
    try inputBound.append(Data(repeating: 0x20, count: 11))
  }

  var fieldBound = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1),
    limits: try ClairV2AgentEventStreamLimits(
      frameLimits: .standard,
      maximumInputBytes: 64,
      maximumEvents: 1,
      maximumTextBytes: 8,
      maximumIdentifierBytes: 8
    )
  )
  #expect(throws: ClairV2AgentStreamError.invalidEventField) {
    try fieldBound.append(h05Data(#"{"type":"text","delta":"too-long!"}"# + "\n"))
  }

  var eventBound = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1),
    limits: try ClairV2AgentEventStreamLimits(
      frameLimits: .standard,
      maximumInputBytes: 256,
      maximumEvents: 1,
      maximumTextBytes: 8,
      maximumIdentifierBytes: 8
    )
  )
  _ = try eventBound.append(h05Data(#"{"type":"text","event_id":"one","delta":"one"}"# + "\n"))
  #expect(throws: ClairV2AgentStreamError.eventLimitExceeded) {
    try eventBound.append(h05Data(#"{"type":"text","event_id":"two","delta":"two"}"# + "\n"))
  }

  var truncatedOutput = ClairV2OpenCodeStreamNormalizer(
    identity: identity,
    epoch: try SessionEpoch(1)
  )
  #expect(throws: ClairV2AgentStreamError.providerOutputTruncated) {
    try truncatedOutput.append(
      rawOutput: ClairV2AgentRawOutput(stdout: h05Data("{}\n"), isTruncated: true)
    )
  }
}

@Test
func h05ValidatesStreamLimitsWhenDecodedFromJSON() throws {
  let valid = try ClairV2AgentEventStreamLimits(
    frameLimits: try FrameLimits(maximumPayloadBytes: 128),
    maximumInputBytes: 256,
    maximumEvents: 4,
    maximumTextBytes: 32,
    maximumIdentifierBytes: 16
  )
  let encoded = try JSONEncoder().encode(valid)
  #expect(try JSONDecoder().decode(ClairV2AgentEventStreamLimits.self, from: encoded) == valid)

  let oversizedEvents = Data(
    """
    {"frame_limits":{"maximum_payload_bytes":128},"maximum_input_bytes":256,"maximum_events":\(ClairV2AgentEventStreamLimits.hardMaximumEvents + 1),"maximum_text_bytes":32,"maximum_identifier_bytes":16}
    """.utf8
  )
  #expect(throws: ClairV2AgentStreamError.invalidLimits) {
    try JSONDecoder().decode(ClairV2AgentEventStreamLimits.self, from: oversizedEvents)
  }

  let oversizedInput = Data(
    """
    {"frame_limits":{"maximum_payload_bytes":128},"maximum_input_bytes":\(ClairV2AgentEventStreamLimits.hardMaximumInputBytes + 1),"maximum_events":4,"maximum_text_bytes":32,"maximum_identifier_bytes":16}
    """.utf8
  )
  #expect(throws: ClairV2AgentStreamError.invalidLimits) {
    try JSONDecoder().decode(ClairV2AgentEventStreamLimits.self, from: oversizedInput)
  }
}

@Test
func h05ProducesStableWireOutputForTheSameInput() throws {
  let identity = try h05Identity()
  let input = h05Data(
    #"{"type":"text","event_id":"stable","delta":"same"}"# + "\n"
      + #"{"type":"usage","event_id":"usage","usage":{"input_tokens":1,"output_tokens":2}}"# + "\n"
      + #"{"type":"done","event_id":"done"}"# + "\n"
  )
  let first = try ClairV2OpenCodeStreamNormalizer.normalize(
    stdout: input,
    identity: identity,
    epoch: try SessionEpoch(3),
    startingRevision: Revision(9)
  )
  let second = try ClairV2OpenCodeStreamNormalizer.normalize(
    stdout: input,
    identity: identity,
    epoch: try SessionEpoch(3),
    startingRevision: Revision(9)
  )
  #expect(first == second)
  let firstWire = try ProtocolCodec.encode(first)
  let secondWire = try ProtocolCodec.encode(second)
  #expect(firstWire == secondWire)
}

import Foundation
import XCTest

@testable import ClairApp

final class AgentActivityTests: XCTestCase {
  func testSourcesAndKindsKeepBellExitAndOfficialHookDistinct() {
    let projectID = UUID()
    let sessionID = UUID()
    let bell = AgentActivity.bell(projectID: projectID, sessionID: sessionID)
    let success = AgentActivity.exit(
      projectID: projectID,
      sessionID: sessionID,
      status: 0
    )
    let failure = AgentActivity.exit(
      projectID: projectID,
      sessionID: sessionID,
      status: 7
    )
    let hook = AgentActivity.officialHook(
      projectID: projectID,
      sessionID: sessionID,
      kind: .attention
    )

    XCTAssertEqual(bell.source, .bell)
    XCTAssertEqual(bell.kind, .attention)
    XCTAssertEqual(success.source, .exit)
    XCTAssertEqual(success.kind, .completed)
    XCTAssertEqual(success.exitStatus, 0)
    XCTAssertEqual(failure.kind, .failed)
    XCTAssertEqual(failure.exitStatus, 7)
    XCTAssertEqual(hook.source, .officialHook)
    XCTAssertEqual(hook.kind, .attention)
  }

  func testHistoryIsCodableAndCanBeQueriedByProjectAndSessionScope() throws {
    let firstProject = UUID()
    let secondProject = UUID()
    let firstSession = UUID()
    let secondSession = UUID()
    let history = AgentActivityHistory(activities: [
      AgentActivity.bell(
        projectID: firstProject,
        sessionID: firstSession,
        occurredAt: Date(timeIntervalSince1970: 1)
      ),
      AgentActivity.exit(
        projectID: firstProject,
        sessionID: secondSession,
        status: 0,
        occurredAt: Date(timeIntervalSince1970: 2)
      ),
      AgentActivity.officialHook(
        projectID: firstProject,
        kind: .started,
        occurredAt: Date(timeIntervalSince1970: 3)
      ),
      AgentActivity.exit(
        projectID: secondProject,
        sessionID: firstSession,
        status: 1,
        occurredAt: Date(timeIntervalSince1970: 4)
      ),
    ])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let restored = try decoder.decode(
      AgentActivityHistory.self,
      from: encoder.encode(history)
    )

    XCTAssertEqual(restored, history)
    XCTAssertEqual(restored.entries(forProject: firstProject).count, 3)
    XCTAssertEqual(
      restored.entries(
        for: AgentActivityScope(projectID: firstProject, sessionID: firstSession)
      ).count,
      1
    )
    XCTAssertEqual(
      restored.entries(forSession: secondSession, in: firstProject).count,
      1
    )
  }

  func testStorePersistsVersionedSnapshotAtomicallyAndPreservesMuteState() throws {
    let fixture = try Fixture()
    let projectID = UUID()
    let sessionID = UUID()
    let store = AgentActivityStore(
      fileURL: fixture.fileURL,
      maximumActivityCount: 10
    )
    let activity = AgentActivity.bell(
      projectID: projectID,
      sessionID: sessionID,
      occurredAt: Date(timeIntervalSince1970: 1)
    )

    XCTAssertEqual(try store.load(), .empty)
    _ = try store.append(activity)
    _ = try store.setMuted(true, projectID: projectID, sessionID: sessionID)

    let restored = try store.load()
    XCTAssertEqual(restored.schemaVersion, AgentActivityStoreSnapshot.currentSchemaVersion)
    XCTAssertEqual(restored.activities, [activity])
    XCTAssertEqual(
      AgentActivityLedger(snapshot: restored).muteState(
        projectID: projectID,
        sessionID: sessionID
      )?.isMuted,
      true
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
  }

  func testStoreRejectsUnsupportedVersionAndMalformedJSON() throws {
    let fixture = try Fixture()
    let store = AgentActivityStore(fileURL: fixture.fileURL)

    try Data(#"{"schemaVersion":99,"history":{"activities":[]},"muteStates":[]}"#.utf8)
      .write(to: fixture.fileURL)
    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? AgentActivityStoreError, .unsupportedStoreVersion(99))
    }

    try Data("not-json".utf8).write(to: fixture.fileURL)
    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? AgentActivityStoreError, .malformedStore)
    }
  }

  func testProjectMuteCoversSessionsButSessionUnmuteDoesNotBypassProjectMute() throws {
    let projectID = UUID()
    let firstSession = UUID()
    let secondSession = UUID()
    var ledger = AgentActivityLedger()

    ledger.setMuted(true, projectID: projectID)
    XCTAssertTrue(ledger.isMuted(projectID: projectID, sessionID: firstSession))
    XCTAssertTrue(ledger.isMuted(projectID: projectID, sessionID: secondSession))

    ledger.setMuted(false, projectID: projectID, sessionID: firstSession)
    XCTAssertTrue(ledger.isMuted(projectID: projectID, sessionID: firstSession))

    ledger.setMuted(false, projectID: projectID)
    XCTAssertFalse(ledger.isMuted(projectID: projectID, sessionID: firstSession))
    XCTAssertFalse(ledger.isMuted(projectID: projectID, sessionID: secondSession))

    ledger.setMuted(true, projectID: projectID, sessionID: firstSession)
    XCTAssertTrue(ledger.isMuted(projectID: projectID, sessionID: firstSession))
    XCTAssertFalse(ledger.isMuted(projectID: projectID, sessionID: secondSession))
  }

  func testStoreKeepsOnlyNewestActivitiesWithinConfiguredBound() throws {
    let fixture = try Fixture()
    let projectID = UUID()
    let store = AgentActivityStore(
      fileURL: fixture.fileURL,
      maximumActivityCount: 2
    )
    let first = AgentActivity.bell(projectID: projectID, occurredAt: Date(timeIntervalSince1970: 1))
    let second = AgentActivity.exit(
      projectID: projectID,
      status: 0,
      occurredAt: Date(timeIntervalSince1970: 2)
    )
    let third = AgentActivity.exit(
      projectID: projectID,
      status: 1,
      occurredAt: Date(timeIntervalSince1970: 3)
    )

    _ = try store.append(first)
    _ = try store.append(second)
    _ = try store.append(third)

    let restored = try store.load()
    XCTAssertEqual(restored.activities, [second, third])
    XCTAssertEqual(restored.activities.count, 2)
  }

  func testLoadingOversizedHistoryIsNormalizedToBound() throws {
    let fixture = try Fixture()
    let projectID = UUID()
    let store = AgentActivityStore(fileURL: fixture.fileURL, maximumActivityCount: 2)
    let snapshot = AgentActivityStoreSnapshot(
      history: AgentActivityHistory(
        activities: (0..<5).map { index in
          AgentActivity.bell(
            id: UUID(),
            projectID: projectID,
            occurredAt: Date(timeIntervalSince1970: TimeInterval(index))
          )
        })
    )

    try store.save(snapshot)

    XCTAssertEqual(try store.load().activities.count, 2)
    XCTAssertEqual(
      try store.load().activities.map(\.occurredAt),
      [Date(timeIntervalSince1970: 3), Date(timeIntervalSince1970: 4)]
    )
  }

  func testOfficialHookDecoderAcceptsKnownEventsWithoutRetainingRawBody() throws {
    let projectID = UUID()
    let sessionID = UUID()
    let receivedAt = Date(timeIntervalSince1970: 100)
    let decoder = OfficialHookDecoder()
    let data = Data(
      #"{"hook_event_name":"Notification","message":"permission requested","secret_field":"do not persist"}"#
        .utf8
    )

    let activity = try XCTUnwrap(
      decoder.decode(
        data,
        projectID: projectID,
        sessionID: sessionID,
        receivedAt: receivedAt
      )
    )

    XCTAssertEqual(activity.source, .officialHook)
    XCTAssertEqual(activity.kind, .notification)
    XCTAssertEqual(activity.scope, AgentActivityScope(projectID: projectID, sessionID: sessionID))
    XCTAssertEqual(activity.occurredAt, receivedAt)
    XCTAssertEqual(activity.summary, "permission requested")
    let encoded = try JSONEncoder().encode(activity)
    let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
    XCTAssertFalse(encodedText.contains("do not persist"))
  }

  func testOfficialHookDecoderDropsUnknownEventsAndRedactsSecretLookingBody() throws {
    let projectID = UUID()
    let decoder = OfficialHookDecoder()
    let unknown = Data(
      #"{"hook_event_name":"FutureVendorEvent","message":"unknown details"}"#.utf8
    )
    XCTAssertNil(try decoder.decode(unknown, projectID: projectID))

    let secret = Data(
      #"{"hook_event_name":"Notification","message":"api_key=super-secret-value"}"#.utf8
    )
    let activity = try XCTUnwrap(try decoder.decode(secret, projectID: projectID))
    XCTAssertEqual(activity.kind, .notification)
    XCTAssertNil(activity.summary)
    XCTAssertFalse(
      String(data: try JSONEncoder().encode(activity), encoding: .utf8)!.contains("super-secret"))
  }

  func testOfficialHookDecoderNormalizesControlCharactersBeforePersistingSummary() throws {
    let decoder = OfficialHookDecoder()
    let data = Data(
      #"{"hook_event_name":"Notification","message":"\u001b[31mpermission\nrequested"}"#.utf8
    )

    let activity = try XCTUnwrap(try decoder.decode(data, projectID: UUID()))

    XCTAssertEqual(activity.summary, "[31mpermission requested")
  }

  func testOfficialHookDecoderBoundsSummaryAndRejectsOversizedPayload() throws {
    let projectID = UUID()
    let decoder = OfficialHookDecoder(maximumPayloadBytes: 1_024, maximumSummaryBytes: 12)
    let longMessage = String(repeating: "あ", count: 100)
    let data = try JSONSerialization.data(withJSONObject: [
      "hook_event_name": "Stop",
      "message": longMessage,
    ])
    let activity = try XCTUnwrap(try decoder.decode(data, projectID: projectID))
    XCTAssertLessThanOrEqual(activity.summary?.utf8.count ?? 0, 12)

    let oversized = Data(repeating: 0x20, count: 1_025)
    XCTAssertThrowsError(try decoder.decode(oversized, projectID: projectID)) { error in
      XCTAssertEqual(error as? OfficialHookDecoderError, .payloadTooLarge(1_025))
    }
  }

  func testNotificationDispatcherHonorsMuteAndUsesProtocolSink() {
    let notifier = TestNotifier()
    let dispatcher = AgentActivityNotificationDispatcher(notifier: notifier)
    let activity = AgentActivity.bell(projectID: UUID())

    XCTAssertFalse(dispatcher.notifyIfNeeded(activity, isMuted: true))
    XCTAssertTrue(notifier.activities.isEmpty)
    XCTAssertTrue(dispatcher.notifyIfNeeded(activity, isMuted: false))
    XCTAssertEqual(notifier.activities, [activity])
  }

  private final class TestNotifier: AgentActivityNotifier, @unchecked Sendable {
    private(set) var activities: [AgentActivity] = []

    func notify(activity: AgentActivity) {
      activities.append(activity)
    }
  }

  private final class Fixture {
    let directory: URL
    let fileURL: URL

    init() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("clair-agent-activity-\(UUID().uuidString)", isDirectory: true)
      fileURL = directory.appendingPathComponent("activity-v1.json", isDirectory: false)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    }

    deinit {
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

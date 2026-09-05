import Foundation
import XCTest

@testable import ClairApp

final class AgentRateLimitTests: XCTestCase {
  func testParsesCodexPrimaryAndSecondaryWindows() throws {
    let response = Data(
      #"{"id":1,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":54,"windowDurationMins":300,"resetsAt":2000},"secondary":{"usedPercent":57,"windowDurationMins":10080,"resetsAt":3000},"planType":"plus"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":54,"windowDurationMins":300,"resetsAt":2000},"secondary":{"usedPercent":57,"windowDurationMins":10080,"resetsAt":3000},"planType":"plus"}}}}"#
        .utf8
    )
    let fetchedAt = Date(timeIntervalSince1970: 1_000)

    let snapshots = try CodexRateLimitResponseParser.parse(response, fetchedAt: fetchedAt)

    let snapshot = try XCTUnwrap(snapshots.first)
    XCTAssertEqual(snapshots.count, 1)
    XCTAssertEqual(snapshot.id, "codex")
    XCTAssertEqual(snapshot.displayName, "Codex")
    XCTAssertEqual(snapshot.planType, "plus")
    XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
    XCTAssertEqual(snapshot.windows.map(\.displayName), ["5時間", "7日間"])
    XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [46, 43])
  }

  func testPrefersMultiBucketResponseAndClampsPercentages() throws {
    let response = Data(
      #"{"id":1,"result":{"rateLimits":{"limitId":"legacy","primary":{"usedPercent":50,"windowDurationMins":60,"resetsAt":2000}},"rateLimitsByLimitId":{"other":{"limitId":"other","limitName":"Other model","primary":{"usedPercent":120,"windowDurationMins":60,"resetsAt":2000}},"codex":{"limitId":"codex","primary":{"usedPercent":-5,"windowDurationMins":300,"resetsAt":3000}}}}}"#
        .utf8
    )

    let snapshots = try CodexRateLimitResponseParser.parse(response)

    XCTAssertEqual(snapshots.map(\.id), ["codex", "other"])
    XCTAssertEqual(snapshots[0].primaryWindow?.usedPercent, 0)
    XCTAssertEqual(snapshots[0].primaryWindow?.remainingPercent, 100)
    XCTAssertEqual(snapshots[1].displayName, "Other model")
    XCTAssertEqual(snapshots[1].primaryWindow?.usedPercent, 100)
    XCTAssertEqual(snapshots[1].primaryWindow?.remainingPercent, 0)
  }

  func testSurfacesAppServerRequestError() {
    let response = Data(
      #"{"id":1,"error":{"code":-32000,"message":"Login required"}}"#.utf8
    )

    XCTAssertThrowsError(try CodexRateLimitResponseParser.parse(response)) { error in
      XCTAssertEqual(error as? AgentRateLimitError, .requestFailed("Login required"))
    }
  }

  func testResetDescriptionUsesLargestUsefulUnits() {
    let now = Date(timeIntervalSince1970: 1_000)
    let window = AgentRateLimitWindow(
      usedPercent: 25,
      durationMinutes: 300,
      resetsAt: now.addingTimeInterval(7_440)
    )

    XCTAssertEqual(window.resetDescription(relativeTo: now), "リセットまで 2時間4分")
  }

  func testParsesClaudeSubscriptionUsage() throws {
    let now = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-09-05T12:00:00Z")
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let output = """
      You are currently using your subscription to power your Claude Code usage
      Current session: 61% used · resets 2:30pm (UTC)
      Current week (all models): 47% used · resets Sep 9 at 2:30pm (UTC)
      """

    let snapshot = ClaudeRateLimitResponseParser.parse(
      output,
      fetchedAt: now,
      calendar: calendar
    )

    XCTAssertEqual(snapshot.id, "claude-code")
    XCTAssertEqual(snapshot.planType, "Claude.ai")
    XCTAssertNil(snapshot.detail)
    XCTAssertEqual(snapshot.windows.map(\.usedPercent), [61, 47])
    XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [39, 53])
    XCTAssertEqual(
      snapshot.windows.map { $0.resetsAt.timeIntervalSince1970 },
      [1_788_618_600, 1_788_964_200]
    )
  }

  func testClaudeAPIUsageHasInformativeEmptySnapshot() {
    let snapshot = ClaudeRateLimitResponseParser.parse("Total cost: $0.0000")

    XCTAssertEqual(snapshot.planType, "API課金")
    XCTAssertTrue(snapshot.windows.isEmpty)
    XCTAssertEqual(snapshot.detail, "サブスクリプションのレート制限はありません")
  }

  func testParsesOpenCodeGoUsage() throws {
    let response = Data(
      #"{"usage":{"rolling":{"status":"ok","percent":16,"resetsAt":"2026-09-05T11:09:48.068Z"},"weekly":{"status":"ok","percent":22,"resetsAt":"2026-09-07T00:00:00.068Z"},"monthly":{"status":"ok","percent":40,"resetsAt":"2026-09-30T16:27:20.068Z"}}}"#
        .utf8
    )

    let snapshot = try OpenCodeRateLimitResponseParser.parse(response)

    XCTAssertEqual(snapshot.id, "opencode")
    XCTAssertEqual(snapshot.planType, "Go")
    XCTAssertEqual(snapshot.windows.map(\.displayName), ["5時間", "7日間", "30日間"])
    XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [84, 78, 60])
  }
}

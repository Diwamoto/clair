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

  func testParsesClaudeStatusLineUsage() throws {
    let date = Date(timeIntervalSince1970: 1000)
    let data = Data(
      #"{"five_hour":{"used_percentage":61,"resets_at":1788618600},"seven_day":{"used_percentage":47,"resets_at":1788964200},"future_field":null}"#
        .utf8)
    let snapshot = try ClaudeRateLimitResponseParser.parse(data, fetchedAt: date)
    XCTAssertEqual(snapshot.windows.map(\.usedPercent), [61, 47])
    XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [39, 53])
    XCTAssertEqual(
      snapshot.windows.map { $0.resetsAt.timeIntervalSince1970 },
      [1_788_618_600, 1_788_964_200])
    XCTAssertEqual(snapshot.fetchedAt, date)
    XCTAssertNotNil(snapshot.detail)
  }

  func testClaudeMissingCacheIsUnknownInsteadOfAPIPlan() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let snapshot = try ClaudeRateLimitCache.fetch(fileURL: url)
    XCTAssertNil(snapshot.planType)
    XCTAssertTrue(snapshot.windows.isEmpty)
    XCTAssertTrue(snapshot.detail?.contains("未取得") == true)
  }

  func testClaudeNullWindowAndMalformedPayload() throws {
    let data = Data(#"{"five_hour":null,"seven_day":{"used_percentage":0,"resets_at":2000}}"#.utf8)
    let snapshot = try ClaudeRateLimitResponseParser.parse(data, fetchedAt: .distantPast)
    XCTAssertEqual(snapshot.windows.map(\.durationMinutes), [10_080])
    for invalid in ["{}", "null", "not json", #"{"five_hour":{"used_percentage":50}}"#] {
      XCTAssertThrowsError(
        try ClaudeRateLimitResponseParser.parse(Data(invalid.utf8), fetchedAt: .now))
    }
  }

  func testClaudeCacheKeepsObservationTime() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"{"five_hour":{"used_percentage":25,"resets_at":2000}}"#.utf8).write(to: url)
    let date = Date(timeIntervalSince1970: 1000)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    XCTAssertEqual(try ClaudeRateLimitCache.fetch(fileURL: url).fetchedAt, date)
  }

  func testClaudeStatusLinePreservesLocalCommandAndUserOptions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let user = root.appendingPathComponent("user")
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try Data(#"{"statusLine":{"type":"command","command":"echo user","padding":2}}"#.utf8)
      .write(to: user.appendingPathComponent("settings.json"))
    let original = "printf '%s' \"local $HOME\""
    try JSONSerialization.data(withJSONObject: ["statusLine": ["command": original]])
      .write(to: project.appendingPathComponent(".claude/settings.local.json"))
    let argument = try ClaudeRateLimitCache.settingsArgument(
      projectRoot: project,
      receiver: root.appendingPathComponent("receiver's script.sh"),
      cache: root.appendingPathComponent("cache.json"), userDirectory: user)
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "set --" + argument + "; printf '%s' \"$2\""]
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let status = try XCTUnwrap(object["statusLine"] as? [String: Any])
    XCTAssertEqual(status["padding"] as? Int, 2)
    XCTAssertTrue(
      (status["command"] as? String)?.contains(AgentLaunchCommand.shellQuote(original)) == true)
    XCTAssertFalse(argument.contains("echo user"))
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

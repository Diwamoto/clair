#if os(macOS)
  import Foundation
  import XCTest

  @testable import ClairAppKit

  final class ProviderQuotaTests: XCTestCase {
    // Recorded from `codex app-server` 0.155 on 2026-09-23.
    let live =
      #"{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":85,"windowDurationMins":300,"resetsAt":1790111980},"secondary":{"usedPercent":76,"windowDurationMins":10080,"resetsAt":1790608726},"planType":"plus"}}}"#

    func testParsesCodexWindows() throws {
      let state = try XCTUnwrap(ProviderQuota.parseCodex(Data(live.utf8)))
      guard case .ok(let w) = state else { return XCTFail("\(state)") }
      XCTAssertEqual(w.map(\.label), ["5時間", "7日間"])
      XCTAssertEqual(w.map(\.remainingPercent), [15, 24])
      XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1_790_111_980))
    }

    func testIgnoresOtherLinesAndReportsErrorsAndMissingLimits() {
      XCTAssertNil(ProviderQuota.parseCodex(Data(#"{"id":0,"result":{}}"#.utf8)))
      XCTAssertNil(
        ProviderQuota.parseCodex(Data(#"{"method":"remoteControl/status/changed"}"#.utf8)))
      XCTAssertNil(ProviderQuota.parseCodex(Data("zsh: login banner".utf8)))
      XCTAssertEqual(
        ProviderQuota.parseCodex(Data(#"{"id":1,"error":{"message":"not logged in"}}"#.utf8)),
        .unavailable("not logged in"))
      guard
        case .unavailable? = ProviderQuota.parseCodex(
          Data(#"{"id":1,"result":{"rateLimits":null}}"#.utf8))
      else {
        return XCTFail("missing limits must not read as a number")
      }
    }

    func testTightestWindowSkipsProvidersWithoutNumbers() {
      let now = Date(timeIntervalSince1970: 1_790_100_000)
      let q = [
        ProviderQuota(
          provider: "Codex", state: ProviderQuota.parseCodex(Data(live.utf8))!, fetchedAt: now),
        ProviderQuota(
          provider: "Claude Code", state: .unsupported("statusLine hook 未接続"), fetchedAt: now),
      ]
      let top = ProviderQuota.tightest(q)
      XCTAssertEqual(top?.provider, "Codex")
      XCTAssertEqual(top?.window.minutes, 300)
      XCTAssertNil(ProviderQuota.tightest([q[1]]))
      XCTAssertTrue(q[0].summary(now: now).contains("5時間 残り15% · リセットまで 3時間19分"))
      XCTAssertEqual(q[1].summary(now: now), "Claude Code: 未対応 — statusLine hook 未接続")
      XCTAssertFalse(q[0].isStale(now: now))
      XCTAssertTrue(q[0].summary(now: now.addingTimeInterval(601)).contains("古い値"))
    }

    func testParsesOpenCodeGoWindows() {
      // Recorded from opencode.ai/zen/go/v1/usage on 2026-09-23.
      let body =
        #"{"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"2026-09-23T10:59:34.091Z"},"weekly":{"status":"ok","percent":0,"resetsAt":"2026-09-28T00:00:00.000Z"},"monthly":{"status":"ok","percent":76,"resetsAt":"2026-09-30T16:27:14.000Z"}}}"#
      guard case .ok(let w) = ProviderQuota.parseOpenCode(Data(body.utf8)) else { return XCTFail() }
      XCTAssertEqual(w.map(\.label), ["5時間", "7日間", "1か月"])
      XCTAssertEqual(w.map(\.remainingPercent), [100, 100, 24])
      XCTAssertEqual(w[0].resetsAt, Date(timeIntervalSince1970: 1_790_161_174.091))
      guard case .unavailable = ProviderQuota.parseOpenCode(Data(#"{"error":{"type":"AuthError"}}"#.utf8)) else {
        return XCTFail("an error body must not read as a number")
      }
    }

    func testParsesClaudeWindows() {
      // Trimmed from api.anthropic.com/api/oauth/usage on 2026-09-23 (microsecond timestamps, many null windows).
      let body =
        #"{"five_hour":{"utilization":56.0,"resets_at":"2026-09-23T09:49:59.731944+00:00","locked_reason":null},"seven_day":{"utilization":14.0,"resets_at":"2026-09-26T00:59:59.731979+00:00"},"seven_day_opus":null,"extra_usage":{"is_enabled":false,"utilization":3.742}}"#
      guard case .ok(let w) = ProviderQuota.parseClaude(Data(body.utf8)) else { return XCTFail() }
      XCTAssertEqual(w.map(\.label), ["5時間", "7日間"])
      XCTAssertEqual(w.map(\.remainingPercent), [44, 86])
      XCTAssertEqual(w[0].resetsAt.timeIntervalSince1970, 1_790_156_999.731, accuracy: 0.001)
      guard case .unavailable = ProviderQuota.parseClaude(Data(#"{"type":"error"}"#.utf8)) else {
        return XCTFail("an error body must not read as a number")
      }
    }

    func testThrottledClaudeIsNotAskedAgainBeforeRetryAfter() async {
      let now = Date(timeIntervalSince1970: 1_790_100_000)
      var held = ProviderQuota(provider: "Claude Code", state: .unavailable("held"), fetchedAt: now)
      held.notBefore = now.addingTimeInterval(60)
      // Returned as-is without touching the Keychain or the network.
      let again = await ProviderQuota.claudeCode(previous: held, now: now.addingTimeInterval(30))
      XCTAssertEqual(again, held)
    }

    /// `CLAIR_LIVE_QUOTA=1`: asks api.anthropic.com with this machine's Claude Code login.
    func testLiveClaude() async throws {
      try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAIR_LIVE_QUOTA"] == "1")
      let q = await ProviderQuota.claudeCode(previous: nil, now: Date())
      print("live claude:", q.state)
      guard case .ok(let w) = q.state else { return XCTFail("\(q.state)") }
      XCTAssertEqual(w.count, 2)
    }

    /// `CLAIR_LIVE_QUOTA=1`: asks opencode.ai with this machine's OpenCode Go key.
    func testLiveOpenCode() async throws {
      try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAIR_LIVE_QUOTA"] == "1")
      let state = await ProviderQuota.openCode()
      print("live opencode:", state)
      guard case .ok(let w) = state else { return XCTFail("\(state)") }
      XCTAssertEqual(w.count, 3)
    }

    /// `CLAIR_LIVE_QUOTA=1`: asks the real Codex CLI on this machine.
    func testLiveCodex() throws {
      try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAIR_LIVE_QUOTA"] == "1")
      let state = ProviderQuota.codex()
      print("live codex:", state)
      guard case .ok(let w) = state else { return XCTFail("\(state)") }
      XCTAssertFalse(w.isEmpty)
    }
  }
#endif

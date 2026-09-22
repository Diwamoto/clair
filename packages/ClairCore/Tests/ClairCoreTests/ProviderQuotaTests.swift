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

import Foundation
import XCTest
@testable import ClairWorkspace

final class AgentHistoryTests: XCTestCase {
  func testClaudeTokenEstimateWithoutCostState() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-claude-cost-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appending(path: ".claude/projects/project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let rows = [
      #"{"type":"user","timestamp":"2026-09-24T02:00:00Z","sessionId":"cc-2","uuid":"u1","message":{"content":"Build it"}}"#,
      #"{"type":"assistant","timestamp":"2026-09-24T02:00:01Z","sessionId":"cc-2","uuid":"a1","message":{"id":"msg1","model":"claude-sonnet-5","content":[{"type":"text","text":"Done"}],"usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":0}}}}"#,
    ]
    try rows.joined(separator: "\n").write(to: project.appending(path: "cc.jsonl"), atomically: true, encoding: .utf8)
    let item = try XCTUnwrap(AgentHistoryReader.load(home: home).first)
    XCTAssertEqual(item.estimatedUSD ?? 0, 0.004145, accuracy: 0.000001)
  }

  func testLiveHistoriesWhenRequested() {
    guard ProcessInfo.processInfo.environment["CLAIR_LIVE_HISTORY"] == "1" else { return }
    let histories = AgentHistoryReader.load()
    for provider in AgentHistory.Provider.allCases {
      let subset = histories.filter { $0.provider == provider }
      print("\(provider.rawValue): \(subset.count) chats, \(subset.map(\.promptCount).reduce(0, +)) prompts")
      XCTAssertFalse(subset.isEmpty)
    }
  }

  func testProviderHistoryAndPromptCalendarIgnoreToolResults() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let codex = home.appending(path: ".codex/sessions/2026/09/24")
    let claude = home.appending(path: ".claude/projects/project")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    let codexRows = [
      #"{"type":"session_meta","timestamp":"2026-09-24T00:00:00Z","payload":{"id":"cx-1"}}"#,
      #"{"type":"turn_context","timestamp":"2026-09-24T00:00:00Z","payload":{"model":"gpt-6-sol"}}"#,
      #"{"type":"response_item","timestamp":"2026-09-24T01:00:00.123Z","payload":{"id":"p1","role":"user","content":[{"type":"input_text","text":"Fix the bug"}]}}"#,
      #"{"type":"response_item","timestamp":"2026-09-24T01:00:01Z","payload":{"id":"a1","role":"assistant","content":[{"type":"output_text","text":"Fixed"}]}}"#,
      #"{"type":"token_usage_record","timestamp":"2026-09-24T01:00:02Z","payload":{"thread_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"cache_write_input_tokens":0,"output_tokens":200}}}"#,
    ]
    try codexRows.joined(separator: "\n").write(to: codex.appending(path: "cx.jsonl"), atomically: true, encoding: .utf8)
    let claudeRows = [
      #"{"type":"user","timestamp":"2026-09-24T02:00:00Z","sessionId":"cc-1","uuid":"u1","message":{"role":"user","content":"Review this"}}"#,
      #"{"type":"user","timestamp":"2026-09-24T02:00:01Z","sessionId":"cc-1","uuid":"tool1","message":{"role":"user","content":[{"type":"tool_result","content":"tool output"}]}}"#,
      #"{"type":"assistant","timestamp":"2026-09-24T02:00:02Z","sessionId":"cc-1","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Reviewed"}]}}"#,
      #"{"type":"cost-state","sessionId":"cc-1","totalCostUSD":0.25}"#,
    ]
    try claudeRows.joined(separator: "\n").write(to: claude.appending(path: "cc.jsonl"), atomically: true, encoding: .utf8)

    let histories = AgentHistoryReader.load(home: home)
    XCTAssertEqual(histories.count, 2)
    XCTAssertEqual(histories.map(\.promptCount).reduce(0, +), 2)
    XCTAssertEqual(histories.first { $0.provider == .codex }?.estimatedUSD ?? 0, 0.00191, accuracy: 0.00001)
    XCTAssertEqual(histories.first { $0.provider == .claude }?.estimatedUSD, 0.25)
    let summary = AgentUsageSummary(histories: histories)
    XCTAssertEqual(summary.days.map(\.prompts), [2])
    XCTAssertTrue(Calendar.current.isDate(summary.days[0].date, inSameDayAs: ISO8601DateFormatter().date(from: "2026-09-24T00:00:00Z")!))
    XCTAssertEqual(summary.sessionsWithoutCost, 0)
  }
}

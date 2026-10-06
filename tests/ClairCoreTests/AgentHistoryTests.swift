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

  func testFormatsClaudeCommandTagsLikeCcedit() {
    XCTAssertEqual(AgentHistoryReader.formatUserText("<command-message>clair-task</command-message>\n<command-name>/clair-task</command-name>\n<command-args>直して</command-args>"), "/clair-task 直して")
    XCTAssertNil(AgentHistoryReader.formatUserText("<local-command-caveat>Caveat: ignore</local-command-caveat>"))
    XCTAssertNil(AgentHistoryReader.formatUserText("<command-name>/clear</command-name><command-args></command-args>"))
    XCTAssertEqual(AgentHistoryReader.formatUserText("Base directory for this skill: /u/.claude/skills/clair-task\n# Clair"), "[Skill loaded: clair-task]")
    XCTAssertEqual(AgentHistoryReader.formatUserText("<bash-input>ls</bash-input>"), "```bash\n$ ls\n```")
    XCTAssertEqual(AgentHistoryReader.formatUserText("<local-command-caveat>x</local-command-caveat>本題"), "本題")
  }

  func testListSkimMatchesFullParse() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-history-skim-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appending(path: ".claude/projects/p")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let rows = [
      #"{"type":"user","timestamp":"2026-09-24T02:00:00Z","sessionId":"s","uuid":"c","message":{"content":"<local-command-caveat>x</local-command-caveat>"}}"#,
      #"{"type":"user","timestamp":"2026-09-24T02:00:01Z","sessionId":"s","uuid":"u1","cwd":"/w/clair","message":{"content":"<command-name>/clair-task</command-name><command-args>go</command-args>"}}"#,
      #"{"type":"assistant","timestamp":"2026-09-24T02:00:02Z","sessionId":"s","uuid":"a1","message":{"model":"claude-sonnet-5","id":"msg_1","content":[{"type":"tool_use","id":"toolu_1","input":{"q":"}{\""}}],"usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":0}}}}"#,
      #"{"type":"user","timestamp":"2026-09-24T02:00:03Z","sessionId":"s","uuid":"t1","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"big"}]}}"#,
      #"{"type":"assistant","timestamp":"2026-09-24T02:00:04Z","sessionId":"s","uuid":"a2","message":{"model":"claude-sonnet-5","id":"msg_1","content":[{"type":"text","text":"Done"}],"usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":0}}}}"#,
    ]
    try rows.joined(separator: "\n").write(to: project.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)
    let list = try XCTUnwrap(AgentHistoryReader.load(home: home).first)
    let full = try XCTUnwrap(AgentHistoryReader.load(home: home, full: true).first)
    XCTAssertEqual(list.title, "/clair-task go")
    XCTAssertEqual(list.estimatedUSD, full.estimatedUSD)
    XCTAssertEqual(list.promptCount, 1)
    XCTAssertEqual(list.messages.last?.text, "Done")
    XCTAssertEqual(list.date, full.date)
    XCTAssertEqual(AgentHistoryReader.transcript(of: list).map(\.text), full.messages.map(\.text))
  }

  func testTranscriptKeepsReadableThinkingSeparateFromText() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-history-thinking-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let claude = home.appending(path: ".claude/projects/p")
    let codex = home.appending(path: ".codex/sessions/2026/09/24")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    try [
      #"{"type":"user","timestamp":"2026-09-24T02:00:00Z","sessionId":"s","uuid":"u1","message":{"content":"Go"}}"#,
      #"{"type":"assistant","timestamp":"2026-09-24T02:00:01Z","sessionId":"s","uuid":"a1","message":{"content":[{"type":"thinking","thinking":"Plan it","signature":"x"},{"type":"text","text":"Done"}]}}"#,
      #"{"type":"assistant","timestamp":"2026-09-24T02:00:02Z","sessionId":"s","uuid":"a2","message":{"content":[{"type":"thinking","thinking":"","signature":"redacted"}]}}"#,
    ].joined(separator: "\n").write(to: claude.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)
    try [
      #"{"type":"session_meta","timestamp":"2026-09-24T00:00:00Z","payload":{"id":"cx"}}"#,
      #"{"type":"response_item","timestamp":"2026-09-24T01:00:00Z","payload":{"id":"p1","role":"user","content":[{"type":"input_text","text":"Fix"}]}}"#,
      #"{"type":"response_item","timestamp":"2026-09-24T01:00:01Z","payload":{"type":"reasoning","id":"r1","summary":[{"type":"summary_text","text":"Look first"}],"encrypted_content":"x"}}"#,
      #"{"type":"response_item","timestamp":"2026-09-24T01:00:02Z","payload":{"id":"a1","role":"assistant","content":[{"type":"output_text","text":"Fixed"}]}}"#,
    ].joined(separator: "\n").write(to: codex.appending(path: "cx.jsonl"), atomically: true, encoding: .utf8)
    let lists = AgentHistoryReader.load(home: home)
    let transcript = { (p: AgentHistory.Provider) in lists.first { $0.provider == p }.map(AgentHistoryReader.transcript(of:))?.map { "\($0.role):\($0.text)" } }
    XCTAssertEqual(transcript(.claude), ["user:Go", "thinking:Plan it", "assistant:Done"])
    XCTAssertEqual(transcript(.codex), ["user:Fix", "thinking:Look first", "assistant:Fixed"])
    XCTAssertFalse(lists.flatMap(\.messages).contains { $0.role == "thinking" }, "the list skim never carries thinking")
  }

  func testChatFoldsProgressBeforeEachRunsReply() {
    let messages = ["user:Go", "thinking:t1", "assistant:Checking", "thinking:t2", "assistant:Done", "user:More", "thinking:t3", "user:Last", "assistant:Only"]
      .enumerated().map { i, s in
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        return AgentHistory.Message(id: "\(i)", role: parts[0], text: parts[1], date: .distantPast)
      }
    let rows = AgentHistory.chatItems(messages).map { item -> String in
      switch item {
      case .message(let m): m.text
      case .progress(let steps): "[" + steps.map(\.text).joined(separator: ",") + "]"
      }
    }
    XCTAssertEqual(rows, ["Go", "[t1,Checking,t2]", "Done", "More", "[t3]", "Last", "Only"])
  }

  func testBenchRealHome() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAIR_HISTORY_BENCH"] != nil)
    let period = AgentHistoryStore.period(.recent)
    for full in [true, false] {
      let start = Date()
      let items = AgentHistoryReader.load(period: period, full: full)
      print("BENCH full=\(full) \(items.count) items \(Date().timeIntervalSince(start))s cost=\(items.compactMap(\.estimatedUSD).reduce(0, +)) prompts=\(items.map(\.promptCount).reduce(0, +))")
    }
  }

  func testGroupsByRelativeDayThenProject() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-history-group-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let dir = home.appending(path: ".claude/projects/p")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"type":"user","timestamp":"2026-09-24T02:00:00Z","sessionId":"s","uuid":"u","cwd":"/w/clair","message":{"content":"hi"}}"#
      .write(to: dir.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)
    let read = try XCTUnwrap(AgentHistoryReader.load(home: home).first)
    XCTAssertEqual(read.project, "/w/clair")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z"))
    func item(_ id: String, _ daysAgo: Double, _ project: String?) -> AgentHistory {
      AgentHistory(id: id, provider: .claude, title: id, date: now - daysAgo * 86_400, messages: [], estimatedUSD: 1, project: project)
    }
    let groups = AgentHistoryGroup.group(
      [item("a", 0, "/w/clair"), item("b", 0.1, "/x/clair"), item("c", 0.05, "/w/ccedit"), item("d", 1, nil), item("e", 5, "/w/clair")])
    XCTAssertEqual(groups.map(\.project), ["clair", "ccedit", "Unknown"])
    XCTAssertEqual(groups[0].histories.map(\.id), ["a", "b", "e"])
    XCTAssertEqual(groups[0].estimatedUSD, 3)
    let days = AgentHistoryDay.group(
      [item("a", 0, "/w/clair"), item("c", 0.05, "/w/ccedit"), item("d", 1, nil), item("e", 5, "/w/clair")], calendar: calendar)
    XCTAssertEqual(days.map { $0.groups.map(\.project) }, [["ccedit", "clair"], ["Unknown"], ["clair"]])
    let spanning = AgentHistory(id: "s", provider: .claude, title: "s", date: now, messages: [
      .init(id: "1", role: "user", text: "", date: now - 2 * 86_400), .init(id: "2", role: "user", text: "", date: now)], estimatedUSD: 1, project: "/w/clair")
    XCTAssertEqual(AgentHistoryDay.group([spanning], calendar: calendar).count, 1)
  }

  func testArchiveIsSplitByModifiedTimeBeforeParsing() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-history-archive-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let dir = home.appending(path: ".claude/projects/p")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, age) in [("new", 1.0), ("old", 40.0)] {
      let file = dir.appending(path: "\(name).jsonl")
      try #"{"type":"user","timestamp":"2026-09-24T02:00:00Z","sessionId":"\#(name)","uuid":"\#(name)","message":{"content":"hi"}}"#
        .write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.modificationDate: Date() - age * 86_400], ofItemAtPath: file.path)
    }
    XCTAssertEqual(AgentHistoryReader.load(home: home, period: AgentHistoryStore.period(.recent)).map(\.id), ["Claude Code:new"])
    XCTAssertEqual(AgentHistoryReader.load(home: home, period: AgentHistoryStore.period(.archive)).map(\.id), ["Claude Code:old"])
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
    XCTAssertEqual(summary.days[0].providerPrompts[.codex], 1)
    XCTAssertEqual(summary.days[0].providerPrompts[.claude], 1)
    XCTAssertTrue(Calendar.current.isDate(summary.days[0].date, inSameDayAs: ISO8601DateFormatter().date(from: "2026-09-24T00:00:00Z")!))
    XCTAssertEqual(summary.sessionsWithoutCost, 0)
  }

  func testTurnsRunFromEachPromptToItsLastReply() {
    let t = Date(timeIntervalSince1970: 1_000_000)
    let turns = AgentHistoryReader.turns([
      (false, t),  // before any prompt: ignored
      (true, t + 10), (false, t + 20), (false, t + 70),
      (true, t + 100),  // unanswered: dropped
      (true, t + 200), (false, t + 230),
    ])
    XCTAssertEqual(turns, [DateInterval(start: t + 10, end: t + 70), DateInterval(start: t + 200, end: t + 230)])
  }

  func testClaudeListParseKeepsTurnsAndModelCosts() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-usage-turns-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appending(path: ".claude/projects/p")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let usage = #"{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":0}}"#
    let rows = [
      #"{"type":"user","timestamp":"2026-09-24T02:00:00Z","sessionId":"s","uuid":"u1","message":{"content":"First"}}"#,
      #"{"type":"assistant","timestamp":"2026-09-24T02:00:05Z","sessionId":"s","uuid":"a1","message":{"model":"claude-sonnet-5","id":"m1","content":[{"type":"tool_use","id":"t1","input":{}}],"usage":\#(usage)}}"#,
      #"{"type":"user","timestamp":"2026-09-24T02:00:06Z","sessionId":"s","uuid":"r1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]}}"#,
      #"{"type":"assistant","timestamp":"2026-09-24T02:00:30Z","sessionId":"s","uuid":"a2","message":{"model":"claude-sonnet-5","id":"m2","content":[{"type":"text","text":"Done"}],"usage":\#(usage)}}"#,
      #"{"type":"user","timestamp":"2026-09-24T02:10:00Z","sessionId":"s","uuid":"u2","message":{"content":"Second"}}"#,
      #"{"type":"assistant","timestamp":"2026-09-24T02:11:00Z","sessionId":"s","uuid":"a3","message":{"model":"claude-x","id":"m3","content":[{"type":"text","text":"Ok"}],"usage":\#(usage)}}"#,
    ]
    try rows.joined(separator: "\n").write(to: project.appending(path: "s.jsonl"), atomically: true, encoding: .utf8)
    let item = try XCTUnwrap(AgentHistoryReader.load(home: home).first)
    let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T02:00:00Z"))
    XCTAssertEqual(item.turns, [DateInterval(start: start, duration: 30), DateInterval(start: start + 600, duration: 60)])
    XCTAssertNil(item.estimatedUSD)  // one model has no known price
    XCTAssertEqual(item.models.first { $0.name == "claude-sonnet-5" }?.usd ?? 0, 0.00829, accuracy: 0.000001)
    XCTAssertEqual(item.models.first { $0.name == "claude-x" }, AgentHistory.ModelCost(name: "claude-x", usd: nil))
  }

  func testUsageSummaryStreaksHoursWaitsAndConcurrency() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-06T12:00:00Z"))
    let today = calendar.startOfDay(for: now)
    func prompt(_ day: Int, _ hour: Double) -> AgentHistory.Message {
      .init(id: UUID().uuidString, role: "user", text: "p", date: today.addingTimeInterval(Double(day) * 86_400 + hour * 3600))
    }
    var a = AgentHistory(id: "Claude Code:a", provider: .claude, title: "a", date: now,
                         messages: [prompt(0, 9), prompt(-1, 9), prompt(-2, 21), prompt(-5, 21)], estimatedUSD: 2)
    a.turns = [DateInterval(start: today + 9 * 3600, duration: 40), DateInterval(start: today + 10 * 3600, duration: 3 * 3600)]
    var b = AgentHistory(id: "Codex:b", provider: .codex, title: "b", date: now, messages: [prompt(-1, 21)], estimatedUSD: nil)
    b.turns = [DateInterval(start: today + 11 * 3600, duration: 600)]
    let summary = AgentUsageSummary(histories: [a, b], calendar: calendar)

    XCTAssertEqual(summary.streak(now: now, calendar: calendar), 3)
    XCTAssertEqual(summary.longestStreak(calendar: calendar), 3)
    XCTAssertEqual(summary.busiestHours(since: today - 90 * 86_400, calendar: calendar), [21, 9])

    let waits = summary.waits(in: DateInterval(start: today, end: now))
    XCTAssertEqual(waits.map(\.seconds).sorted(), [40, 600, AgentUsageSummary.waitCap])
    XCTAssertEqual(AgentUsageSummary.median(waits.map(\.seconds)), 600)
    XCTAssertEqual(AgentUsageSummary.histogram(waits), [0, 0, 1, 0, 0, 0, 1, 1])

    let steps = summary.concurrency(in: DateInterval(start: today, end: now))
    XCTAssertEqual(steps.map(\.running).max(), 2)
    XCTAssertEqual(AgentUsageSummary.seconds(steps, atLeast: 2, until: now), 600)
  }

  func testUsageSummaryMonthsAndRankings() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let formatter = ISO8601DateFormatter()
    let now = try XCTUnwrap(formatter.date(from: "2026-10-03T12:00:00Z"))
    func chat(_ id: String, _ provider: AgentHistory.Provider, _ date: String, usd: Double?, models: [AgentHistory.ModelCost]) throws -> AgentHistory {
      let at = try XCTUnwrap(formatter.date(from: date))
      var history = AgentHistory(id: id, provider: provider, title: id, date: at,
                                 messages: [.init(id: id, role: "user", text: id, date: at)], estimatedUSD: usd)
      history.models = models
      return history
    }
    let summary = AgentUsageSummary(histories: [
      try chat("a", .claude, "2026-10-01T10:00:00Z", usd: 3, models: [.init(name: "claude-opus-5-5", usd: 3)]),
      try chat("b", .claude, "2026-10-03T10:00:00Z", usd: 1, models: [.init(name: "claude-sonnet-5", usd: 1)]),
      try chat("c", .codex, "2026-10-02T10:00:00Z", usd: nil, models: [.init(name: "gpt-x", usd: nil)]),
      try chat("d", .claude, "2026-09-02T10:00:00Z", usd: 5, models: [.init(name: "claude-opus-5-5", usd: 5)]),
    ], calendar: calendar)

    XCTAssertEqual(summary.cumulative(month: now, cost: false, now: now, calendar: calendar), [1, 2, 3])
    XCTAssertEqual(summary.cumulative(month: now, cost: true, now: now, calendar: calendar), [3, 3, 4])
    XCTAssertEqual(summary.cumulative(month: now - 30 * 86_400, cost: true, now: now, calendar: calendar).count, 30)
    XCTAssertEqual(summary.sessionsWithoutCost(month: now, calendar: calendar), 1)

    let models = summary.models(since: nil)
    XCTAssertEqual(models.map(\.name), ["claude-opus-5-5", "claude-sonnet-5", "gpt-x"])
    XCTAssertEqual(models[0].usd, 8)
    XCTAssertEqual(models[0].sessions, 2)
    XCTAssertNil(models[2].usd)
    XCTAssertEqual(summary.costliestSessions(since: now - 7 * 86_400, limit: 5).map(\.id), ["a", "b"])
  }

  func testResumeCommandCdsIntoRecordedDirectory() {
    let chat = AgentHistory(id: "Claude Code:abc-1", provider: .claude, title: "t", date: .now, messages: [],
                            estimatedUSD: nil, project: "/tmp/it's")
    XCTAssertEqual(chat.resumeCommand, #"cd '/tmp/it'\''s' && claude --resume abc-1"#)
  }
}

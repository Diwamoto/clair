import XCTest

@testable import ClairWorkspace

/// #69: agent.history keeps a pane's run after it closes, for 90 days.
final class AgentPaneLogTests: XCTestCase {
  let r = CommandRegistry.workbench

  func opened() throws -> WorkbenchState {
    let dir = URL.temporaryDirectory.appending(path: "clair-69-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var s = WorkbenchState()
    try r.execute("project.open", ["path": .string(dir.path)], state: &s).get()
    s.tree = PaneTree()
    return s
  }

  func history(_ s: WorkbenchState) throws -> [[String: Any]] {
    var s = s
    guard case .text(let json) = try r.execute("agent.history", state: &s).get() else { throw CocoaError(.coderInvalidValue) }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
  }

  // Launch → title changes → close → `agent.history`, through the window tick and the command.
  func testLaunchActivityCloseThenHistory() throws {
    let saved = AgentPaneLog.defaultURL
    AgentPaneLog.defaultURL = URL.temporaryDirectory.appending(path: "clair-69-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: AgentPaneLog.defaultURL); AgentPaneLog.defaultURL = saved }
    var s = try opened()
    guard case .pane(let pane) = try r.execute("agent.launch", ["profile": .string("codex")], confirmed: true, state: &s).get() else { return XCTFail() }
    let key = WorkbenchState.terminalKey(s.projects[0].path, pane)
    var owned: Set<String> = []
    let t0 = Date()
    AgentPaneLog.record(live: s.liveAgentRecords(now: t0), owned: &owned, now: t0)
    s.paneTitles[NotificationLog.paneKey(s.project, pane)] = "◐ fix login"
    AgentPaneLog.record(live: s.liveAgentRecords(now: t0 + 2), owned: &owned, now: t0 + 2)
    s.paneTitles[NotificationLog.paneKey(s.project, pane)] = "✳ Codex"  // a bare tool name keeps the last activity
    AgentPaneLog.record(live: s.liveAgentRecords(now: t0 + 3), owned: &owned, now: t0 + 3)
    // Another window, which never had this pane, must not end it.
    var other: Set<String> = []
    AgentPaneLog.record(live: [], owned: &other, now: t0 + 3)
    XCTAssertTrue(try history(s).first?["end"] is NSNull)  // live: null, not a missing key
    s.closeTerminal(key)
    AgentPaneLog.record(live: s.liveAgentRecords(now: t0 + 4), owned: &owned, now: t0 + 4)
    AgentPaneLog.record(live: s.liveAgentRecords(now: t0 + 6), owned: &owned, now: t0 + 6)

    let rows = try history(s)
    XCTAssertEqual(rows.count, 1)
    let rec = try XCTUnwrap(rows.first)
    XCTAssertEqual(rec["key"] as? String, key); XCTAssertEqual(rec["profile"] as? String, "codex")
    XCTAssertEqual(rec["activity"] as? String, "fix login"); XCTAssertEqual(rec["activityState"] as? String, "✳")
    XCTAssertEqual(rec["start"] as? String, AgentPaneLog.stamp(t0)); XCTAssertEqual(rec["end"] as? String, AgentPaneLog.stamp(t0 + 4))
    XCTAssertEqual(rec["endReason"] as? String, "closed")
    XCTAssertEqual(try r.preflight("agent.history", ["since": .string("2026-02-30")], s).failure?.code, .preconditionFailed)
  }

  func testQuitEndsOpenRuns() throws {
    let url = URL.temporaryDirectory.appending(path: "clair-69-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let now = Date()
    AgentPaneLog.save([AgentPaneRecord(key: "/p#1", project: "p", cwd: "/p", profile: "claude", branch: nil, start: AgentPaneLog.stamp(now), end: nil, parent: nil)], to: url)
    AgentPaneLog.endOpen(url: url, now: now + 5)
    XCTAssertEqual(AgentPaneLog.load(url).first?.end, AgentPaneLog.stamp(now + 5))
    XCTAssertEqual(AgentPaneLog.load(url).first?.endReason, "quit")
  }

  func testRetentionDropsEndedRecordsAfter90Days() {
    let now = Date()
    func rec(_ key: String, end: Date?) -> AgentPaneRecord {
      AgentPaneRecord(key: key, project: "p", cwd: "/p", profile: "claude", branch: nil, start: AgentPaneLog.stamp(now - 100 * 86400),
        end: end.map(AgentPaneLog.stamp), parent: nil)
    }
    let kept = AgentPaneLog.merge([rec("old", end: now - 91 * 86400), rec("recent", end: now - 89 * 86400)], live: [], now: now)
    XCTAssertEqual(kept.map(\.key), ["recent"])
  }
}

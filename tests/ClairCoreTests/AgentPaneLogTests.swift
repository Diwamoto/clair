import XCTest

@testable import ClairWorkspace

/// #69: agent.history keeps a pane's run after it closes, for 90 days.
final class AgentPaneLogTests: XCTestCase {
  let r = CommandRegistry.workbench

  func testLaunchActivityCloseThenHistory() throws {
    let dir = URL.temporaryDirectory.appending(path: "clair-69-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var s = WorkbenchState()
    try r.execute("project.open", ["path": .string(dir.path)], state: &s).get()
    s.tree = PaneTree()
    guard case .pane(let pane) = try r.execute("agent.launch", ["profile": .string("codex")], confirmed: true, state: &s).get() else { return XCTFail() }
    let t0 = Date()
    var log = AgentPaneLog.merge([], live: s.liveAgentRecords(now: t0), now: t0)
    s.paneTitles[NotificationLog.paneKey(s.project, pane)] = "fix login"
    log = AgentPaneLog.merge(log, live: s.liveAgentRecords(now: t0 + 2), now: t0 + 2)
    s.closeTerminal(WorkbenchState.terminalKey(dir.path, pane))
    log = AgentPaneLog.merge(log, live: s.liveAgentRecords(now: t0 + 4), now: t0 + 4)
    log = AgentPaneLog.merge(log, live: s.liveAgentRecords(now: t0 + 6), now: t0 + 6)

    XCTAssertEqual(log.count, 1)
    let rec = try XCTUnwrap(log.first)
    XCTAssertEqual([rec.key, rec.profile, rec.activity], [WorkbenchState.terminalKey(dir.path, pane), "codex", "fix login"])
    XCTAssertEqual(rec.start, AgentPaneLog.stamp(t0)); XCTAssertEqual(rec.end, AgentPaneLog.stamp(t0 + 4))
    let today = Calendar.current.startOfDay(for: t0)
    XCTAssertEqual(AgentPaneLog.filter(log, since: today, until: .distantFuture, project: s.project).count, 1)
    XCTAssertEqual(AgentPaneLog.filter(log, since: today, until: .distantFuture, project: "other").count, 0)
    XCTAssertEqual(AgentPaneLog.filter(log, since: t0 + 3600, until: .distantFuture, project: nil).count, 0)
    XCTAssertEqual(try r.preflight("agent.history", ["since": .string("2026-02-30")], s).failure?.code, .preconditionFailed)
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

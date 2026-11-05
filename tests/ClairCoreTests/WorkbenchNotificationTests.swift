import XCTest

@testable import ClairWorkspace

final class WorkbenchNotificationTests: XCTestCase {
  func testBadgeHistoryAndMute() {
    var log = NotificationLog()
    XCTAssertNotNil(log.record(project: "a", pane: 2, kind: .bell))
    XCTAssertNotNil(log.record(project: "b", pane: 3, kind: .exited, exitCode: 1))
    XCTAssertEqual(log.unread("a"), 1); XCTAssertEqual(log.unread(), 2)
    XCTAssertEqual(log.items.first?.title, "Failed (exit 1)")
    log.mutedPanes.insert(NotificationLog.paneKey("a", 2))
    XCTAssertNil(log.record(project: "a", pane: 2, kind: .bell))  // muted pane: no alert…
    XCTAssertEqual(log.unread("a"), 1)  // …no badge…
    XCTAssertEqual(log.items.count, 3)  // …but kept in history
    log.mutedProjects.insert("b")
    XCTAssertNil(log.record(project: "b", pane: 9, kind: .bell))
    log.markRead(project: "a"); XCTAssertEqual(log.unread("a"), 0); XCTAssertEqual(log.unread("b"), 1)
    log.markRead(project: "b", pane: 3); XCTAssertEqual(log.unread("b"), 0)
    for _ in 0..<300 { log.record(project: "a", pane: 1, kind: .bell) }
    XCTAssertEqual(log.items.count, NotificationLog.cap)
  }

  func testSourceNotificationTextIsKeptInHistory() {
    var log = NotificationLog()
    let notice = log.record(project: "p", pane: 1, kind: .bell, sourceTitle: "承認待ち", sourceBody: "コマンドの実行を確認してください", sessionTitle: "設定画面の修正")
    XCTAssertEqual(notice?.title, "承認待ち")
    XCTAssertEqual(log.items.first?.sourceBody, "コマンドの実行を確認してください")
    XCTAssertEqual(log.items.first?.sessionTitle, "設定画面の修正")
  }

  func testDoneNoticeFoldsTheIdleBellUntilWorkingAgain() {
    var log = NotificationLog()
    log.record(project: "p", pane: 1, kind: .done, sourceBody: String(repeating: "あ", count: 1000))
    XCTAssertEqual(log.items.first?.title, "Done")
    XCTAssertEqual(log.items.first?.sourceBody?.count, NotificationLog.bodyCap)
    XCTAssertTrue(log.hasUnreadDone(project: "p", pane: 1))
    XCTAssertFalse(log.hasUnreadDone(project: "p", pane: 2))
    log.record(project: "p", pane: 1, kind: .bell)
    log.markDoneRead(project: "p", pane: 1)  // the agent works again: only the stale "done" is read
    XCTAssertFalse(log.hasUnreadDone(project: "p", pane: 1))
    XCTAssertEqual(log.unread("p"), 1)
  }

  func testPostRespectsMuteAndRateLimit() throws {
    var s = WorkbenchState()
    s.projects = [WorkbenchProject(name: "p", path: "/tmp"), WorkbenchProject(name: "q", path: "/tmp")]; s.project = "p"
    let reg = CommandRegistry.workbench
    XCTAssertNoThrow(try reg.execute("notice.post", ["title": .string("期限切れ"), "body": .string("TODO 3 件"), "open": .string("a.md")], state: &s).get())
    XCTAssertEqual(s.notices.items.first?.sessionTitle, "期限切れ"); XCTAssertEqual(s.notices.items.first?.open, "a.md")
    XCTAssertEqual(s.notices.unread("p"), 1)
    s.notices.mutedProjects.insert("q")
    XCTAssertNoThrow(try reg.execute("notice.post", ["title": .string("x"), "project": .string("q")], state: &s).get())
    XCTAssertEqual(s.notices.unread("q"), 0)  // muted: history only
    XCTAssertEqual(reg.execute("notice.post", ["title": .string("x"), "project": .string("nope")], state: &s).failureCode, .preconditionFailed)
    for _ in 0..<3 { XCTAssertNoThrow(try reg.execute("notice.post", ["title": .string("x")], state: &s).get()) }
    XCTAssertEqual(reg.execute("notice.post", ["title": .string("x")], state: &s).failureCode, .preconditionFailed)
    XCTAssertTrue(s.notices.postAllowed(at: Date().addingTimeInterval(NotificationLog.postWindow + 1)))
    XCTAssertEqual(reg.commands.first { $0.id == "notice.post" }?.aiAvailable, true)
  }

  func testToggleOpensTheNoticePanel() throws {
    var s = WorkbenchState()
    let reg = CommandRegistry.workbench
    XCTAssertNoThrow(try reg.execute("notice.toggle", [:], state: &s).get())
    XCTAssertTrue(s.noticesOpen)
    XCTAssertEqual(reg.commands.first { $0.id == "notice.toggle" }?.shortcut, "⌘⇧H")
  }

  func testMuteCommandsAndAIBoundary() throws {
    var s = WorkbenchState()
    s.projects = [WorkbenchProject(name: "p", path: "/tmp")]; s.project = "p"
    let reg = CommandRegistry.workbench
    XCTAssertNoThrow(try reg.execute("notice.mutePane", ["id": .int(1), "muted": .bool(true)], state: &s).get())
    XCTAssertTrue(s.notices.mutedPanes.contains("p#1"))
    XCTAssertNoThrow(try reg.execute("notice.muteProject", ["name": .string("p"), "muted": .bool(true)], state: &s).get())
    XCTAssertEqual(reg.execute("notice.mutePane", ["id": .int(99), "muted": .bool(true)], state: &s).failureCode, .preconditionFailed)
    let ai = Dictionary(uniqueKeysWithValues: reg.commands.map { ($0.id, $0.aiAvailable) })
    XCTAssertEqual(ai["notice.muteProject"], false); XCTAssertEqual(ai["notice.markRead"], true)
  }
}

private extension Result where Failure == CommandError {
  var failureCode: CommandError.Code? { if case .failure(let e) = self { e.code } else { nil } }
}

final class AgentSessionTests: XCTestCase {
  func testStatusFromFacts() {
    var s = WorkbenchState()
    s.project = "p"
    s.launches = [1: AgentLaunch(profile: "claude", cwd: "/x"), 2: AgentLaunch(profile: "codex", cwd: "/x"), 3: AgentLaunch(profile: "opencode", cwd: "/x")]
    s.notices.record(project: "p", pane: 2, kind: .bell)
    s.notices.record(project: "p", pane: 3, kind: .exited, exitCode: 0)
    XCTAssertEqual(s.agentSessions.map(\.status), [.running, .attention, .exited(0)])
    s.notices.markRead(project: "p")
    XCTAssertEqual(s.agentSessions[1].status, .running)
  }

  func testOnlyClairAgentPanesQualifyForNotifications() {
    var s = WorkbenchState()
    s.project = "p"
    s.launches = [1: AgentLaunch(profile: "codex", cwd: "/p")]
    s.detectedLaunches["p"] = [2: AgentLaunch(profile: "claude", cwd: "/p")]
    XCTAssertEqual(s.agentLaunch(in: "p", pane: 1)?.profile, "codex")
    XCTAssertEqual(s.agentLaunch(in: "p", pane: 2)?.profile, "claude")
    XCTAssertNil(s.agentLaunch(in: "p", pane: 3))
  }
}

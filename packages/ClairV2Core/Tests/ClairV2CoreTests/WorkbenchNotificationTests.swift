import XCTest

@testable import ClairV2Workspace

final class WorkbenchNotificationTests: XCTestCase {
  func testBadgeHistoryAndMute() {
    var log = NotificationLog()
    XCTAssertNotNil(log.record(project: "a", pane: 2, kind: .bell))
    XCTAssertNotNil(log.record(project: "b", pane: 3, kind: .exited, exitCode: 1))
    XCTAssertEqual(log.unread("a"), 1); XCTAssertEqual(log.unread(), 2)
    XCTAssertEqual(log.items.first?.title, "異常終了 (exit 1)")
    log.mutedPanes.insert(NotificationLog.paneKey("a", 2))
    XCTAssertNil(log.record(project: "a", pane: 2, kind: .bell))  // muted pane: no alert…
    XCTAssertEqual(log.unread("a"), 1)  // …no badge…
    XCTAssertEqual(log.items.count, 3)  // …but kept in history
    log.mutedProjects.insert("b")
    XCTAssertNil(log.record(project: "b", pane: 9, kind: .bell))
    log.markRead(project: "a"); XCTAssertEqual(log.unread("a"), 0); XCTAssertEqual(log.unread("b"), 1)
    for _ in 0..<300 { log.record(project: "a", pane: 1, kind: .bell) }
    XCTAssertEqual(log.items.count, NotificationLog.cap)
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

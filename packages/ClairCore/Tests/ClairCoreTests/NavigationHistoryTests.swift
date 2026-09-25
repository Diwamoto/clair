import XCTest

@testable import ClairWorkspace

/// E17: ⌃- / ⌃⇧- definition-jump history.
final class NavigationHistoryTests: XCTestCase {
  private func loc(_ path: String, _ line: Int) -> EditorLocation { EditorLocation(path: path, line: line, column: 0) }

  func testBackForwardAndAJumpDropsForwardEntries() {
    var h = NavigationHistory()
    XCTAssertFalse(h.canGoBack)
    h.jump(from: loc("/p/a.go", 3), to: loc("/p/b.go", 10))
    h.jump(from: loc("/p/b.go", 12), to: loc("/p/c.go", 1))  // caret moved in b before the second jump
    XCTAssertEqual(h.entries.map(\.line), [3, 12, 1])
    XCTAssertEqual(h.back(), loc("/p/b.go", 12))
    XCTAssertEqual(h.back(), loc("/p/a.go", 3))
    XCTAssertNil(h.back())
    XCTAssertEqual(h.forward(), loc("/p/b.go", 12))
    h.jump(from: loc("/p/b.go", 20), to: loc("/p/d.go", 5))
    XCTAssertEqual(h.entries.map(\.line), [3, 20, 5])
    XCTAssertFalse(h.canGoForward)
    for i in 0..<100 { h.jump(from: loc("/p/x", i), to: loc("/p/y", i)) }
    XCTAssertEqual(h.entries.count, NavigationHistory.limit)
    XCTAssertEqual(h.current, loc("/p/y", 99))
  }

  func testNavigateCommandsOpenTheRecordedFile() throws {
    let r = CommandRegistry.workbench
    var s = WorkbenchState()
    XCTAssertEqual(r.commands.first { $0.id == "editor.navigateBack" }?.shortcut, "⌃-")
    XCTAssertEqual(r.commands.first { $0.id == "editor.navigateForward" }?.shortcut, "⌃⇧-")
    XCTAssertThrowsError(try r.execute("editor.navigateBack", state: &s).get())
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for f in ["a.swift", "lib/b.swift"] { FileManager.default.createFile(atPath: root.appendingPathComponent(f).path, contents: Data()) }
    s.navigation.jump(from: loc(root.path + "/a.swift", 4), to: loc(root.path + "/lib/b.swift", 9))
    _ = try r.execute("editor.navigateBack", state: &s).get()
    XCTAssertEqual(s.active, "a.swift")
    XCTAssertEqual(s.navigation.current?.line, 4)
    _ = try r.execute("editor.navigateForward", state: &s).get()
    XCTAssertEqual(s.active, "lib/b.swift")
  }
}

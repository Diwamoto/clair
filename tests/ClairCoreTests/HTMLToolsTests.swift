import XCTest

@testable import ClairWorkspace

/// ADR-0033: HTML tools — shipped + `~/.clair/tools`, each opened in a pane of its own.
final class HTMLToolsTests: XCTestCase {
  func testAddCopiesAndOverwritesAndListsShippedFirst() throws {
    let tmp = URL.temporaryDirectory.appending(path: "clair-tools-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let home = tmp.appending(path: "home"), builtins = tmp.appending(path: "builtin"), src = tmp.appending(path: "out")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try "v1".write(to: src.appending(path: "report.html"), atomically: true, encoding: .utf8)
    try "x".write(to: src.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

    let copy = try HTMLTools.add(src.appending(path: "report.html").path, home: home)
    XCTAssertEqual(copy, HTMLTools.folder(home: home).appending(path: "report.html").path)
    try "v2".write(to: src.appending(path: "report.html"), atomically: true, encoding: .utf8)
    _ = try HTMLTools.add(src.appending(path: "report.html").path, home: home)
    XCTAssertEqual(try String(contentsOfFile: copy, encoding: .utf8), "v2", "the same name overwrites")
    XCTAssertThrowsError(try HTMLTools.add(src.appending(path: "notes.txt").path, home: home))
    XCTAssertThrowsError(try HTMLTools.add(src.appending(path: "missing.html").path, home: home))

    let tools = HTMLTools.list(home: home, builtins: builtins)
    XCTAssertEqual(tools.map(\.name), ["terraform-plan.html", "report.html"])
    XCTAssertEqual(tools.map(\.builtin), [true, false])
    XCTAssertEqual(try String(contentsOfFile: tools[0].path, encoding: .utf8), HTMLTools.terraformPlan, "shipped pages are written out")
    XCTAssertEqual(HTMLTools.find("report.html", home: home, builtins: builtins)?.path, copy)
    XCTAssertEqual(HTMLTools.find(copy, home: home, builtins: builtins)?.name, "report.html")
    XCTAssertNil(HTMLTools.find("nope.html", home: home, builtins: builtins))
  }

  func testToolOpensOnceInAPaneOfItsOwn() throws {
    var s = WorkbenchState()
    let first = s.tree.leaves.count
    guard case .pane(let id) = CommandRegistry.openToolPane(&s, "/t/a.html") else { return XCTFail() }
    XCTAssertEqual(s.tree.leaves.count, first + 1)
    XCTAssertEqual(s.tree.focused, id)
    XCTAssertEqual(s.previews[id], "/t/a.html")
    XCTAssertTrue(s.tree.isValid)
    _ = CommandRegistry.openToolPane(&s, "/t/b.html")
    s.tree.focus(s.tree.leaves[0].id)
    XCTAssertEqual(CommandRegistry.openToolPane(&s, "/t/a.html"), .pane(id), "asking again focuses the open pane")
    XCTAssertEqual(s.tree.leaves.count, first + 2)

    s.panesClosed = true
    guard case .pane(let only) = CommandRegistry.openToolPane(&s, "/t/a.html") else { return XCTFail() }
    XCTAssertEqual(s.tree.leaves.map(\.id), [only])
    XCTAssertFalse(s.panesClosed)
  }
}

import ClairV2EditorCore
import XCTest

@testable import ClairV2Workspace

/// V05: quick open, project search/replace, live reload, local history.
final class WorkbenchSearchTests: XCTestCase {
  func tmp() throws -> String {
    let d = URL.temporaryDirectory.appending(path: "clair-v05-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.path
  }

  func testQuickOpenPrefersBasenameAndSubsequence() {
    let f = ["docs/pane.md", "apple/ClairApp/PaneSplit.swift", "x/unrelated.txt"].map { WorkbenchFile(path: $0, status: nil) }
    XCTAssertEqual(QuickOpen.rank("pansp", f).map(\.path), ["apple/ClairApp/PaneSplit.swift"])
    XCTAssertEqual(QuickOpen.rank("pane", f).first?.path, "docs/pane.md")
    XCTAssertEqual(QuickOpen.rank("", f).count, 3)
  }

  func testFindAndReplaceWithHistory() throws {
    let root = try tmp()
    try "foo\nbar foo\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    try Data([0xff, 0xfe, 0x00]).write(to: URL(fileURLWithPath: root + "/bin.dat"))
    let files = WorkbenchFiles.scan(root)
    let hits = try ProjectSearch.find(root: root, files: files, .literal("foo"))
    XCTAssertEqual(hits, [SearchHit(path: "a.txt", line: 1, text: "foo"), SearchHit(path: "a.txt", line: 2, text: "bar foo")])
    let h = LocalHistory(dir: URL(fileURLWithPath: try tmp()))
    XCTAssertEqual(try ProjectSearch.replace(root: root, files: files, .literal("foo"), with: "baz", history: h), 2)
    XCTAssertEqual(try String(contentsOfFile: root + "/a.txt", encoding: .utf8), "baz\nbar baz\n")
    let v = try h.versions(root: root, path: "a.txt")
    XCTAssertEqual(v.count, 1)
    try h.restore(v[0], root: root, path: "a.txt")
    XCTAssertEqual(try String(contentsOfFile: root + "/a.txt", encoding: .utf8), "foo\nbar foo\n")
    XCTAssertEqual(try h.versions(root: root, path: "a.txt").count, 2)  // restore is undoable
  }

  func testDiskChangeDiscardsUnsavedBuffer() throws {
    let root = try tmp()
    try "x".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    var s = WorkbenchState()
    try CommandRegistry.workbench.execute("project.open", ["path": .string(root)], state: &s).get()
    s.dirty = ["a.txt", "other"]
    try "y".write(toFile: root + "/b.txt", atomically: true, encoding: .utf8)
    s.applyDiskChange(["a.txt"], root: root)
    XCTAssertEqual(s.dirty, ["other"])
    XCTAssertEqual(s.files.map(\.path), ["a.txt", "b.txt"])
  }

  func testWatcherReportsAgentWrite() throws {
    let root = try tmp()
    let e = expectation(description: "change")
    let w = FileWatcher(root: root, latency: 0.05) { if $0.contains("n.txt") { e.fulfill() } }
    try withExtendedLifetime(XCTUnwrap(w)) {
      Thread.sleep(forTimeInterval: 0.3)
      try "1".write(toFile: root + "/n.txt", atomically: true, encoding: .utf8)
      wait(for: [e], timeout: 5)
    }
  }

  func testTenThousandFilesStayResponsive() throws {
    let root = try tmp()
    for i in 0..<10_000 { FileManager.default.createFile(atPath: root + "/f\(i).txt", contents: Data("line \(i)\n".utf8)) }
    let t0 = Date()
    let files = WorkbenchFiles.scan(root)
    let scan = Date().timeIntervalSince(t0)
    let t1 = Date()
    _ = QuickOpen.rank("f99", files)
    let rank = Date().timeIntervalSince(t1)
    print("V05 perf: scan(\(files.count) of 10000)=\(scan)s rank=\(rank)s")
    XCTAssertEqual(files.count, 10_000)
    XCTAssertLessThan(rank, 0.2)
  }
}

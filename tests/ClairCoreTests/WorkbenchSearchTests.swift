import ClairEditorCore
import XCTest

@testable import ClairWorkspace

/// V05: quick open, project search/replace, live reload.
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

  func testQuickOpenTokensAndSubstrings() {
    let f = ["packages/ClairWorkspace/WorkbenchSearch.swift", "apps/mac/Search.swift", "tests/WorkbenchSearchTests.swift"]
      .map { WorkbenchFile(path: $0, status: nil) }
    // Space-separated tokens match in any order.
    XCTAssertEqual(QuickOpen.rank("search workspace", f).map(\.path), ["packages/ClairWorkspace/WorkbenchSearch.swift"])
    XCTAssertEqual(QuickOpen.rank("mac/sea", f).first?.path, "apps/mac/Search.swift")
    XCTAssertEqual(QuickOpen.rank("", f, limit: 2).count, 2)
  }

  func testFilesPaletteListsRecentFirst() {
    var s = WorkbenchState()
    s.files = ["a.txt", "b.txt", "c.txt"].map { WorkbenchFile(path: $0, status: nil) }
    s.recent = ["c.txt", "b.txt"]
    XCTAssertEqual(CommandRegistry.workbench.paletteItems(.files, query: "", state: s).map(\.title), ["c.txt", "b.txt", "a.txt"])
    XCTAssertEqual(CommandRegistry.workbench.paletteItems(.files, query: "txt", state: s).first?.title, "c.txt")
  }

  func testSearchTreeGroupsFoldersFirstAndCollapses() {
    let h = { (p: String, l: Int) in SearchHit(path: p, line: l, text: "\(p):\(l)") }
    let hits = SearchTree.sorted([h("README.md", 3), h("a/b/x.swift", 5), h("a/b/x.swift", 9), h("a/y.swift", 1), h("../docs/z.md", 2)])
    XCTAssertEqual(hits.map(\.path), ["../docs/z.md", "a/b/x.swift", "a/b/x.swift", "a/y.swift", "README.md"])
    let rows = SearchTree.rows(hits)
    XCTAssertEqual(rows.map { "\($0.depth) \($0.name) \($0.count)" }, [
      "0 docs 1", "1 z.md 1", "2 ../docs/z.md:2 1",
      "0 a 3", "1 b 2", "2 x.swift 2", "3 a/b/x.swift:5 1", "3 a/b/x.swift:9 1", "1 y.swift 1", "2 a/y.swift:1 1",
      "0 README.md 1", "1 README.md:3 1",
    ])
    XCTAssertEqual(rows.compactMap { if case .hit(let i) = $0.kind { i } else { nil } }, [0, 1, 2, 3, 4])
    // Collapsing a folder hides everything under it but keeps the folder row; a file hides only its hits.
    XCTAssertEqual(SearchTree.rows(hits, collapsed: ["a/b", "README.md"]).map(\.path),
      ["../docs", "../docs/z.md", "../docs/z.md", "a", "a/b", "a/y.swift", "a/y.swift", "README.md"])
  }

  func testFindAndReplace() throws {
    let root = try tmp()
    try "foo\nbar foo\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    try Data([0xff, 0xfe, 0x00]).write(to: URL(fileURLWithPath: root + "/bin.dat"))
    let files = WorkbenchFiles.scan(root)
    let hits = try ProjectSearch.find(root: root, files: files, .literal("foo"))
    XCTAssertEqual(hits, [SearchHit(path: "a.txt", line: 1, text: "foo"), SearchHit(path: "a.txt", line: 2, text: "bar foo")])
    XCTAssertEqual(try ProjectSearch.replace(root: root, files: files, .literal("foo"), with: "baz"), 2)
    XCTAssertEqual(try String(contentsOfFile: root + "/a.txt", encoding: .utf8), "baz\nbar baz\n")
  }

  func testSearchSurfacesBadRegexAndStopsWhenCancelled() async throws {
    let root = try tmp()
    try "foo\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    let files = WorkbenchFiles.scan(root)
    XCTAssertThrowsError(try ProjectSearch.find(root: root, files: files, .regex("(", caseSensitive: true))) { XCTAssertEqual($0 as? SearchError, .invalidRegex) }
    let t = Task { () -> Bool in
      while !Task.isCancelled { await Task.yield() }
      do { _ = try ProjectSearch.find(root: root, files: files, .literal("foo")); return false } catch { return error is CancellationError }
    }
    t.cancel()
    let stopped = await t.value
    XCTAssertTrue(stopped)
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

  /// Added folders map to their `../x/` prefix; `.git/index`/`HEAD` pass so terminal commits recolor the tree.
  func testWatcherMapsFoldersAndGitIndex() throws {
    let base = try tmp(), root = base + "/app", docs = base + "/docs"
    for d in [root, docs] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
    let w = try XCTUnwrap(FileWatcher(root: root, folders: [docs]) { _ in })
    let r = realpath(base, nil).map { String(cString: $0) }!
    XCTAssertEqual(w.relative(r + "/app/a.swift"), "a.swift")
    XCTAssertEqual(w.relative(r + "/docs/x.md"), "../docs/x.md")
    XCTAssertEqual(w.relative(r + "/app/.git/index"), ".git/index")
    XCTAssertEqual(w.relative(r + "/app/.git/refs/heads/feature/x"), ".git/refs/heads/feature/x")
    XCTAssertNil(w.relative(r + "/app/.git/refs/heads/main.lock"))
    XCTAssertNil(w.relative(r + "/app/.git/objects/ab"))
    XCTAssertNil(w.relative(r + "/app/.build/x"))
    XCTAssertNil(w.relative("/elsewhere/y"))
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

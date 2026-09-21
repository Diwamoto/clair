import XCTest

@testable import ClairWorkspace

/// V04: Project open/switch, real file tree, persistence and safe degradation.
final class WorkbenchProjectTests: XCTestCase {
  let r = CommandRegistry.workbench
  var tmp: URL!

  override func setUpWithError() throws {
    tmp = URL.temporaryDirectory.appending(path: "clair-v04-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  }

  override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

  func folder(_ name: String, _ files: [String]) throws -> String {
    let root = tmp.appending(path: name)
    for f in files {
      let u = root.appending(path: f)
      try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: u)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.path
  }

  func open(_ path: String, _ s: inout WorkbenchState) {
    XCTAssertNoThrow(try r.execute("project.open", ["path": .string(path)], state: &s).get())
  }

  func testOpenNonGitFolderShowsRealFilesAndSkipsJunkAndSymlinks() throws {
    let a = try folder("a", ["src/main.swift", "README.md", "node_modules/x/y.js", ".build/z"])
    try FileManager.default.createSymbolicLink(atPath: a + "/link", withDestinationPath: "/etc")
    var s = WorkbenchState()
    open(a, &s)
    XCTAssertEqual(s.project, "a")
    XCTAssertEqual(s.files.map(\.path), ["src/main.swift", "README.md"])
    XCTAssertEqual(s.tabs, [])
  }

  func testOpenRejectsNonDirectoryAndSamePathReusesProject() throws {
    let a = try folder("a", ["f"])
    var s = WorkbenchState()
    XCTAssertEqual(r.execute("project.open", ["path": .string(a + "/f")], state: &s).failure?.code, .preconditionFailed)
    XCTAssertEqual(r.execute("project.open", ["path": .string("relative")], state: &s).failure?.code, .preconditionFailed)
    open(a, &s); open(a, &s)
    XCTAssertEqual(s.projects.count, 1)
    let b = try folder("x/a", ["g"])
    open(b, &s)
    XCTAssertEqual(s.projects.map(\.name), ["a", "a 2"])
  }

  func testSwitchKeepsLayoutPerProject() throws {
    var s = WorkbenchState()
    open(try folder("a", ["one.txt"]), &s)
    r.execute("tab.open", ["path": .string("one.txt")], state: &s)
    r.execute("pane.splitRight", state: &s)
    let aTree = s.tree
    open(try folder("b", ["two.txt"]), &s)
    XCTAssertEqual(s.tree, PaneTree()); XCTAssertEqual(s.tabs, [])
    r.execute("project.switch", ["name": .string("a")], state: &s)
    XCTAssertEqual(s.tree, aTree); XCTAssertEqual(s.tabs, ["one.txt"]); XCTAssertEqual(s.active, "one.txt")
    XCTAssertEqual(r.execute("project.switch", ["name": .string("zzz")], state: &s).failure?.code, .preconditionFailed)
  }

  func testPersistRoundTripAndDegradation() throws {
    let a = try folder("a", ["one.txt", "two.txt"]), b = try folder("b", ["x"])
    var s = WorkbenchState()
    open(a, &s); open(b, &s)
    r.execute("project.switch", ["name": .string("a")], state: &s)
    r.execute("tab.open", ["path": .string("one.txt")], state: &s)
    r.execute("tab.open", ["path": .string("two.txt")], state: &s)
    s.dirty = ["two.txt"]
    let url = tmp.appending(path: "ws.json")
    try s.save(to: url)

    try FileManager.default.removeItem(atPath: a + "/one.txt")  // stale tab
    let got = try XCTUnwrap(WorkbenchState.restore(from: url))
    XCTAssertEqual(got.project, "a")
    XCTAssertEqual(got.tabs, ["two.txt"]); XCTAssertEqual(got.active, "two.txt")
    XCTAssertTrue(got.dirty.isEmpty, "unsaved markers are not restored")
    XCTAssertEqual(got.projects.count, 2)

    try FileManager.default.removeItem(atPath: a)  // current root gone → falls to the survivor
    let got2 = try XCTUnwrap(WorkbenchState.restore(from: url))
    XCTAssertEqual(got2.projects.map(\.name), ["b"]); XCTAssertEqual(got2.project, "b")

    try Data("{not json".utf8).write(to: url)
    XCTAssertNil(WorkbenchState.restore(from: url))
  }

  func testInvalidTreeAndRestoreLayoutOff() throws {
    let a = try folder("a", ["f"])
    var s = WorkbenchState()
    open(a, &s)
    let url = tmp.appending(path: "ws.json")
    try s.save(to: url)
    var json = try String(contentsOf: url, encoding: .utf8)
    json = json.replacingOccurrences(of: "\"focused\":1", with: "\"focused\":99")  // focus points at no pane
    XCTAssertNotEqual(json, try String(contentsOf: url, encoding: .utf8))
    try Data(json.utf8).write(to: url)
    XCTAssertEqual(try XCTUnwrap(WorkbenchState.restore(from: url)).tree, PaneTree())

    r.execute("pane.splitRight", state: &s)
    r.execute("settings.set", ["key": .string("restoreLayout"), "value": .bool(false)], state: &s)
    try s.save(to: url)
    XCTAssertEqual(try XCTUnwrap(WorkbenchState.restore(from: url)).tree, PaneTree())
  }

  func testGitStatusBadges() throws {
    let a = try folder("g", ["tracked.txt", "old.txt"])
    func git(_ args: String...) throws {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      p.arguments = ["-C", a, "-c", "user.name=t", "-c", "user.email=t@t"] + args
      p.standardOutput = FileHandle.nullDevice
      try p.run(); p.waitUntilExit()
    }
    try git("init"); try git("add", "."); try git("commit", "-m", "i")
    try Data("y".utf8).write(to: URL(fileURLWithPath: a + "/tracked.txt"))
    try Data("n".utf8).write(to: URL(fileURLWithPath: a + "/new.txt"))
    try git("mv", "old.txt", "renamed.txt")
    let m = Dictionary(uniqueKeysWithValues: WorkbenchFiles.scan(a).map { ($0.path, $0.status) })
    XCTAssertEqual(m["tracked.txt"], "M"); XCTAssertEqual(m["new.txt"], "U"); XCTAssertEqual(m["renamed.txt"], "R")
  }

  func testTreeOrderFoldersFirstThenNames() {
    let paths = ["b.txt", "Z/x.txt", "a/z.txt", "a/B/y.txt", "a/a.txt", "A.txt"]
    XCTAssertEqual(paths.sorted(by: WorkbenchFiles.treeOrder), ["a/B/y.txt", "a/a.txt", "a/z.txt", "Z/x.txt", "A.txt", "b.txt"])
  }

  func testSwitchBackReusesCachedTree() throws {
    let a = try folder("ca", ["f.txt"]), b = try folder("cb", ["g.txt"])
    var s = WorkbenchState()
    s.openProject(WorkbenchProject(name: "ca", path: a)); s.openProject(WorkbenchProject(name: "cb", path: b))
    try Data("n".utf8).write(to: URL(fileURLWithPath: a + "/late.txt"))
    s.switchProject(to: s.projects[0])
    XCTAssertEqual(s.files.map(\.path), ["f.txt"])  // cached; the GUI's background rescan picks up late.txt
  }

  func testDirectoriesStartFolded() throws {
    let dir = URL.temporaryDirectory.appending(path: "clair-fold-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir.appending(path: "a/b"), withIntermediateDirectories: true)
    try "x".write(to: dir.appending(path: "a/b/f.txt"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appending(path: "top.txt"), atomically: true, encoding: .utf8)
    var s = WorkbenchState()
    try CommandRegistry.workbench.execute("project.open", ["path": .string(dir.path)], state: &s).get()
    XCTAssertEqual(s.collapsed, ["a", "a/b"])
  }

  // V11 `clair open`: the owning open Project wins (deepest root), else a Git root, else the folder.
  func testFileOpenResolvesOwnerThenGitRootThenFolder() throws {
    let outer = try folder("outer", ["a.txt", "inner/b.txt"]), inner = outer + "/inner"
    var s = WorkbenchState()
    open(outer, &s); open(inner, &s); open(outer, &s)
    XCTAssertEqual(r.execute("file.open", ["path": .string(inner + "/b.txt")], state: &s).success, .ok)
    XCTAssertEqual(s.project, "inner"); XCTAssertEqual(s.active, "b.txt")  // nested Project owns it, not outer
    r.execute("file.open", ["path": .string(outer + "/a.txt"), "line": .int(3)], state: &s)
    XCTAssertEqual(s.project, "outer"); XCTAssertEqual(s.active, "a.txt"); XCTAssertEqual(s.projects.count, 2)

    let repo = try folder("repo", ["src/m.swift", ".git/HEAD"])
    r.execute("file.open", ["path": .string(repo + "/src/m.swift")], state: &s)
    XCTAssertEqual(s.projects.last?.path, repo); XCTAssertEqual(s.active, "src/m.swift")  // Git root, not src/

    let loose = try folder("loose/deep", ["n.txt"])
    r.execute("file.open", ["path": .string(loose + "/n.txt")], state: &s)
    XCTAssertEqual(s.projects.last?.path, loose); XCTAssertEqual(s.active, "n.txt")  // no repo: its folder

    let skipped = try folder("outer/node_modules", ["p.js"])
    r.execute("file.open", ["path": .string(skipped + "/p.js")], state: &s)  // not in the scan, still opens
    XCTAssertEqual(s.project, "outer"); XCTAssertEqual(s.active, "node_modules/p.js")
  }

  func testFileOpenRejectsBadInput() throws {
    let a = try folder("a", ["f"])
    var s = WorkbenchState()
    for bad in [a, a + "/missing", "f"] {
      XCTAssertEqual(r.execute("file.open", ["path": .string(bad)], state: &s).failure?.code, .preconditionFailed, bad)
    }
    XCTAssertEqual(r.execute("file.open", ["path": .string(a + "/f"), "line": .int(0)], state: &s).failure?.code, .preconditionFailed)
    XCTAssertFalse(r.commands.first { $0.id == "file.open" }!.aiAvailable)
    XCTAssertTrue(s.projects.isEmpty)
  }

  func testShortcutAssignmentConflictClearAndPersistence() throws {
    var s = WorkbenchState()
    let set = { (c: String, k: String, s: inout WorkbenchState) in self.r.execute("shortcut.set", ["command": .string(c), "shortcut": .string(k)], state: &s) }
    XCTAssertEqual(set("pane.close", "⇧⌘x", &s).success, .ok)  // canonicalized
    XCTAssertEqual(s.shortcuts["pane.close"], "⌘⇧X")
    XCTAssertEqual(s.shortcut(for: r.commands.first { $0.id == "pane.close" }!), "⌘⇧X")
    XCTAssertEqual(set("pane.equalize", "⌘⇧X", &s).failure?.code, .preconditionFailed)  // taken
    XCTAssertEqual(set("pane.equalize", "⌃⌘W", &s).success, .ok)  // pane.close's old default is free now
    XCTAssertEqual(set("pane.equalize", "X", &s).failure?.code, .invalidInput)  // bare key
    XCTAssertEqual(set("pane.equalize", "⇧X", &s).failure?.code, .invalidInput)  // shift-only
    XCTAssertEqual(set("pane.equalize", "⌘⌘X", &s).failure?.code, .invalidInput)
    XCTAssertEqual(set("nope", "⌘X", &s).failure?.code, .invalidInput)
    XCTAssertEqual(set("tab.open", "⌘X", &s).failure?.code, .preconditionFailed)  // needs arguments
    XCTAssertEqual(set("file.save", "", &s).success, .ok)  // unassign a default
    XCTAssertNil(s.shortcut(for: r.commands.first { $0.id == "file.save" }!))
    XCTAssertFalse(r.commands.first { $0.id == "shortcut.set" }!.aiAvailable)
    let hint = r.paletteItems(.commands, query: "ペインを閉じる", state: s).first?.hint
    XCTAssertEqual(hint, "⌘⇧X")

    let a = try folder("a", ["f"])
    open(a, &s)
    let url = tmp.appending(path: "ws.json")
    try s.save(to: url)
    let got = try XCTUnwrap(WorkbenchState.restore(from: url))
    XCTAssertEqual(got.shortcuts, s.shortcuts)
  }
}

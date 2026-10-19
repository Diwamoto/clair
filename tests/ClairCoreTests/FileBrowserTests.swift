import XCTest

@testable import ClairWorkspace

/// ADR-0025: the file browser tab, terminal drops, and agents' file-operation proposals.
final class FileBrowserTests: XCTestCase {
  private var dir: String!

  override func setUpWithError() throws {
    dir = URL.temporaryDirectory.appending(path: "clair-finder-\(UUID().uuidString)").standardizedFileURL.path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

  private func touch(_ name: String, _ text: String = "hello\n") throws {
    let path = (dir as NSString).appendingPathComponent(name)
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }

  func testDroppedPathIsShellEscapedLikeGhostty() {
    XCTAssertEqual(FileBrowser.shellEscape("/Users/me/スクリーンショット 2026-10-18 (1).png"), #"/Users/me/スクリーンショット\ 2026-10-18\ \(1\).png"#)
    XCTAssertEqual(FileBrowser.shellEscape("/tmp/a'b$c&d"), #"/tmp/a\'b\$c\&d"#)
    XCTAssertEqual(FileBrowser.shellEscape("/plain/path.swift"), "/plain/path.swift")
  }

  func testListsOneLevelFoldersFirstAndHidesDotfilesUnlessAsked() throws {
    try touch("b.txt"); try touch("A.md"); try touch(".env"); try touch("src/deep/x.swift")
    let names = try FileBrowser.list(dir).map(\.name)
    XCTAssertEqual(names, ["src", "A.md", "b.txt"])
    XCTAssertTrue(try FileBrowser.list(dir, showHidden: true).contains { $0.name == ".env" && $0.isHidden })
    XCTAssertEqual(try FileBrowser.list(dir + "/src").map(\.name), ["deep"])  // never deeper than the folder asked for
  }

  func testTextDetectionAndPreviewHead() throws {
    try touch("note.md", (1...30).map { "line \($0)" }.joined(separator: "\n"))
    try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: URL(fileURLWithPath: dir + "/image.png"))
    XCTAssertTrue(FileBrowser.isText(dir + "/note.md"))
    XCTAssertFalse(FileBrowser.isText(dir + "/image.png"))
    XCTAssertEqual(FileBrowser.head(dir + "/note.md", lines: 3), "line 1\nline 2\nline 3")
    XCTAssertNil(FileBrowser.head(dir + "/image.png"))
  }

  func testPasteNamesACopyLikeFinder() throws {
    try touch("a.txt")
    XCTAssertEqual(FileBrowser.copyName("a.txt", isDirectory: false, taken: ["b"]), "a.txt")
    let made = try FileBrowser.paste([dir + "/a.txt", dir + "/a.txt"], into: dir)
    XCTAssertEqual(made.map { ($0 as NSString).lastPathComponent }, ["a \(copyWord).txt", "a \(copyWord) 2.txt"])
  }

  func testMentionIsProjectRelativeInsideTheRootElseAbsolute() {
    XCTAssertEqual(FileBrowser.mention("/p/root/src/a.swift", root: "/p/root"), "@src/a.swift")
    XCTAssertEqual(FileBrowser.mention("/elsewhere/a.pdf", root: "/p/root"), "@/elsewhere/a.pdf")
  }

  func testOpenRevealAndSelectionCommands() throws {
    let r = CommandRegistry.workbench
    var s = WorkbenchState()
    try touch("docs/a.md")
    _ = try r.execute("finder.open", ["path": .string(dir)], state: &s).get()
    let tab = FileBrowser.tabPath(dir)
    XCTAssertEqual(s.active, tab)
    XCTAssertEqual(s.browserNavigationGeneration, 1)
    XCTAssertFalse(s.findTargetsFocusedPane)  // ⌘F searches the Project, not a browser tab
    // Opening the same folder again reuses its tab.
    _ = try r.execute("finder.open", ["path": .string(dir + "/")], state: &s).get()
    XCTAssertEqual(s.tabs.filter { FileBrowser.root(tab: $0) != nil }.count, 1)
    if case .failure(let e) = r.execute("finder.open", ["path": .string(dir + "/docs/a.md")], state: &s) {
      XCTAssertEqual(e.code, .preconditionFailed)
    } else { XCTFail("a file is not a folder") }

    // An agent reveals a file: the active browser tab moves to its folder with it selected.
    _ = try r.execute("finder.reveal", ["path": .string(dir + "/docs/a.md")], state: &s).get()
    XCTAssertEqual(s.browserReveal, FileBrowserReveal(tab: tab, folder: dir + "/docs", select: dir + "/docs/a.md", seq: 1))
    XCTAssertTrue(r.commands.first { $0.id == "finder.reveal" }!.aiAvailable)
    XCTAssertFalse(r.commands.first { $0.id == "finder.open" }!.aiAvailable)

    // The selection is readable only while a browser tab is active.
    XCTAssertThrowsError(try r.execute("finder.selection", state: &s).get())
    s.browserContext = FileBrowserContext(folder: dir + "/docs", selection: [dir + "/docs/a.md"])
    guard case .text(let json) = try r.execute("finder.selection", state: &s).get() else { return XCTFail() }
    XCTAssertTrue(json.contains(#""selection":["\#(dir!)/docs/a.md"]"#), json)
  }

  func testBrowserTabSurvivesARescanAndReopensAfterClose() throws {
    let r = CommandRegistry.workbench
    var s = WorkbenchState()
    try touch("a.txt")
    s.openProject(WorkbenchProject(name: "p", path: dir), scanFiles: true)
    _ = try r.execute("finder.open", state: &s).get()
    let tab = FileBrowser.tabPath(dir)
    XCTAssertEqual(s.active, tab)
    s.refreshStatus(reconcileOpenFiles: true)
    XCTAssertTrue(s.tabs.contains(tab))
    _ = try r.execute("tab.close", ["path": .string(tab)], state: &s).get()
    _ = try r.execute("tab.reopenClosed", state: &s).get()
    XCTAssertEqual(s.active, tab)
  }

  func testProposalIsValidatedInsideItsFolder() throws {
    try touch("a.pdf"); try touch("b.png")
    let ok = try FileProposal.validate(#"[{"op":"mkdir","to":"PDF"},{"op":"move","from":"a.pdf","to":"PDF/a.pdf","why":"pdf"}]"#, folder: dir)
    XCTAssertEqual(ok.ops.map(\.to), [dir + "/PDF", dir + "/PDF/a.pdf"])
    func refused(_ ops: String) -> Error? {
      do { _ = try FileProposal.validate(ops, folder: dir); return nil } catch { return error }
    }
    XCTAssertNotNil(refused(#"[{"op":"move","from":"a.pdf","to":"../escape.pdf"}]"#), "outside the folder")
    XCTAssertNotNil(refused(#"[{"op":"trash","from":"/etc/hosts"}]"#), "absolute path outside")
    XCTAssertNotNil(refused(#"[{"op":"move","from":"missing.pdf","to":"x.pdf"}]"#), "missing source")
    XCTAssertNotNil(refused(#"[{"op":"rename","from":"a.pdf","to":"b.png"}]"#), "taken target")
    XCTAssertNotNil(refused(#"[{"op":"move","from":"a.pdf","to":"Nope/a.pdf"}]"#), "no folder for the target")
    XCTAssertNotNil(refused(#"[{"op":"move","from":"a.pdf","to":"c.pdf"},{"op":"move","from":"a.pdf","to":"d.pdf"}]"#), "moved twice")
    XCTAssertNotNil(refused("not json"))
    XCTAssertNotNil(refused("[]"))
  }

  func testProposalWaitsForTheUserAndAppliesOnlyWhatWasPicked() throws {
    let r = CommandRegistry.workbench
    var s = WorkbenchState()
    try touch("a.pdf"); try touch("old.txt")
    let ops = #"[{"op":"mkdir","to":"PDF"},{"op":"move","from":"a.pdf","to":"PDF/a.pdf"},{"op":"trash","from":"old.txt"}]"#
    guard case .text(let id) = try r.execute("finder.propose", ["folder": .string(dir), "ops": .string(ops)], state: &s).get() else { return XCTFail() }
    XCTAssertEqual(s.active, FileProposal.tabPrefix + id)
    XCTAssertEqual(s.fileProposals[id]?.state, .pending)
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/a.pdf"), "proposing moves nothing")
    XCTAssertTrue(r.commands.first { $0.id == "finder.propose" }!.aiAvailable)
    XCTAssertFalse(r.commands.first { $0.id == "finder.applyProposal" }!.aiAvailable, "only the user applies")

    // Trash makes applying destructive: it needs the GUI's confirmation.
    if case .failure(let e) = r.execute("finder.applyProposal", ["id": .string(id), "picked": .string("0,1,2")], state: &s) {
      XCTAssertEqual(e.code, .confirmationRequired)
    } else { XCTFail("trash needs confirmation") }

    // The user leaves the trash row unchecked.
    _ = try r.execute("finder.applyProposal", ["id": .string(id), "picked": .string("0,1")], state: &s).get()
    XCTAssertEqual(s.fileProposals[id]?.state, .applied)
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/PDF/a.pdf"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/old.txt"))
    guard case .text(let report) = try r.execute("finder.proposal", ["id": .string(id)], state: &s).get() else { return XCTFail() }
    XCTAssertTrue(report.contains(#""state":"applied""#) && report.contains(#""skipped":1"#), report)
    XCTAssertThrowsError(try r.execute("finder.applyProposal", ["id": .string(id), "picked": .string("2")], confirmed: true, state: &s).get())
  }

  func testRejectedProposalChangesNothing() throws {
    let r = CommandRegistry.workbench
    var s = WorkbenchState()
    try touch("a.txt")
    guard case .text(let id) = try r.execute("finder.propose", ["folder": .string(dir), "ops": .string(#"[{"op":"rename","from":"a.txt","to":"b.txt"}]"#)], state: &s).get() else { return XCTFail() }
    _ = try r.execute("finder.rejectProposal", ["id": .string(id)], state: &s).get()
    XCTAssertEqual(s.fileProposals[id]?.state, .rejected)
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/a.txt"))
  }

  func testCLIRevealResolvesAgainstTheCallersDirectory() {
    let req = WorkbenchCLI.parse(["reveal", "notes/a.md"])
    XCTAssertEqual(req?.command, "finder.reveal")
    XCTAssertEqual(req?.input["path"], .string(FileManager.default.currentDirectoryPath + "/notes/a.md"))
    XCTAssertEqual(WorkbenchCLI.parse(["finder.propose", "folder=.", "ops=[]"])?.input["folder"], .string(FileManager.default.currentDirectoryPath))
  }
}

/// The copy suffix in the current UI language (English by default).
private let copyWord = "copy"

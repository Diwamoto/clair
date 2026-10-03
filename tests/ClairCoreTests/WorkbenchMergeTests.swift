import Foundation
import XCTest

@testable import ClairWorkspace

/// Merge conflicts, partial staging and agent instruction files.
final class WorkbenchMergeTests: XCTestCase {
  func testConflictBlocksParseWithLabelsAndBase() {
    let text = """
      keep
      <<<<<<< HEAD
      ours 1
      ours 2
      ||||||| base
      old
      =======
      theirs
      >>>>>>> feature
      middle
      <<<<<<< HEAD
      a
      =======
      >>>>>>> other
      <<<<<<< broken
      never closed
      """
    let c = MergeConflict.parse(text)
    XCTAssertEqual(c.count, 2)
    XCTAssertEqual([c[0].startLine, c[0].endLine], [1, 8])
    XCTAssertEqual(c[0].ours, ["ours 1", "ours 2"])
    XCTAssertEqual(c[0].base, ["old"])
    XCTAssertEqual(c[0].theirs, ["theirs"])
    XCTAssertEqual([c[0].oursLabel, c[0].theirsLabel], ["HEAD", "feature"])
    XCTAssertEqual(c[1].theirs, [])
    XCTAssertNil(c[1].base)
    XCTAssertEqual(c[0].resolution(.both), ["ours 1", "ours 2", "theirs"])
    XCTAssertEqual(c[1].resolution(.theirs), [])
    XCTAssertEqual(MergeConflict.parse("<<<<<<< a\r\nx\r\n=======\r\ny\r\n>>>>>>> b\r\n").first?.ours, ["x"])  // CRLF
    XCTAssertTrue(MergeConflict.parse("no conflicts\n").isEmpty)
  }

  func testConflictedStatusesAreTheUnmergedOnes() {
    func change(_ x: Character, _ y: Character) -> GitChange { GitChange(path: "f", index: x, worktree: y) }
    for (x, y) in [("U", "U"), ("A", "A"), ("D", "D"), ("A", "U"), ("U", "D")] as [(Character, Character)] {
      XCTAssertTrue(change(x, y).conflicted, "\(x)\(y)")
    }
    for (x, y) in [("M", " "), (" ", "M"), ("A", " "), ("?", "?"), ("D", " ")] as [(Character, Character)] {
      XCTAssertFalse(change(x, y).conflicted, "\(x)\(y)")
    }
  }

  private func rows(_ diff: String) -> [DiffLine] {
    // The diff view's numbering: old for context/removed, new for context/added.
    var o = 1, n = 1
    return diff.split(separator: "\n", omittingEmptySubsequences: false).map { l in
      let t = String(l)
      if t.hasPrefix("-") { defer { o += 1 }; return DiffLine(text: t, oldLine: o, newLine: nil) }
      if t.hasPrefix("+") { defer { n += 1 }; return DiffLine(text: t, oldLine: nil, newLine: n) }
      defer { o += 1; n += 1 }
      return DiffLine(text: t, oldLine: o, newLine: n)
    }
  }

  func testBlocksAndOneHunkPatches() {
    let lines = rows(" a\n b\n-c\n+C\n d\n e\n f\n g\n h\n+i\n j")
    XCTAssertEqual(GitPatch.blocks(lines), [2..<4, 9..<10])
    let first = GitPatch.patch(path: "src/x.txt", rows: lines, block: 2..<4)
    XCTAssertEqual(first, "diff --git a/src/x.txt b/src/x.txt\n--- a/src/x.txt\n+++ b/src/x.txt\n@@ -1,6 +1,6 @@\n a\n b\n-c\n+C\n d\n e\n f\n")
    let second = GitPatch.patch(path: "src/x.txt", rows: lines, block: 9..<10, context: 1)
    XCTAssertTrue(second.hasSuffix("@@ -8,2 +8,3 @@\n h\n+i\n j\n"), second)
  }

  func testStagePatchStagesOneBlockInARealRepository() throws {
    let root = URL.temporaryDirectory.appending(path: "clair-patch-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: String...) { WorkbenchGit.run(root.path, ["-c", "user.name=t", "-c", "user.email=t@t"] + args, merge: true) }
    git("init", "-q")
    let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try original.write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
    git("add", "f.txt"); git("commit", "-qm", "init")
    var edited = original.replacingOccurrences(of: "line 2\n", with: "LINE 2\n")
    edited = edited.replacingOccurrences(of: "line 18\n", with: "LINE 18\n")
    try edited.write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
    var s = WorkbenchState()
    try CommandRegistry.workbench.execute("project.open", ["path": .string(root.path)], state: &s).get()
    let diff = WorkbenchGit.diff(root.path, "f.txt", staged: false, fullContext: true)
    let body = diff.split(separator: "\n", omittingEmptySubsequences: false).drop { !$0.hasPrefix("@@") }.dropFirst().joined(separator: "\n")
    let lines = rows(body)
    let blocks = GitPatch.blocks(lines)
    XCTAssertEqual(blocks.count, 2)
    let patch = GitPatch.patch(path: "f.txt", rows: lines, block: blocks[0])
    XCTAssertEqual(try CommandRegistry.workbench.execute("git.stagePatch", ["patch": .string(patch)], state: &s).get(), .ok)
    let staged = WorkbenchGit.diff(root.path, "f.txt", staged: true)
    XCTAssertTrue(staged.contains("+LINE 2") && !staged.contains("+LINE 18"), staged)
    // Unstaging the same block from the staged diff empties the index again.
    let stagedBody = WorkbenchGit.diff(root.path, "f.txt", staged: true, fullContext: true)
      .split(separator: "\n", omittingEmptySubsequences: false).drop { !$0.hasPrefix("@@") }.dropFirst().joined(separator: "\n")
    let stagedLines = rows(stagedBody)
    let back = GitPatch.patch(path: "f.txt", rows: stagedLines, block: GitPatch.blocks(stagedLines)[0])
    XCTAssertEqual(
      try CommandRegistry.workbench.execute("git.stagePatch", ["patch": .string(back), "reverse": .bool(true)], state: &s).get(), .ok)
    XCTAssertTrue(WorkbenchGit.diff(root.path, "f.txt", staged: true).isEmpty)
    // A patch that names two files, or leaves the Project, is refused before git sees it.
    let two = patch + "diff --git a/g b/g\n"
    XCTAssertEqual(CommandRegistry.workbench.execute("git.stagePatch", ["patch": .string(two)], state: &s).failure?.code, .invalidInput)
    let escape = patch.replacingOccurrences(of: "a/f.txt", with: "a/../f.txt")
    XCTAssertEqual(CommandRegistry.workbench.execute("git.stagePatch", ["patch": .string(escape)], state: &s).failure?.code, .invalidInput)
  }

  func testInstructionFilesAreCreatedOnceAndOpened() throws {
    let root = URL.temporaryDirectory.appending(path: "clair-agents-md-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var s = WorkbenchState()
    try CommandRegistry.workbench.execute("project.open", ["path": .string(root.path)], state: &s).get()
    try CommandRegistry.workbench.execute("agent.editAgentsMd", state: &s).get()
    let file = root.appending(path: "AGENTS.md")
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    XCTAssertEqual(s.active, "AGENTS.md")
    try "mine".write(to: file, atomically: true, encoding: .utf8)
    try CommandRegistry.workbench.execute("agent.editAgentsMd", state: &s).get()
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mine")  // never overwritten
    XCTAssertEqual(CommandRegistry.workbench.commands.first { $0.id == "agent.editClaudeMd" }?.aiAvailable, false)
  }
}

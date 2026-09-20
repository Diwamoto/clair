import XCTest

@testable import ClairV2Workspace

/// V06: stage/commit/switch, managed worktree lifecycle, adoption, branch review.
final class WorkbenchGitTests: XCTestCase {
  let r = CommandRegistry.workbench

  func sh(_ dir: String, _ args: String...) { WorkbenchGit.run(dir, ["-c", "user.name=t", "-c", "user.email=t@t"] + args) }

  func repo() throws -> (WorkbenchState, String) {
    let base = URL.temporaryDirectory.appending(path: "clair-v06-\(UUID().uuidString)").resolvingSymlinksInPath()
    let dir = base.appending(path: "repo")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    WorkbenchGit.worktreeBase = base.appending(path: "wt")
    sh(dir.path, "init", "-b", "main")
    try "a".write(to: dir.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    sh(dir.path, "add", "."); sh(dir.path, "commit", "-m", "init")
    var s = WorkbenchState()
    try r.execute("project.open", ["path": .string(dir.path)], state: &s).get()
    return (s, dir.path)
  }

  func testWaitWithoutRunLoopReturnsStatus() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/false")
    try p.run(); p.waitWithoutRunLoop()
    XCTAssertEqual(p.terminationStatus, 1)
  }

  func testStageCommitAndNothingStaged() throws {
    var (s, root) = try repo()
    try "b".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    s.refreshStatus()
    XCTAssertEqual(r.execute("git.commit", ["message": .string("x")], state: &s).failure?.code, .preconditionFailed)
    try r.execute("git.stage", ["path": .string("a.txt")], state: &s).get()
    try r.execute("git.commit", ["message": .string("edit")], state: &s).get()
    XCTAssertNil(s.files.first { $0.path == "a.txt" }?.status)
    XCTAssertEqual(r.execute("git.stage", ["path": .string("../etc/passwd")], state: &s).failure?.code, .preconditionFailed)
  }

  func testNonGitProjectHasNoGitCommands() throws {
    let dir = URL.temporaryDirectory.appending(path: "clair-v06-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var s = WorkbenchState()
    try r.execute("project.open", ["path": .string(dir.path)], state: &s).get()
    XCTAssertEqual(r.execute("git.review", state: &s).failure?.code, .preconditionFailed)
    XCTAssertFalse(r.paletteItems(.commands, query: "", state: s).contains { $0.id.hasPrefix("git.") || $0.id.hasPrefix("worktree.") })
  }

  func testWorktreeLifecycleReviewAdoptRemove() throws {
    var (s, root) = try repo()
    XCTAssertEqual(r.execute("git.review", state: &s).success.map { if case .review = $0 { true } else { false } }, true)
    try r.execute("worktree.create", ["branch": .string("feat/x")], state: &s).get()
    let wt = try XCTUnwrap(s.current)
    XCTAssertEqual(wt.origin, root)
    XCTAssertFalse(wt.path.hasPrefix(root))  // outside the repository
    // agent launch cwd = the worktree
    try r.execute("agent.launch", ["profile": .string("claude")], confirmed: true, state: &s).get()
    XCTAssertEqual(s.launches.values.first?.cwd, wt.path)
    // uncommitted and untracked are separated from committed; adoption needs a clean tree
    try "n".write(toFile: wt.path + "/n.txt", atomically: true, encoding: .utf8)
    s.refreshStatus()
    XCTAssertEqual(r.execute("worktree.adopt", state: &s).failure?.code, .preconditionFailed)
    guard case .review(let rv) = try r.execute("git.review", state: &s).get() else { return XCTFail() }
    XCTAssertEqual(rv.untracked, ["n.txt"]); XCTAssertTrue(rv.committed.isEmpty)
    try r.execute("git.stage", ["path": .string("n.txt")], state: &s).get()
    try r.execute("git.commit", ["message": .string("add n")], state: &s).get()
    guard case .review(let rv2) = try r.execute("git.review", state: &s).get() else { return XCTFail() }
    XCTAssertEqual(rv2.committed, ["A\tn.txt"]); XCTAssertTrue(rv2.untracked.isEmpty)
    try r.execute("worktree.adopt", state: &s).get()
    XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/n.txt"))
    // destructive ops need individual confirmation; removal returns to the origin project
    XCTAssertEqual(r.execute("worktree.remove", state: &s).failure?.code, .confirmationRequired)
    try r.execute("worktree.remove", confirmed: true, state: &s).get()
    XCTAssertEqual(s.current?.path, root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
    XCTAssertEqual(r.execute("git.branchDelete", ["name": .string("feat/x")], state: &s).failure?.code, .confirmationRequired)
    try r.execute("git.branchDelete", ["name": .string("feat/x")], confirmed: true, state: &s).get()
  }

  func testConflictIsAbortedAndReported() throws {
    var (s, root) = try repo()
    try r.execute("worktree.create", ["branch": .string("c")], state: &s).get()
    let wt = s.current!.path
    try "wt".write(toFile: wt + "/a.txt", atomically: true, encoding: .utf8)
    sh(wt, "commit", "-am", "wt")
    try "origin".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    sh(root, "commit", "-am", "origin")
    guard case .text(let msg) = try r.execute("worktree.adopt", state: &s).get() else { return XCTFail("expected conflict text") }
    XCTAssertTrue(msg.contains("aborted"))
    XCTAssertTrue(WorkbenchGit.isClean(root))  // merge state left no residue
  }

  func testBadBranchNamesRejected() throws {
    var (s, _) = try repo()
    XCTAssertEqual(r.execute("worktree.create", ["branch": .string("-x")], state: &s).failure?.code, .invalidInput)
    XCTAssertEqual(r.execute("git.switch", ["name": .string("a b")], state: &s).failure?.code, .invalidInput)
  }

  func testChangesAndDiff() throws {
    let (_, root) = try repo()
    try "b".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    try "n".write(toFile: root + "/new.txt", atomically: true, encoding: .utf8)
    sh(root, "add", "a.txt")
    try "c".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    let c = WorkbenchGit.changes(root)
    XCTAssertEqual(c.first { $0.path == "a.txt" }.map { [$0.staged, $0.unstaged] }, [true, true])
    XCTAssertEqual(c.first { $0.path == "new.txt" }?.untracked, true)
    XCTAssertTrue(WorkbenchGit.diff(root, "a.txt", staged: true).contains("+b"))
    XCTAssertTrue(WorkbenchGit.diff(root, "a.txt", staged: false).contains("+c"))
    XCTAssertTrue(WorkbenchGit.diff(root, "new.txt", staged: false, untracked: true).contains("+n"))
  }
}

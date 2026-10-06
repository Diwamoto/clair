import XCTest

@testable import ClairWorkspace

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

  func testDailyCommitsCountsTheUsersOwnNonMergeCommits() throws {
    let dir = URL.temporaryDirectory.appending(path: "clair-usage-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    XCTAssertNil(WorkbenchGit.dailyCommits(dir.path, since: .distantPast))
    sh(dir.path, "init", "-b", "main")
    WorkbenchGit.run(dir.path, ["config", "user.email", "me+clair@example.com"])
    WorkbenchGit.run(dir.path, ["config", "user.name", "me"])
    WorkbenchGit.run(dir.path, ["commit", "--allow-empty", "-m", "mine 1"])
    WorkbenchGit.run(dir.path, ["commit", "--allow-empty", "-m", "mine 2"])
    WorkbenchGit.run(dir.path, ["-c", "user.email=other@example.com", "commit", "--allow-empty", "-m", "theirs"])
    WorkbenchGit.run(dir.path, ["switch", "-c", "side"])
    WorkbenchGit.run(dir.path, ["commit", "--allow-empty", "-m", "mine on side"])
    WorkbenchGit.run(dir.path, ["switch", "main"])
    WorkbenchGit.run(dir.path, ["merge", "--no-ff", "-m", "merge side", "side"])
    let counts = try XCTUnwrap(WorkbenchGit.dailyCommits(dir.path, since: Date().addingTimeInterval(-3600)))
    XCTAssertEqual(counts.values.reduce(0, +), 3)
    XCTAssertEqual(counts.keys.first, Calendar.current.startOfDay(for: .now))
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

    try FileManager.default.removeItem(atPath: root + "/a.txt")
    // A watcher/full scan may already have removed the deleted row from the tree.
    s.files.removeAll { $0.path == "a.txt" }
    XCTAssertFalse(s.files.contains { $0.path == "a.txt" })
    try r.execute("git.stage", ["path": .string("a.txt")], state: &s).get()
    XCTAssertTrue(WorkbenchGit.changes(root).first { $0.path == "a.txt" }?.staged == true)
    try r.execute("git.unstage", ["path": .string("a.txt")], state: &s).get()
    XCTAssertTrue(WorkbenchGit.changes(root).first { $0.path == "a.txt" }?.unstaged == true)
  }

  func testDiscardRestoresWorktreeAndDeletesUntracked() throws {
    var (s, root) = try repo()
    try "b".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    try "n".write(toFile: root + "/new.txt", atomically: true, encoding: .utf8)
    s.refreshStatus()
    XCTAssertEqual(r.execute("git.discard", ["path": .string("a.txt")], state: &s).failure?.code, .confirmationRequired)
    try r.execute("git.discard", ["path": .string("a.txt")], confirmed: true, state: &s).get()
    XCTAssertEqual(try String(contentsOfFile: root + "/a.txt", encoding: .utf8), "a")
    try r.execute("git.discard", ["path": .string("new.txt")], confirmed: true, state: &s).get()
    XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/new.txt"))
    XCTAssertEqual(r.execute("git.discard", ["path": .string("a.txt")], confirmed: true, state: &s).failure?.code, .preconditionFailed)
  }

  func testDiscardStagedGoesBackToHead() throws {
    var (s, root) = try repo()
    try "b".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    try "n".write(toFile: root + "/new.txt", atomically: true, encoding: .utf8)
    try r.execute("git.stage", ["path": .string("a.txt")], state: &s).get()
    try r.execute("git.stage", ["path": .string("new.txt")], state: &s).get()
    let staged: CommandInput = ["staged": .bool(true)]
    try r.execute("git.discard", ["path": .string("a.txt")] .merging(staged) { $1 }, confirmed: true, state: &s).get()
    try r.execute("git.discard", ["path": .string("new.txt")] .merging(staged) { $1 }, confirmed: true, state: &s).get()
    XCTAssertEqual(try String(contentsOfFile: root + "/a.txt", encoding: .utf8), "a")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/new.txt"))
    XCTAssertTrue(WorkbenchGit.changes(root).isEmpty)
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
    sh(wt.path, "branch", "feat/y")
    try r.execute("git.switch", ["name": .string("feat/y")], state: &s).get()
    XCTAssertEqual(s.current?.branch, "feat/y")
    try "y".write(toFile: wt.path + "/y.txt", atomically: true, encoding: .utf8)
    sh(wt.path, "add", "."); sh(wt.path, "commit", "-m", "add y")
    guard case .review(let rv2) = try r.execute("git.review", state: &s).get() else { return XCTFail() }
    XCTAssertEqual(rv2.committed, ["A\tn.txt", "A\ty.txt"]); XCTAssertTrue(rv2.untracked.isEmpty)
    try r.execute("worktree.adopt", state: &s).get()
    XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/n.txt"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/y.txt"))
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

  func testBranchCreateSwitchesToNewBranchAndRefusesExisting() throws {
    var (s, root) = try repo()
    s.dirty = ["a.txt"]  // switch -c keeps the working tree, so unsaved buffers don't block it
    try r.execute("git.branchCreate", ["name": .string("feat/new")], state: &s).get()
    XCTAssertEqual(WorkbenchGit.currentBranch(root), "feat/new")
    XCTAssertEqual(r.execute("git.branchCreate", ["name": .string("main")], state: &s).failure?.code, .preconditionFailed)
    XCTAssertEqual(r.execute("git.branchCreate", ["name": .string("a b")], state: &s).failure?.code, .invalidInput)
    try r.execute("git.branches", state: &s).get()
    XCTAssertEqual(s.palette, .branches)
  }

  func testBranchesSwitchAndRemoteCommandsUseTypedRegistry() throws {
    var (s, root) = try repo()
    sh(root, "branch", "topic")
    XCTAssertEqual(WorkbenchGit.branches(root), ["main", "topic"])
    s.dirty = ["a.txt"]
    XCTAssertEqual(r.execute("git.switch", ["name": .string("topic")], state: &s).failure?.code, .preconditionFailed)
    s.dirty = []
    try r.execute("git.switch", ["name": .string("topic")], state: &s).get()
    XCTAssertEqual(WorkbenchGit.currentBranch(root), "topic")
    try r.execute("git.switch", ["name": .string("main")], state: &s).get()

    XCTAssertEqual(r.execute("git.pull", state: &s).failure?.code, .preconditionFailed)
    XCTAssertEqual(r.execute("git.push", state: &s).failure?.code, .preconditionFailed)

    let remote = URL.temporaryDirectory.appending(path: "clair-v06-remote-\(UUID().uuidString).git").path
    XCTAssertTrue(WorkbenchGit.run(root, ["clone", "--bare", root, remote], merge: true).ok)
    sh(root, "remote", "add", "origin", remote)
    XCTAssertTrue(WorkbenchGit.run(root, ["push", "-u", "origin", "main"], merge: true).ok)

    let peer = URL.temporaryDirectory.appending(path: "clair-v06-peer-\(UUID().uuidString).path").path
    XCTAssertTrue(WorkbenchGit.run(root, ["clone", remote, peer], merge: true).ok)
    sh(peer, "config", "user.name", "t"); sh(peer, "config", "user.email", "t@t")
    try "remote".write(toFile: peer + "/remote.txt", atomically: true, encoding: .utf8)
    sh(peer, "add", "."); sh(peer, "commit", "-m", "remote"); sh(peer, "push")

    XCTAssertEqual(r.execute("git.pull", state: &s).failure?.code, .confirmationRequired)
    try r.execute("git.pull", confirmed: true, state: &s).get()
    XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/remote.txt"))
    XCTAssertTrue(s.files.contains { $0.path == "remote.txt" })

    try "local".write(toFile: root + "/local.txt", atomically: true, encoding: .utf8)
    sh(root, "add", "."); sh(root, "commit", "-m", "local")
    XCTAssertEqual(r.execute("git.push", state: &s).failure?.code, .confirmationRequired)
    try r.execute("git.push", confirmed: true, state: &s).get()
    XCTAssertEqual(
      WorkbenchGit.run(root, ["rev-parse", "HEAD"]).out,
      WorkbenchGit.run(remote, ["rev-parse", "main"]).out)
  }

  func testRemoteAuthenticationFailureIsActionable() {
    let message = WorkbenchGit.remoteFailure("Push", output: "fatal: could not read Username; terminal prompts disabled")
    XCTAssertTrue(message.contains("Authentication required"))
    XCTAssertTrue(message.contains("terminal"))
  }

  /// V14: a hung child is killed at the deadline instead of pinning its caller; the pipe read returns.
  func testSubprocessDeadlineEndsAHungChild() throws {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["30"]
    p.standardOutput = out
    try p.run()
    let deadline = p.terminate(after: 0.2)
    let start = Date()
    _ = out.fileHandleForReading.readDataToEndOfFile()
    p.waitWithoutRunLoop()
    deadline.cancel()
    XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    XCTAssertEqual(p.terminationReason, .uncaughtSignal)
  }

  func testGitRunSuppressesAskpassProcesses() throws {
    let (_, root) = try repo()
    let directory = URL.temporaryDirectory.appending(path: "clair-v06-askpass-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = directory.appending(path: "askpass")
    let invoked = directory.appending(path: "invoked")
    try "#!/bin/sh\ntouch '\(invoked.path)'\necho secret\n".write(to: probe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)

    let previous = ProcessInfo.processInfo.environment["GIT_ASKPASS"]
    setenv("GIT_ASKPASS", probe.path, 1)
    defer {
      if let previous { setenv("GIT_ASKPASS", previous, 1) } else { unsetenv("GIT_ASKPASS") }
    }
    let result = WorkbenchGit.run(
      root,
      ["-c", "credential.helper=", "-c", "core.askPass=\(probe.path)", "credential", "fill"],
      merge: true,
      input: "protocol=https\nhost=example.invalid\nusername=test\n\n")
    XCTAssertFalse(result.ok)
    XCTAssertFalse(FileManager.default.fileExists(atPath: invoked.path))
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

  func testCompareTwoFiles() throws {
    let (_, root) = try repo()
    try "same\nleft\n".write(toFile: root + "/l.txt", atomically: true, encoding: .utf8)
    try "same\nright\n".write(toFile: root + "/r.txt", atomically: true, encoding: .utf8)
    let d = WorkbenchGit.diff(root, "r.txt", staged: false, against: "l.txt", fullContext: true)
    XCTAssertTrue(d.contains("-left") && d.contains("+right") && d.contains(" same"))
  }

  func testFullContextDiffIncludesUnchangedBeginningAndEnd() throws {
    let (_, root) = try repo()
    let original = (1...30).map { "line \($0)" }
    try original.joined(separator: "\n").write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    sh(root, "add", "a.txt"); sh(root, "commit", "-m", "expand")
    var edited = original
    edited[14] = "changed line 15"
    try edited.joined(separator: "\n").write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    XCTAssertFalse(WorkbenchGit.diff(root, "a.txt", staged: false).contains(" line 1\n"))
    let full = WorkbenchGit.diff(root, "a.txt", staged: false, fullContext: true)
    XCTAssertTrue(full.contains(" line 1\n"))
    XCTAssertTrue(full.contains("+changed line 15\n"))
    XCTAssertTrue(full.contains(" line 30"))
  }

  func testBatchStageAndUnstagePreservesPorcelainColumns() throws {
    let (_, root) = try repo()
    try "b".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    try "n".write(toFile: root + "/new.txt", atomically: true, encoding: .utf8)
    XCTAssertNil(WorkbenchGit.setStaged(root, paths: ["a.txt", "new.txt"], staged: true))
    XCTAssertTrue(WorkbenchGit.changes(root).allSatisfy(\.staged))
    XCTAssertNil(WorkbenchGit.setStaged(root, paths: ["a.txt", "new.txt"], staged: false))
    let changes = WorkbenchGit.changes(root)
    XCTAssertEqual(changes.first { $0.path == "a.txt" }.map { [$0.staged, $0.unstaged] }, [false, true])
    XCTAssertEqual(changes.first { $0.path == "new.txt" }?.untracked, true)
  }

  // V16: a child agent can get its own managed worktree without switching the shown Project.
  func testAgentLaunchInNewWorktreeKeepsProject() throws {
    var (s, root) = try repo()
    s.tree = PaneTree()  // editor | agent / terminal: the layout these tests place into, not the single-editor default
    let shown = s.project
    guard case .text(let key) = try r.execute(
      "agent.launch", ["profile": .string("claude"), "branch": .string("agent/a"), "parent": .string(root + "#2")],
      confirmed: true, state: &s
    ).get() else { return XCTFail() }
    XCTAssertEqual(s.project, shown)
    let wt = try XCTUnwrap(s.projects.first { $0.branch == "agent/a" })
    XCTAssertEqual(wt.origin, root)
    XCTAssertEqual(s.launches[Int(key.split(separator: "#").last!)!]?.cwd, wt.path)
    XCTAssertEqual(r.execute("agent.launch", ["profile": .string("claude"), "branch": .string("agent/a"), "parent": .string(root + "#2")], confirmed: true, state: &s).failure?.code, .preconditionFailed)
  }

  /// #53: git calls from background threads leaked a pipe fd each until the updater could no longer spawn ditto.
  func testBackgroundGitCallsDoNotLeakFileDescriptors() async {
    func open() -> Int { (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
    let before = open()
    await Task.detached { for _ in 0..<100 { WorkbenchGit.run("/", ["--version"]) } }.value
    try? await Task.sleep(for: .seconds(3))  // Foundation reclaims a waited process's fds asynchronously
    XCTAssertLessThan(open() - before, 30)
  }
}

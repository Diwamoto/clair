import Foundation

// V06: Git/worktree workflow on top of the command registry. Shells out to /usr/bin/git with an
// argv array (never a shell), so branch/path/message text cannot inject anything. Only Projects
// that are Git repositories get these commands (`WorkbenchState.isRepo`).
// Managed worktrees live outside the repository and are opened as their own Project.
// Calls are synchronous; UI callers dispatch the typed commands off the main actor.
// ponytail: conflicts are aborted and reported (re-ask the agent); a native merge editor is not built.

#if os(macOS)
extension Process {
  /// `waitUntilExit()` spins the current run loop, so on the main thread SwiftUI re-renders mid-wait — while a
  /// `store.state` mutation that called us is still open — and traps on exclusive access. Poll instead.
  func waitWithoutRunLoop() { while isRunning { usleep(2000) } }

  /// Terminates the child if it outlives `seconds`, so a hung git (credential helper, network, index lock) cannot pin
  /// its caller forever. Arm before reading the pipe — `readDataToEndOfFile` only returns once the child exits.
  /// Cancel the returned item after the wait. Captures the pid, not the non-Sendable `Process`.
  func terminate(after seconds: Double) -> DispatchWorkItem {
    let pid = processIdentifier
    let item = DispatchWorkItem { kill(pid, SIGTERM) }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
    return item
  }
}
#endif

public struct GitReview: Sendable, Codable, Equatable {
  public var base: String?
  /// `git diff base...HEAD --name-status` lines — already committed on this branch.
  public var committed: [String]
  /// Tracked changes not yet committed (staged + unstaged).
  public var uncommitted: [String]
  public var untracked: [String]
}

public enum WorkbenchGit {
  /// Managed worktrees root. Tests point this at a temp dir.
  nonisolated(unsafe) public static var worktreeBase = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Clair/worktrees")

  /// Upper bound for one git subprocess. Generous because pull/push go over the network; it exists so a stall ends.
  static let timeout = 120.0

  @discardableResult
  static func run(_ root: String, _ args: [String], merge: Bool = false, input: String? = nil) -> (ok: Bool, out: String) {
    #if os(macOS)
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", root] + args
    p.environment = ProcessInfo.processInfo.environment.merging([
      "GIT_TERMINAL_PROMPT": "0",
      "GCM_INTERACTIVE": "never",
      "GIT_ASKPASS": "/usr/bin/false",
      "SSH_ASKPASS": "/usr/bin/false",
      "SSH_ASKPASS_REQUIRE": "never",
      "GIT_SSH_COMMAND": "/usr/bin/ssh -oBatchMode=yes",
    ]) { _, commandValue in commandValue }
    p.standardOutput = out; p.standardError = merge ? out : FileHandle.nullDevice
    let stdin = input.map { _ in Pipe() }
    p.standardInput = stdin ?? FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (false, "git not runnable") }
    let deadline = p.terminate(after: timeout)
    defer { deadline.cancel() }
    if let input, let stdin {
      stdin.fileHandleForWriting.write(Data(input.utf8))
      try? stdin.fileHandleForWriting.close()
    }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitWithoutRunLoop()
    if p.terminationReason == .uncaughtSignal {
      return (false, "git が \(Int(timeout)) 秒以内に終わらなかったため中断しました。\n\(text)")
    }
    // Keep leading spaces: porcelain status uses them as the index/worktree column,
    // and unified diff context lines are also significant. Only strip line endings.
    return (p.terminationStatus == 0, text.trimmingCharacters(in: .newlines))
    #else
    return (false, "git is not available on iOS")
    #endif
  }

  static func lines(_ root: String, _ args: [String]) -> [String] {
    let r = run(root, args)
    return r.ok ? r.out.split(separator: "\n").map(String.init) : []
  }

  static func validBranch(_ name: String) -> Bool { run(".", ["check-ref-format", "--branch", name]).ok }
  static func branchExists(_ root: String, _ name: String) -> Bool { run(root, ["rev-parse", "--verify", "-q", "refs/heads/\(name)"]).ok }
  public static func currentBranch(_ root: String) -> String? {
    let r = run(root, ["rev-parse", "--abbrev-ref", "HEAD"]); return r.ok && r.out != "HEAD" ? r.out : nil
  }
  public static func branches(_ root: String) -> [String] {
    lines(root, ["for-each-ref", "--format=%(refname:short)", "--sort=refname", "refs/heads"])
  }
  /// Commits behind / ahead of the upstream; nil without one.
  public static func aheadBehind(_ root: String) -> (behind: Int, ahead: Int)? {
    let r = run(root, ["rev-list", "--left-right", "--count", "@{u}...HEAD"])
    let n = r.out.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    return r.ok && n.count == 2 ? (n[0], n[1]) : nil
  }
  /// Stage or unstage a validated group in one subprocess. This is materially cheaper than
  /// spawning git and rescanning the repository once per sidebar row.
  @discardableResult public static func setStaged(_ root: String, paths: [String], staged: Bool) -> String? {
    guard !paths.isEmpty else { return nil }
    let verb = staged ? ["add"] : ["restore", "--staged"]
    let result = run(root, verb + ["--"] + paths, merge: true)
    return result.ok ? nil : result.out
  }

  @discardableResult public static func commit(_ root: String, message: String) -> String? {
    let result = run(root, ["commit", "-m", message], merge: true)
    return result.ok ? nil : result.out
  }
  static func isClean(_ root: String) -> Bool { run(root, ["status", "--porcelain"]).out.isEmpty }

  static func remoteFailure(_ action: String, output: String) -> String {
    let lower = output.lowercased()
    let authentication = [
      "authentication failed", "could not read username", "permission denied (publickey)",
      "terminal prompts disabled", "credentials", "repository not found",
    ].contains { lower.contains($0) }
    let detail = output.isEmpty ? "Git から詳細が返りませんでした。" : output
    return authentication
      ? "認証が必要です。ターミナルで Git の認証を設定してください。\n\(detail)"
      : "\(action) に失敗しました。\n\(detail)"
  }
}

extension WorkbenchState {
  var current: WorkbenchProject? { projects.first { $0.name == project } }
  /// False for a plain folder: Git commands are neither listed nor runnable.
  public var isRepo: Bool { current.map { FileManager.default.fileExists(atPath: $0.path + "/.git") } ?? false }

  mutating func refreshStatus(reconcileOpenFiles: Bool = false) {
    guard let p = current else { return }
    if reconcileOpenFiles {
      let scanned = WorkbenchFiles.scan(p.path)
      files = scanned
      filesCache[project] = scanned
      let existing = Set(scanned.map(\.path))
      tabs = tabs.filter(existing.contains)
      dirty.formIntersection(tabs)
      if active.map(tabs.contains) != true { active = tabs.last }
      return
    }
    let status = WorkbenchFiles.gitStatus(p.path)
    var known = Set<String>()
    var refreshed = files.compactMap { file -> WorkbenchFile? in
      known.insert(file.path)
      // A D row is retained while Git reports it, then removed on the refresh after commit.
      // The watcher owns arbitrary filesystem removals, so this hot Git path needs no 20k-file stat walk.
      guard file.status != "D" || status[file.path] != nil else { return nil }
      return WorkbenchFile(path: file.path, status: status[file.path])
    }
    // Preserve the already tree-ordered list. New Git-visible paths are deterministic here;
    // the file watcher performs the canonical full tree-order scan in the background.
    for path in status.keys.filter({ !known.contains($0) }).sorted() {
      refreshed.append(WorkbenchFile(path: path, status: status[path]))
    }
    files = refreshed
  }

  func review(base: String?) -> GitReview {
    let root = current!.path
    let base = base ?? current?.origin.flatMap(WorkbenchGit.currentBranch)
      ?? ["main", "master"].first { WorkbenchGit.branchExists(root, $0) }
    let committed = base.map { WorkbenchGit.lines(root, ["diff", "--name-status", "\($0)...HEAD"]) } ?? []
    let changes = WorkbenchGit.changes(root)
    return GitReview(
      base: base, committed: committed,
      uncommitted: changes.filter { !$0.untracked }.map {
        "\($0.index != " " ? $0.index : $0.worktree)\t\($0.path)"
      },
      untracked: changes.filter(\.untracked).map(\.path))
  }
}

extension CommandRegistry {
  static let gitCommands: [Command] = {
    @Sendable func repo(_ s: WorkbenchState) throws(CommandError) -> String {
      guard s.isRepo else { throw CommandError(.preconditionFailed, "not a Git project") }
      return s.current!.path
    }
    @Sendable func inFiles(_ s: WorkbenchState, _ i: CommandInput) throws(CommandError) -> String {
      let root = try repo(s)
      guard let p = i["path"]?.string,
        (try? ClairWorkspacePath(p)) != nil,
        s.files.contains(where: { $0.path == p }) || WorkbenchGit.changes(root).contains(where: { $0.path == p })
      else {
        throw CommandError(.preconditionFailed, "no file \(i["path"]?.string ?? "")")
      }
      return p
    }
    @Sendable func branch(_ i: CommandInput) throws(CommandError) -> String {
      guard let b = i["name"]?.string, WorkbenchGit.validBranch(b) else { throw CommandError(.invalidInput, "invalid branch name") }
      return b
    }
    func stage(_ id: String, _ title: String, _ verb: [String]) -> Command {
      cmd(id, title, .write, params: [CommandParam("path", .string)], palette: false,
          preflight: { s, i throws(CommandError) in _ = try inFiles(s, i); return .write }) { s, i in
        let r = WorkbenchGit.run(s.current!.path, verb + ["--", i["path"]!.string!], merge: true)
        s.refreshStatus(); return r.ok ? .ok : .text(r.out)
      }
    }
    return [
      stage("git.stage", "変更をステージ", ["add"]),
      stage("git.unstage", "ステージを解除", ["restore", "--staged"]),
      cmd("git.commit", "コミット", .write, params: [CommandParam("message", .string)], palette: false,
          preflight: { s, i throws(CommandError) in
            let root = try repo(s)
            guard !(i["message"]!.string!.trimmingCharacters(in: .whitespaces).isEmpty) else { throw CommandError(.invalidInput, "empty message") }
            guard !WorkbenchGit.run(root, ["diff", "--cached", "--quiet"]).ok else { throw CommandError(.preconditionFailed, "nothing staged") }
            return .write
          }) { s, i in
        let r = WorkbenchGit.run(s.current!.path, ["commit", "-m", i["message"]!.string!], merge: true)
        s.refreshStatus(); return r.ok ? .ok : .text(r.out)
      },
      cmd("git.switch", "ブランチを切り替え", .write, params: [CommandParam("name", .string)], palette: false,
          preflight: { s, i throws(CommandError) in
            let root = try repo(s), b = try branch(i)
            guard WorkbenchGit.branchExists(root, b) else { throw CommandError(.preconditionFailed, "no branch \(b)") }
            guard s.dirty.isEmpty else { throw CommandError(.preconditionFailed, "未保存のファイルを保存してから切り替えてください") }
            return .write
          }) { s, i in
        let root = s.current!.path
        let switched = i["name"]!.string!
        let r = WorkbenchGit.run(root, ["switch", switched], merge: true)
        if r.ok {
          if let index = s.projects.firstIndex(where: { $0.name == s.project }), s.projects[index].origin != nil {
            s.projects[index].branch = switched
          }
          s.refreshStatus(reconcileOpenFiles: true)
        }
        return r.ok ? .ok : .text(r.out)
      },
      cmd("git.pull", "Pull", .external, ai: false, palette: false,
          preflight: { s, _ throws(CommandError) in
            let root = try repo(s)
            guard WorkbenchGit.currentBranch(root) != nil else { throw CommandError(.preconditionFailed, "detached HEAD では pull できません") }
            guard WorkbenchGit.run(root, ["rev-parse", "--verify", "@{u}"]).ok else {
              throw CommandError(.preconditionFailed, "upstream が設定されていません")
            }
            guard s.dirty.isEmpty else { throw CommandError(.preconditionFailed, "未保存のファイルを保存してから pull してください") }
            return .external
          }) { s, _ in
        let r = WorkbenchGit.run(s.current!.path, ["pull", "--ff-only"], merge: true)
        if r.ok { s.refreshStatus(reconcileOpenFiles: true) }
        return r.ok ? .ok : .text(WorkbenchGit.remoteFailure("Pull", output: r.out))
      },
      cmd("git.push", "Push", .external, ai: false, palette: false,
          preflight: { s, _ throws(CommandError) in
            let root = try repo(s)
            guard WorkbenchGit.currentBranch(root) != nil else { throw CommandError(.preconditionFailed, "detached HEAD では push できません") }
            guard WorkbenchGit.run(root, ["rev-parse", "--verify", "@{u}"]).ok else {
              throw CommandError(.preconditionFailed, "upstream が設定されていません")
            }
            return .external
          }) { s, _ in
        let r = WorkbenchGit.run(s.current!.path, ["push"], merge: true)
        return r.ok ? .ok : .text(WorkbenchGit.remoteFailure("Push", output: r.out))
      },
      // ai: false — deleting a branch is never an agent's call; individual confirmation for each.
      cmd("git.branchDelete", "ブランチを削除", .destructive, ai: false, params: [CommandParam("name", .string)], palette: false,
          preflight: { s, i throws(CommandError) in
            let root = try repo(s), b = try branch(i)
            guard WorkbenchGit.branchExists(root, b) else { throw CommandError(.preconditionFailed, "no branch \(b)") }
            guard WorkbenchGit.currentBranch(root) != b else { throw CommandError(.preconditionFailed, "cannot delete the checked-out branch") }
            return .destructive
          }) { s, i in
        let r = WorkbenchGit.run(s.current!.path, ["branch", "-d", i["name"]!.string!], merge: true)  // -d: refuses unmerged
        return r.ok ? .ok : .text(r.out)
      },
      cmd("git.review", "ブランチ全体をレビュー", .read, params: [CommandParam("base", .string, required: false)],
          preflight: { s, _ throws(CommandError) in _ = try repo(s); return .read }) { s, i in .review(s.review(base: i["base"]?.string)) },
      // Creates <worktreeBase>/<project>/<branch> on a new branch and opens it as a Project.
      cmd("worktree.create", "worktree を作成", .write, ai: false, params: [CommandParam("branch", .string)], palette: false,
          preflight: { s, i throws(CommandError) in
            let root = try repo(s)
            guard s.current!.origin == nil else { throw CommandError(.preconditionFailed, "already inside a managed worktree") }
            guard let b = i["branch"]?.string, WorkbenchGit.validBranch(b) else { throw CommandError(.invalidInput, "invalid branch name") }
            guard !WorkbenchGit.branchExists(root, b) else { throw CommandError(.preconditionFailed, "branch \(b) exists") }
            return .write
          }) { s, i in
        let b = i["branch"]!.string!, origin = s.current!
        let dir = WorkbenchGit.worktreeBase.appending(path: origin.name).appending(path: b.replacingOccurrences(of: "/", with: "-"))
        try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = WorkbenchGit.run(origin.path, ["worktree", "add", "-b", b, dir.path], merge: true)
        guard r.ok, let path = WorkbenchProject.normalized(dir.path) else { return .text(r.out) }
        let p = WorkbenchProject(name: "\(origin.name) · \(b)", path: path, origin: origin.path, branch: b)
        s.projects.append(p); s.switchProject(to: p)
        return .ok
      },
      // Adoption: the worktree must be clean (everything committed); merge commit into origin's checked-out branch.
      cmd("worktree.adopt", "worktree をマージ", .write, ai: false,
          preflight: { s, _ throws(CommandError) in
            let root = try repo(s)
            guard s.current!.origin != nil else { throw CommandError(.preconditionFailed, "not a managed worktree") }
            guard WorkbenchGit.currentBranch(root) != nil else { throw CommandError(.preconditionFailed, "managed worktree has detached HEAD") }
            guard WorkbenchGit.isClean(root) else { throw CommandError(.preconditionFailed, "commit or discard changes before adopting") }
            return .write
          }) { s, _ in
        let p = s.current!, base = p.origin!
        guard let branch = WorkbenchGit.currentBranch(p.path) else { return .text("managed worktree has detached HEAD") }
        let r = WorkbenchGit.run(base, ["merge", "--no-ff", "-m", "Merge \(branch)", branch], merge: true)
        if r.ok { return .ok }
        WorkbenchGit.run(base, ["merge", "--abort"])
        return .text("merge failed and was aborted; ask the agent to resolve conflicts on \(branch):\n\(r.out)")
      },
      // Refuses a dirty worktree (no --force); the branch is kept and deleted separately via git.branchDelete.
      cmd("worktree.remove", "worktree を削除", .destructive, ai: false,
          preflight: { s, _ throws(CommandError) in
            _ = try repo(s)
            guard s.current!.origin != nil else { throw CommandError(.preconditionFailed, "not a managed worktree") }
            return .destructive
          }) { s, _ in
        let p = s.current!
        let r = WorkbenchGit.run(p.origin!, ["worktree", "remove", p.path], merge: true)
        guard r.ok else { return .text(r.out) }
        s.layouts[p.name] = nil
        s.projects.removeAll { $0.name == p.name }
        if let o = s.projects.first(where: { $0.path == p.origin }) { s.project = ""; s.switchProject(to: o) }
        return .ok
      },
    ]
  }()
}

// U05: read side of the source-control view.
public struct GitChange: Sendable, Equatable {
  public let path: String
  /// Porcelain X (index) and Y (worktree) columns; `?` on both for untracked.
  public let index: Character, worktree: Character
  public var untracked: Bool { index == "?" }
  public var staged: Bool { index != " " && index != "?" }
  public var unstaged: Bool { worktree != " " }
}

extension WorkbenchGit {
  /// `git status` as staged/unstaged/untracked entries. Empty for a non-repo.
  public static func changes(_ root: String) -> [GitChange] {
    let r = run(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
    guard r.ok else { return [] }
    var out: [GitChange] = []
    var parts = r.out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init).makeIterator()
    while let e = parts.next(), e.count > 3 {
      let x = e[e.startIndex], y = e[e.index(after: e.startIndex)]
      out.append(GitChange(path: String(e.dropFirst(3)), index: x, worktree: y))
      if x == "R" || x == "C" { _ = parts.next() }  // -z rename: the old path follows
    }
    return out
  }

  /// Unified diff of one file: staged (index vs HEAD) or worktree (vs index). Untracked files diff against /dev/null.
  public static func diff(_ root: String, _ path: String, staged: Bool, untracked: Bool = false) -> String {
    let args = untracked ? ["diff", "--no-index", "--", "/dev/null", path] : ["diff"] + (staged ? ["--cached"] : []) + ["--", path]
    // `--no-index` exits 1 when files differ, so read the output whatever the status.
    return run(root, args, merge: false).out
  }
}

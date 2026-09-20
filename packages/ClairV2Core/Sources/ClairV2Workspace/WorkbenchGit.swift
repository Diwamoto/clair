import Foundation

// V06: Git/worktree workflow on top of the command registry. Shells out to /usr/bin/git with an
// argv array (never a shell), so branch/path/message text cannot inject anything. Only Projects
// that are Git repositories get these commands (`WorkbenchState.isRepo`).
// Managed worktrees live outside the repository and are opened as their own Project.
// ponytail: synchronous git on the GUI thread, no timeout; move off-thread if a huge repo stalls it.
// ponytail: conflicts are aborted and reported (re-ask the agent); a native merge editor is not built.

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

  @discardableResult
  static func run(_ root: String, _ args: [String], merge: Bool = false) -> (ok: Bool, out: String) {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", root] + args
    p.standardOutput = out; p.standardError = merge ? out : FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (false, "git not runnable") }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func lines(_ root: String, _ args: [String]) -> [String] {
    let r = run(root, args)
    return r.ok ? r.out.split(separator: "\n").map(String.init) : []
  }

  static func validBranch(_ name: String) -> Bool { run(".", ["check-ref-format", "--branch", name]).ok }
  static func branchExists(_ root: String, _ name: String) -> Bool { run(root, ["rev-parse", "--verify", "-q", "refs/heads/\(name)"]).ok }
  static func currentBranch(_ root: String) -> String? {
    let r = run(root, ["rev-parse", "--abbrev-ref", "HEAD"]); return r.ok && r.out != "HEAD" ? r.out : nil
  }
  static func isClean(_ root: String) -> Bool { run(root, ["status", "--porcelain"]).out.isEmpty }
}

extension WorkbenchState {
  var current: WorkbenchProject? { projects.first { $0.name == project } }
  /// False for a plain folder: Git commands are neither listed nor runnable.
  public var isRepo: Bool { current.map { FileManager.default.fileExists(atPath: $0.path + "/.git") } ?? false }

  mutating func refreshStatus() {
    guard let p = current else { return }
    files = WorkbenchFiles.scan(p.path)  // rescan: new/removed files must become stageable
  }

  func review(base: String?) -> GitReview {
    let root = current!.path
    let base = base ?? current?.origin.flatMap(WorkbenchGit.currentBranch)
      ?? ["main", "master"].first { WorkbenchGit.branchExists(root, $0) }
    let committed = base.map { WorkbenchGit.lines(root, ["diff", "--name-status", "\($0)...HEAD"]) } ?? []
    return GitReview(
      base: base, committed: committed,
      uncommitted: WorkbenchGit.lines(root, ["diff", "--name-status", "HEAD"]),
      untracked: WorkbenchGit.lines(root, ["ls-files", "--others", "--exclude-standard"]))
  }
}

extension CommandRegistry {
  static let gitCommands: [Command] = {
    @Sendable func repo(_ s: WorkbenchState) throws(CommandError) -> String {
      guard s.isRepo else { throw CommandError(.preconditionFailed, "not a Git project") }
      return s.current!.path
    }
    @Sendable func inFiles(_ s: WorkbenchState, _ i: CommandInput) throws(CommandError) -> String {
      _ = try repo(s)
      guard let p = i["path"]?.string, s.files.contains(where: { $0.path == p }) else {
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
            return .write
          }) { s, i in
        let r = WorkbenchGit.run(s.current!.path, ["switch", i["name"]!.string!], merge: true)
        s.refreshStatus(); return r.ok ? .ok : .text(r.out)
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
            guard WorkbenchGit.isClean(root) else { throw CommandError(.preconditionFailed, "commit or discard changes before adopting") }
            return .write
          }) { s, _ in
        let p = s.current!, base = p.origin!
        let r = WorkbenchGit.run(base, ["merge", "--no-ff", "-m", "Merge \(p.branch!)", p.branch!], merge: true)
        if r.ok { return .ok }
        WorkbenchGit.run(base, ["merge", "--abort"])
        return .text("merge failed and was aborted; ask the agent to resolve conflicts on \(p.branch!):\n\(r.out)")
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

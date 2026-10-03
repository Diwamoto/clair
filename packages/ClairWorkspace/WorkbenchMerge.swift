import ClairShared
import Foundation

// Merge conflicts and partial staging (owner request 2026-10-03: "merge editor 欲しい、stage とかもやりたい").
// Conflicts are resolved in the file's own editor, one block at a time (ours / theirs / both), so every choice is an
// ordinary undoable edit; a resolved file is marked with `git.stage`. A change block of a diff can be staged or
// unstaged on its own through `git.stagePatch`.

/// One `<<<<<<<` … `>>>>>>>` block of a file with merge conflicts. Lines are 0-based.
public struct MergeConflict: Sendable, Equatable {
  public let startLine: Int
  public let endLine: Int
  public let ours: [String]
  /// The common ancestor (`|||||||`, diff3 style), when the file carries it.
  public let base: [String]?
  public let theirs: [String]
  public let oursLabel: String
  public let theirsLabel: String

  public enum Choice: Sendable { case ours, theirs, both }

  /// The lines that replace `startLine...endLine` for `choice`.
  public func resolution(_ choice: Choice) -> [String] {
    switch choice {
    case .ours: ours
    case .theirs: theirs
    case .both: ours + theirs
    }
  }

  /// Every complete conflict block of `text`, in order. A block missing its `=======` or `>>>>>>>` is not reported.
  public static func parse(_ text: String) -> [MergeConflict] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
    var out: [MergeConflict] = []
    var i = 0
    func label(_ line: String) -> String { String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
    while i < lines.count {
      guard lines[i].hasPrefix("<<<<<<<") else { i += 1; continue }
      let start = i
      var ours: [String] = [], base: [String]?, theirs: [String] = []
      var part = 0  // 0 ours, 1 base, 2 theirs
      var j = i + 1
      var closed = false
      while j < lines.count {
        let l = lines[j]
        if l.hasPrefix("<<<<<<<") { break }  // a new block before this one closed: drop this one
        if part == 0, l.hasPrefix("|||||||") { part = 1; base = [] }
        else if part < 2, l.hasPrefix("=======") { part = 2 }
        else if part == 2, l.hasPrefix(">>>>>>>") {
          out.append(MergeConflict(
            startLine: start, endLine: j, ours: ours, base: base, theirs: theirs, oursLabel: label(lines[start]), theirsLabel: label(l)))
          closed = true
          break
        } else if part == 0 { ours.append(l) } else if part == 1 { base?.append(l) } else { theirs.append(l) }
        j += 1
      }
      i = closed ? j + 1 : max(j, i + 1)
    }
    return out
  }
}

extension GitChange {
  /// Porcelain's unmerged states (DD, AU, UD, UA, DU, AA, UU).
  public var conflicted: Bool {
    index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D")
  }
}

/// One line of a parsed diff, as the diff view numbers it.
public struct DiffLine: Sendable, Equatable {
  public let text: String
  public let oldLine: Int?
  public let newLine: Int?
  public init(text: String, oldLine: Int?, newLine: Int?) { self.text = text; self.oldLine = oldLine; self.newLine = newLine }
  var isChange: Bool { text.hasPrefix("+") || text.hasPrefix("-") }
  var isContext: Bool { text.hasPrefix(" ") || (text.isEmpty && oldLine != nil) }
}

public enum GitPatch {
  /// Runs of added/removed lines (with a trailing `\ No newline` marker), as row ranges: what can be staged on its own.
  public static func blocks(_ rows: [DiffLine]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var i = 0
    while i < rows.count {
      guard rows[i].isChange else { i += 1; continue }
      var j = i
      while j < rows.count, rows[j].isChange || rows[j].text.hasPrefix("\\") { j += 1 }
      out.append(i..<j)
      i = j
    }
    return out
  }

  /// A one-hunk patch of `block` with up to `context` unchanged lines around it, for `git apply --cached --recount`.
  /// The rows are a full-context diff of `path` (index → worktree to stage, HEAD → index to unstage with `--reverse`).
  public static func patch(path: String, rows: [DiffLine], block: Range<Int>, context: Int = 3) -> String {
    var before: [DiffLine] = []
    var k = block.lowerBound - 1
    while k >= 0, before.count < context, rows[k].isContext { before.insert(rows[k], at: 0); k -= 1 }
    var after: [DiffLine] = []
    k = block.upperBound
    while k < rows.count, after.count < context, rows[k].isContext { after.append(rows[k]); k += 1 }
    let body = before + Array(rows[block]) + after
    let oldCount = body.filter { !$0.text.hasPrefix("+") && !$0.text.hasPrefix("\\") }.count
    let newCount = body.filter { !$0.text.hasPrefix("-") && !$0.text.hasPrefix("\\") }.count
    let firstOld = body.compactMap(\.oldLine).first
    let previousOld = rows[..<block.lowerBound].compactMap(\.oldLine).last ?? 0
    let oldStart = oldCount == 0 ? previousOld : (firstOld ?? previousOld)
    let newStart = newCount == 0 ? max(oldStart - 1, 0) : (oldCount == 0 ? oldStart + 1 : oldStart)
    let lines = body.map { $0.text.isEmpty ? " " : $0.text }
    return (["diff --git a/\(path) b/\(path)", "--- a/\(path)", "+++ b/\(path)", "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"] + lines)
      .joined(separator: "\n") + "\n"
  }
}

extension CommandRegistry {
  /// The instruction files agents read: `AGENTS.md` (Codex, OpenCode, …) and `CLAUDE.md` (Claude Code) at the Project
  /// root, and the user's own `~/.claude/CLAUDE.md`. Opening one that does not exist creates it from a short template.
  static func instructions(_ id: String, _ title: String, _ path: @escaping @Sendable (WorkbenchState) -> String?) -> Command {
    cmd(id, title, .additive, ai: false,
        preflight: { s, _ throws(CommandError) in
          guard path(s) != nil else { throw CommandError(.preconditionFailed, "no active Project") }
          return .additive
        }) { s, _ in
      let file = path(s)!
      if !FileManager.default.fileExists(atPath: file) {
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: file).deletingLastPathComponent(), withIntermediateDirectories: true)
        let name = (file as NSString).lastPathComponent
        let template = tr("# %@\n\nこの Project で agent に守ってほしいこと(ビルド・テストの方法、規約、触ってはいけない場所)を書きます。\n", name)
        guard FileManager.default.createFile(atPath: file, contents: Data(template.utf8)) else { return .text("cannot create \(file)") }
      }
      s.openFile(file)
      return .ok
    }
  }

  static let mergeCommands: [Command] = [
    instructions("agent.editAgentsMd", tr("AGENTS.md を編集"), { s in s.current.map { $0.path + "/AGENTS.md" } }),
    instructions("agent.editClaudeMd", tr("CLAUDE.md を編集"), { s in s.current.map { $0.path + "/CLAUDE.md" } }),
    instructions("agent.editUserClaudeMd", tr("ユーザーの CLAUDE.md を編集"), { s in
      s.current == nil ? nil : NSHomeDirectory() + "/.claude/CLAUDE.md"
    }),
    // Brings the base branch into a managed worktree whose adoption conflicted, so the conflicts are resolved there
    // (in the editor's conflict bar or by the worktree's agent) before adopting again. Spec §8.
    cmd("worktree.mergeBase", tr("base ブランチを取り込む"), .write, ai: false,
        preflight: { s, _ throws(CommandError) in
          guard s.isRepo, let p = s.current, let origin = p.origin else { throw CommandError(.preconditionFailed, "not a managed worktree") }
          guard WorkbenchGit.isClean(p.path) else { throw CommandError(.preconditionFailed, "commit or discard changes before merging") }
          guard WorkbenchGit.currentBranch(origin) != nil else { throw CommandError(.preconditionFailed, "the base checkout has detached HEAD") }
          return .write
        }) { s, _ in
      let p = s.current!, base = WorkbenchGit.currentBranch(p.origin!)!
      let r = WorkbenchGit.run(p.path, ["merge", "--no-edit", base], merge: true)
      s.refreshStatus(reconcileOpenFiles: true)
      if r.ok { return .ok }
      let conflicted = WorkbenchGit.changes(p.path).filter(\.conflicted).map(\.path)
      return .text(conflicted.isEmpty ? r.out : tr("%@ の取り込みで競合しました: %@。エディタの競合バーか agent で解決して commit してください。", base, conflicted.joined(separator: ", ")))
    },
    // Applies a patch from `GitPatch.patch` to the index: stages (or, with `reverse`, unstages) one change block.
    cmd("git.stagePatch", tr("変更ブロックをステージ"), .write, ai: false,
        params: [CommandParam("patch", .string), CommandParam("reverse", .bool, required: false)], palette: false,
        preflight: { s, i throws(CommandError) in
          guard s.isRepo else { throw CommandError(.preconditionFailed, "not a Git project") }
          let patch = i["patch"]!.string!
          // Exactly one file, inside the Project: no `..`, no absolute path, no second `diff --git`.
          let headers = patch.split(separator: "\n").filter { $0.hasPrefix("diff --git ") }
          guard headers.count == 1, !patch.contains("/../"), !patch.contains(" a//"), !patch.contains(" b//") else {
            throw CommandError(.invalidInput, "a patch must touch exactly one file in the Project")
          }
          return .write
        }) { s, i in
      let args = ["apply", "--cached", "--recount"] + (i["reverse"]?.bool == true ? ["--reverse"] : []) + ["-"]
      let r = WorkbenchGit.run(s.current!.path, args, merge: true, input: i["patch"]!.string!)
      s.refreshStatus()
      return r.ok ? .ok : .text(r.out)
    },
  ]
}

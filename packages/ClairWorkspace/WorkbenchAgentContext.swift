import ClairShared
import Foundation

// IDE context for agents (MCP / `clair`): what the editor knows that an agent in a terminal cannot see
// (language-server diagnostics, review threads), and the way back in (an agent's review findings become
// review threads and suggestions instead of terminal text, spec §6). The registry validates the call and
// the target file; the GUI store answers from its live language servers and review store (`answer`), the
// same split as `editor.definition`, whose effect the GUI applies after the registry accepted it.

/// One language-server diagnostic of an open document. Lines are 1-based, columns 0-based UTF-16 (as `editor.context`).
public struct WorkbenchDiagnostic: Sendable, Codable, Equatable {
  public let path: String
  public let line: Int
  public let column: Int
  public let endLine: Int
  public let endColumn: Int
  /// `error` / `warning` / `information` / `hint`
  public let severity: String
  public let message: String

  public init(path: String, line: Int, column: Int, endLine: Int, endColumn: Int, severity: String, message: String) {
    self.path = path; self.line = line; self.column = column; self.endLine = endLine; self.endColumn = endColumn
    self.severity = severity; self.message = message
  }
}

/// A review thread as an agent reads it. `line` is where the thread sits in the current file; `stale` means the
/// commented line's text is gone, so `line` is where it was made.
public struct WorkbenchReviewThread: Sendable, Codable, Equatable {
  public struct Comment: Sendable, Codable, Equatable {
    public let author: String
    public let body: String
    public init(author: String, body: String) { self.author = author; self.body = body }
  }
  public let id: String
  public let path: String
  public let line: Int
  public let stale: Bool
  /// `open` / `resolved`
  public let state: String
  public let comments: [Comment]

  public init(id: String, path: String, line: Int, stale: Bool, state: String, comments: [Comment]) {
    self.id = id; self.path = path; self.line = line; self.stale = stale; self.state = state; self.comments = comments
  }
}

/// A file an agent names: inside an open Project, as that Project's root and the path relative to it.
public struct AgentFileTarget: Sendable, Equatable {
  public let root: String
  public let path: String
}

extension WorkbenchState {
  /// Resolves `raw` (absolute, or relative to the active Project) to an existing file in an open Project.
  /// Refuses anything else, so an agent cannot annotate or read state about files outside the workspace.
  public func agentFile(_ raw: String) throws(CommandError) -> AgentFileTarget {
    let absolute: String
    if raw.hasPrefix("/") {
      absolute = raw
    } else {
      guard let root = current?.path else { throw CommandError(.preconditionFailed, "no active Project") }
      guard !raw.isEmpty, !raw.split(separator: "/").contains("..") else { throw CommandError(.invalidInput, "invalid path \(raw)") }
      absolute = root + "/" + raw
    }
    guard let file = WorkbenchProject.normalizedFile(absolute), let owner = owner(of: file) else {
      throw CommandError(.preconditionFailed, "\(raw) is not a file in an open Project")
    }
    return AgentFileTarget(root: owner.path, path: String(file.dropFirst(owner.path.count + 1)))
  }

  /// The Project an optional `path` argument scopes a listing to: that file's Project, else the active one.
  func agentScope(_ input: CommandInput) throws(CommandError) -> AgentFileTarget? {
    if let raw = input["path"]?.string { return try agentFile(raw) }
    guard current != nil else { throw CommandError(.preconditionFailed, "no active Project") }
    return nil
  }
}

extension CommandRegistry {
  private static func lines(_ i: CommandInput) throws(CommandError) {
    let line = i["line"]?.int ?? 0, end = i["endLine"]?.int ?? line
    guard line >= 1, end >= line else { throw CommandError(.invalidInput, "line must be ≥ 1 and endLine ≥ line") }
  }

  private static func text(_ i: CommandInput, _ key: String) throws(CommandError) {
    guard let s = i[key]?.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CommandError(.invalidInput, "\(key) must not be empty")
    }
    guard s.utf8.count <= 16_384 else { throw CommandError(.invalidInput, "\(key) is longer than 16 KiB") }
  }

  static let agentContextCommands: [Command] = [
    // Diagnostics exist only for documents a language server has open (files open in a Clair editor).
    // ponytail: open documents only; workspace-wide diagnostics need the server to open unopened files (pull diagnostics).
    cmd("editor.diagnostics", "診断（エラー・警告）を取得", .read,
        params: [CommandParam("path", .string, required: false)], palette: false,
        preflight: { s, i throws(CommandError) in _ = try s.agentScope(i); return .read }) { _, _ in .diagnostics([]) },
    cmd("review.threads", "レビューコメントを取得", .read,
        params: [CommandParam("path", .string, required: false)], palette: false,
        preflight: { s, i throws(CommandError) in _ = try s.agentScope(i); return .read }) { _, _ in .reviewThreads([]) },
    // Additive: a thread is an annotation the user resolves; it never changes a file.
    cmd("review.comment", "レビューコメントを追加", .additive,
        params: [CommandParam("path", .string), CommandParam("line", .int), CommandParam("endLine", .int, required: false),
                 CommandParam("body", .string)], palette: false,
        preflight: { s, i throws(CommandError) in
          _ = try s.agentFile(i["path"]!.string!); try lines(i); try text(i, "body")
          return .additive
        }) { _, _ in .ok },
    // A proposal only: the text changes when the user presses 適用 in the diff (one undo unit, unsaved).
    // The file must be in the active Project, whose open buffers the suggestion binds to (spec §6).
    cmd("review.suggest", "変更を提案", .additive,
        params: [CommandParam("path", .string), CommandParam("line", .int), CommandParam("endLine", .int, required: false),
                 CommandParam("replacement", .string), CommandParam("body", .string, required: false)], palette: false,
        preflight: { s, i throws(CommandError) in
          let target = try s.agentFile(i["path"]!.string!)
          guard target.root == s.current?.path else {
            throw CommandError(.preconditionFailed, "review.suggest needs a file in the active Project (\(s.project))")
          }
          try lines(i)
          guard i["replacement"]!.string!.utf8.count <= 16_384 else { throw CommandError(.invalidInput, "replacement is longer than 16 KiB") }
          if i["body"] != nil { try text(i, "body") }
          return .additive
        }) { _, _ in .ok },
  ]
}

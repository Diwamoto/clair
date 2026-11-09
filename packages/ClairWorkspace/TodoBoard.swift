import Foundation

/// #78: one card of the all-Project board, derived from a TODO's workflow keys and the live agent panes.
public struct TodoBoardCard: Equatable, Sendable {
  public enum State: String, Sendable { case running, waiting, overLimit, done }
  public let todo: ClairTodo
  /// The Project the card belongs to: the agent pane's, else the `project:` key (name or path).
  public let project: String?
  /// The agent pane, when it is still open.
  public let pane: Int?
  public let state: State
  /// `- <stage> …` lines of the TODO body, oldest first: who did each stage.
  public var history: [String] = []
  /// Existing `~/.clair/todo/<name>/{plan,review}.md`, next to the TODO file.
  public var artifacts: [String] = []

  static func history(_ text: String) -> [String] {
    ClairTodo.split(text).body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { line in ClairTodo.stages.contains { line.hasPrefix("- \($0) ") || line == "- \($0)" } }
      .map { String($0.dropFirst(2)) }
  }
}

extension WorkbenchState {
  /// ponytail: fixed send-back limit; make it a setting when a workflow needs another N.
  public static let boardRetryLimit = 3

  /// TODOs with a `stage` only: the others stay sidebar-only (#78).
  public func board(_ todos: [ClairTodo]) -> [TodoBoardCard] {
    let sessions = agentSessions
    return todos.filter { $0.stage != nil }.map { t in
      let live = t.agent.flatMap(terminal)
      let session = live.flatMap { l in sessions.first { $0.project == l.project && $0.pane == l.pane } }
      let named = t.extra["project"].flatMap { p in projects.first { $0.name == p || $0.path == p }?.name }
      let state: TodoBoardCard.State =
        if t.done || t.stage == "done" { .done }
        else if (t.retry ?? 0) > Self.boardRetryLimit { .overLimit }
        else if let s = session?.status, s == .running { .running }
        else if session?.status == .blocked || session?.status == .attention || t.stage == "plan" || t.stage == "submit" { .waiting }
        else { .running }
      let project = live?.project ?? named
      let dir = (t.path as NSString).deletingPathExtension
      let artifacts = ["plan.md", "review.md"].map { "\(dir)/\($0)" }.filter { FileManager.default.fileExists(atPath: $0) }
      let text = (try? String(contentsOfFile: t.path, encoding: .utf8)) ?? ""
      return TodoBoardCard(todo: t, project: project, pane: live?.pane, state: state, history: TodoBoardCard.history(text), artifacts: artifacts)
    }
  }
}

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
      return TodoBoardCard(todo: t, project: live?.project ?? named, pane: live?.pane, state: state)
    }
  }
}

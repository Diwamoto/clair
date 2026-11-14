import Foundation

/// One card of the all-Project board, derived from a TODO's workflow keys and the live agent panes.
public struct TodoBoardCard: Equatable, Sendable {
  /// `idle`: Inbox, Done, or no agent yet. `blocked`: the agent waits for input. `done` / `failed`: the column's
  /// `result` (an abnormal exit is `failed`). `unreported`: the agent finished without reporting a result.
  public enum State: String, Sendable { case idle, running, blocked, done, failed, unreported }
  public let todo: ClairTodo
  public let column: String
  /// The Project the card belongs to: the agent pane's, else the `project:` key (name or path).
  public let project: String?
  /// The agent pane, when it is still open.
  public let pane: Int?
  public let state: State
  public var note: String? { todo.note }
  /// When a Done card was finished: its `doneAt`, else the file's mtime.
  public var doneAt: Date? = nil
  public var body = ""
  /// `- <stage> …` lines of the TODO body, oldest first: who did each stage.
  public var history: [String] = []
  /// Existing `~/.clair/todo/<name>/{plan,review}.md`, next to the TODO file.
  public var artifacts: [String] = []

  static func history(_ text: String) -> [String] {
    ClairTodo.split(text).body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { line in (ClairTodo.stages + ClairTodo.legacyStages).contains { line.hasPrefix("- \($0) ") || line == "- \($0)" } }
      .map { String($0.dropFirst(2)) }
  }

  /// Cards containing every word of `query` in the title, body, plan.md, review.md, note, branch or PR URL.
  // ponytail: reads the two artifacts on every call; index them if a board of hundreds feels slow.
  public static func search(_ cards: [TodoBoardCard], _ query: String) -> [TodoBoardCard] {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return cards }
    return cards.filter { c in
      let text = ([c.todo.title, c.body, c.todo.note ?? "", c.todo.branch ?? "", c.todo.pr ?? ""]
        + c.artifacts.map { (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "" }).joined(separator: "\n").lowercased()
      return words.allSatisfy { text.contains($0) }
    }
  }
}

extension WorkbenchState {
  /// Days a Done card stays in its column (`board.doneDays`).
  var doneDays: Int { Int(choices["board.doneDays"] ?? "") ?? 7 }

  /// Every TODO as a card. Done cards older than `board.doneDays` go to `archived`; Inbox is priority, then due.
  public func board(_ todos: [ClairTodo], now: Date = .now) -> (cards: [TodoBoardCard], archived: [TodoBoardCard]) {
    let sessions = agentSessions
    let all = todos.map { t -> TodoBoardCard in
      let live = t.agent.flatMap(terminal)
      let session = live.flatMap { l in sessions.first { $0.project == l.project && $0.pane == l.pane } }
      let named = t.project.flatMap { p in projects.first { $0.name == p || $0.path == p }?.name }
      let column = t.column
      let state: TodoBoardCard.State =
        if t.result == "failed" { .failed }
        else if t.result == "ok" { .done }
        else if column == "inbox" || column == "done" || t.agent == nil { .idle }
        else {
          switch session?.status {
          case .running?: .running
          case .blocked?, .attention?: .blocked
          case .exited(let code)?: (code ?? 0) == 0 ? .unreported : .failed
          case .done?, .idle?: .unreported
          case nil: .idle
          }
        }
      let dir = (t.path as NSString).deletingPathExtension
      let artifacts = ["plan.md", "review.md"].map { "\(dir)/\($0)" }.filter { FileManager.default.fileExists(atPath: $0) }
      let text = (try? String(contentsOfFile: t.path, encoding: .utf8)) ?? ""
      let doneAt = column == "done"
        ? t.doneAt.flatMap { ISO8601DateFormatter().date(from: $0) }
          ?? (try? FileManager.default.attributesOfItem(atPath: t.path)[.modificationDate]) as? Date
        : nil
      return TodoBoardCard(
        todo: t, column: column, project: live?.project ?? named ?? t.project, pane: live?.pane, state: state, doneAt: doneAt,
        body: ClairTodo.split(text).body.trimmingCharacters(in: .whitespacesAndNewlines),
        history: TodoBoardCard.history(text), artifacts: artifacts)
    }
    let cutoff = now.addingTimeInterval(-Double(doneDays) * 86400)
    func old(_ c: TodoBoardCard) -> Bool { c.column == "done" && (c.doneAt ?? .distantPast) < cutoff }
    let order = ClairTodo.columns
    let kept = all.filter { !old($0) }.enumerated().sorted { a, b in
      func key(_ c: TodoBoardCard, _ i: Int) -> [String] {
        [String(order.firstIndex(of: c.column) ?? 0), c.column == "inbox" ? String(c.todo.priority) : "",
         c.column == "inbox" ? c.todo.due ?? "~" : "", String(format: "%09d", i)]
      }
      return key(a.element, a.offset).lexicographicallyPrecedes(key(b.element, b.offset))
    }.map(\.element)
    return (kept, all.filter(old))
  }
}

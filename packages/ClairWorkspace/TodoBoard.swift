import Foundation

/// One card of the all-Project board, derived from a TODO and its agent's live pane (#82: one card, one agent).
public struct TodoBoardCard: Equatable, Sendable {
  /// `idle`: no agent yet (Inbox). `blocked`: the agent waits on the owner (a decision sheet or a prompt). `done` / `failed`:
  /// the agent's `result` (an abnormal exit is `failed`). `unreported`: the agent stopped, or its pane is gone, without a result.
  public enum State: String, Sendable { case idle, running, blocked, done, failed, unreported }
  /// The board's columns, in order: each is a state (failed and unreported share 未完了).
  public static let columns = ["inbox", "running", "blocked", "done", "failed"]
  public let todo: ClairTodo
  /// The Project the card belongs to: the agent pane's, else the `project:` key (name or path).
  public let project: String?
  /// The agent pane, when it is still open.
  public let pane: Int?
  public let state: State
  public var note: String? { todo.note }
  /// When a done card finished: its `doneAt`, else the file's mtime.
  public var doneAt: Date? = nil
  public var body = ""
  /// Existing files the card's agent left in `~/.clair/todo/<name>/` that search reads.
  public var artifacts: [String] = []
  /// Questions on the card's unanswered decision sheet (ADR-0030); the card waits on the owner while this is > 0.
  public var asking = 0

  public var column: String {
    switch state {
    case .idle: "inbox"
    case .running: "running"
    case .blocked: "blocked"
    case .done: "done"
    case .failed, .unreported: "failed"
    }
  }

  /// Cards containing every word of `query` in the title, body, the card folder's notes, note, branch or PR URL.
  // ponytail: reads the artifacts on every call; index them if a board of hundreds feels slow.
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
  /// Days a done card stays in its column (`board.doneDays`).
  var doneDays: Int { Int(choices["board.doneDays"] ?? "") ?? 7 }

  /// A card's state from its file and its agent's pane. A checked-off TODO or an `ok` is done; an open decision sheet
  /// waits on the owner whatever the pane does.
  func cardState(_ t: ClairTodo, session: AgentSession?, sheet: Bool) -> TodoBoardCard.State {
    if t.result == "ok" || t.done { return .done }
    if sheet { return .blocked }
    if t.result == "failed" { return .failed }
    guard t.agent != nil else { return .idle }
    switch session?.status {
    case .running?: return .running
    case .blocked?, .attention?: return .blocked
    case .exited(let code)?: return (code ?? 0) == 0 ? .unreported : .failed
    case .done?, .idle?, nil: return .unreported
    }
  }

  /// Every TODO as a card. Done cards older than `board.doneDays` go to `archived`; Inbox is priority, then due.
  public func board(_ todos: [ClairTodo], now: Date = .now) -> (cards: [TodoBoardCard], archived: [TodoBoardCard]) {
    let sessions = agentSessions
    let all = todos.map { t -> TodoBoardCard in
      let live = t.agent.flatMap { cardAgent($0, path: t.path) ? terminal($0) : nil }  // a forged agent= shows no pane
      let session = live.flatMap { l in sessions.first { $0.project == l.project && $0.pane == l.pane } }
      let named = t.project.flatMap { p in projects.first { $0.name == p || $0.path == p }?.name }
      let sheet = DecisionSheet.load(card: t.path).flatMap { $0.state == .pending ? $0 : nil }
      let state = cardState(t, session: session, sheet: sheet != nil)
      let dir = (t.path as NSString).deletingPathExtension
      let artifacts = ["research.md", "plan.md", "review.md", "decisions.md"].map { "\(dir)/\($0)" }.filter { FileManager.default.fileExists(atPath: $0) }
      let text = (try? String(contentsOfFile: t.path, encoding: .utf8)) ?? ""
      let doneAt = state == .done
        ? t.doneAt.flatMap { ISO8601DateFormatter().date(from: $0) }
          ?? (try? FileManager.default.attributesOfItem(atPath: t.path)[.modificationDate]) as? Date
        : nil
      return TodoBoardCard(
        todo: t, project: live?.project ?? named ?? t.project, pane: live?.pane, state: state, doneAt: doneAt,
        body: ClairTodo.split(text).body.trimmingCharacters(in: .whitespacesAndNewlines),
        artifacts: artifacts, asking: sheet?.questions.count ?? 0)
    }
    let cutoff = now.addingTimeInterval(-Double(doneDays) * 86400)
    func old(_ c: TodoBoardCard) -> Bool { c.state == .done && (c.doneAt ?? .distantPast) < cutoff }
    let order = TodoBoardCard.columns
    let kept = all.filter { !old($0) }.enumerated().sorted { a, b in
      func key(_ c: TodoBoardCard, _ i: Int) -> [String] {
        let inbox = c.column == "inbox"
        return [String(order.firstIndex(of: c.column) ?? 0), inbox ? String(c.todo.priority) : "", inbox ? c.todo.due ?? "~" : "", String(format: "%09d", i)]
      }
      return key(a.element, a.offset).lexicographicallyPrecedes(key(b.element, b.offset))
    }.map(\.element)
    return (kept, all.filter(old))
  }
}

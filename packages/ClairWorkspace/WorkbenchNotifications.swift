import ClairShared
import Foundation

// V08: Project badges, notification history and mute. OSC 9/777 notification
// title/body and the reply excerpt of an `agent.report state=done` are retained
// locally; both are terminal-supplied text.
// ponytail: history lives in memory only (cap 200), not workspace.json; persist if restore-after-quit matters.

public struct WorkbenchNotice: Sendable, Codable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Codable { case bell, exited, done }
  public let id: Int
  public let project: String
  public let pane: Int
  public let kind: Kind
  public let exitCode: Int?
  public let sourceTitle: String?
  public let sourceBody: String?
  public let sessionTitle: String?
  public let at: Date
  public var read: Bool

  /// Fixed wording from the fact alone.
  public var title: String {
    switch kind {
    case .bell: sourceTitle.flatMap { $0.isEmpty ? nil : $0 } ?? tr("通知")
    case .done: tr("完了")
    case .exited: exitCode == 0 ? tr("正常終了") : tr("異常終了 (exit %@)", exitCode ?? -1)
    }
  }
}

public struct NotificationLog: Sendable, Codable, Equatable {
  public static let cap = 200
  /// Longest kept body: the toast and list show a few lines of it.
  public static let bodyCap = 600
  public private(set) var items: [WorkbenchNotice] = []  // newest first
  public var mutedProjects: Set<String> = []
  public var mutedPanes: Set<String> = []  // "project#pane"
  private var nextID = 1

  public static func paneKey(_ project: String, _ pane: Int) -> String { "\(project)#\(pane)" }

  /// Records the fact. A muted source is kept in history (already read) but returns nil: no badge, no macOS alert.
  @discardableResult
  public mutating func record(project: String, pane: Int, kind: WorkbenchNotice.Kind, exitCode: Int? = nil, sourceTitle: String? = nil, sourceBody: String? = nil, sessionTitle: String? = nil, at: Date = Date()) -> WorkbenchNotice? {
    let muted = mutedProjects.contains(project) || mutedPanes.contains(Self.paneKey(project, pane))
    let n = WorkbenchNotice(id: nextID, project: project, pane: pane, kind: kind, exitCode: exitCode, sourceTitle: sourceTitle, sourceBody: sourceBody.map { String($0.prefix(Self.bodyCap)) }, sessionTitle: sessionTitle, at: at, read: muted)
    nextID += 1
    items.insert(n, at: 0)
    if items.count > Self.cap { items.removeLast(items.count - Self.cap) }
    return muted ? nil : n
  }

  public func unread(_ project: String? = nil) -> Int { items.filter { !$0.read && (project == nil || $0.project == project) }.count }

  public mutating func markRead(project: String?) {
    for i in items.indices where project == nil || items[i].project == project { items[i].read = true }
  }

  public mutating func markRead(project: String, pane: Int) {
    for i in items.indices where items[i].project == project && items[i].pane == pane { items[i].read = true }
  }

  /// The agent's turn ended and nobody has looked yet; its later "waiting for input" bell says nothing new.
  public func hasUnreadDone(project: String, pane: Int) -> Bool {
    items.contains { $0.kind == .done && !$0.read && $0.project == project && $0.pane == pane }
  }

  /// A pane working again makes its "done" stale.
  public mutating func markDoneRead(project: String, pane: Int) {
    for i in items.indices where items[i].kind == .done && items[i].project == project && items[i].pane == pane { items[i].read = true }
  }

  public mutating func clear() { items = [] }
}

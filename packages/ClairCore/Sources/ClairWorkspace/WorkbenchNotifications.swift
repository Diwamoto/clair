import Foundation

// V08: Project badges, notification history and mute. Only facts enter (bell / OSC 9·777 request, exit code);
// terminal bytes and secrets have no path into this model by construction (no text field).
// ponytail: history lives in memory only (cap 200), not workspace.json; persist if restore-after-quit matters.

public struct WorkbenchNotice: Sendable, Codable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Codable { case bell, exited }
  public let id: Int
  public let project: String
  public let pane: Int
  public let kind: Kind
  public let exitCode: Int?
  public let at: Date
  public var read: Bool

  /// Fixed wording from the fact alone.
  public var title: String { kind == .bell ? "通知" : exitCode == 0 ? "正常終了" : "異常終了 (exit \(exitCode ?? -1))" }
}

public struct NotificationLog: Sendable, Codable, Equatable {
  public static let cap = 200
  public private(set) var items: [WorkbenchNotice] = []  // newest first
  public var mutedProjects: Set<String> = []
  public var mutedPanes: Set<String> = []  // "project#pane"
  private var nextID = 1

  public static func paneKey(_ project: String, _ pane: Int) -> String { "\(project)#\(pane)" }

  /// Records the fact. A muted source is kept in history (already read) but returns nil: no badge, no macOS alert.
  @discardableResult
  public mutating func record(project: String, pane: Int, kind: WorkbenchNotice.Kind, exitCode: Int? = nil, at: Date = Date()) -> WorkbenchNotice? {
    let muted = mutedProjects.contains(project) || mutedPanes.contains(Self.paneKey(project, pane))
    let n = WorkbenchNotice(id: nextID, project: project, pane: pane, kind: kind, exitCode: exitCode, at: at, read: muted)
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

  public mutating func clear() { items = [] }
}

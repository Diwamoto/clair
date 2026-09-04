import Foundation
import SwiftUI

/// First-class workspace activities surfaced by the native shell.
///
/// The Interaction Lab contract keeps Files, Search, Git, Review, and
/// Notifications/History as the only always-present core navigation. Advanced
/// tools (Quick Open overlay, Command Window, Agent launcher, pane layout
/// actions) stay out of the default rail.
enum WorkspaceActivity: String, CaseIterable, Identifiable, Codable, Sendable {
  case files
  case search
  case git
  case review
  case activity

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .files:
      "エクスプローラー"
    case .search:
      "検索"
    case .git:
      "ソース管理"
    case .review:
      "変更を確認"
    case .activity:
      "アクティビティ"
    }
  }

  var accessibilityHint: String {
    switch self {
    case .files:
      "Projectエクスプローラーを表示"
    case .search:
      "Project全体を検索・置換"
    case .git:
      "ProjectのGitワークツリーを開く"
    case .review:
      "管理対象worktreeのブランチを確認"
    case .activity:
      "通知、Agentのアクティビティ、ファイル履歴を表示"
    }
  }

  var symbolName: String {
    switch self {
    case .files:
      "folder"
    case .search:
      "magnifyingglass"
    case .git:
      "arrow.triangle.branch"
    case .review:
      "checkmark.shield"
    case .activity:
      "bell"
    }
  }
}

extension ProjectSurfaceModel {
  /// Persisted workspace activity selection for this Project.
  var workspaceActivity: WorkspaceActivity {
    get {
      WorkspaceActivity(rawValue: workspaceActivityRawValue) ?? .files
    }
    set {
      guard workspaceActivityRawValue != newValue.rawValue else {
        return
      }
      workspaceActivityRawValue = newValue.rawValue
      notifyWorkspaceActivityChanged()
    }
  }
}

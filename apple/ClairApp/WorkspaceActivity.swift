import Foundation
import SwiftUI

/// The tools the sidebar strip can show.
///
/// The design canvas gives the strip four destinations — File Tree, Source
/// Control, Agents and Debug. The debug destination owns a Project-scoped
/// Go/Delve session. Two cases stay in the model without a strip entry of
/// their own:
///
/// - `search` moved to the titlebar's search field, so file and symbol search
///   has exactly one entry point.
/// - `review` became a *mode* of `git` rather than a separate destination, the
///   way a git GUI keeps history inside its one source-control tool instead of
///   giving it a top-level tab.
enum WorkspaceActivity: String, CaseIterable, Identifiable, Codable, Sendable {
  case files
  case search
  case git
  case review
  case debug
  case activity

  /// The entries the sidebar strip actually draws, in order.
  static let navigationCases: [WorkspaceActivity] = [.files, .git, .activity, .debug]

  var id: String {
    rawValue
  }

  /// The strip entry a given activity lights up. `search` and `review` have no
  /// entry of their own, so they light the tool they now live inside.
  var navigationEntry: WorkspaceActivity {
    switch self {
    case .search:
      .files
    case .review:
      .git
    default:
      self
    }
  }

  var title: String {
    switch self {
    case .files:
      "File Tree"
    case .search:
      "検索"
    case .git:
      "Source Control"
    case .review:
      "レビュー"
    case .debug:
      "Debug"
    case .activity:
      "Agents"
    }
  }

  var accessibilityHint: String {
    switch self {
    case .files:
      "File Tree"
    case .search:
      "Project全体を検索・置換"
    case .git:
      "Source Control"
    case .review:
      "管理対象worktreeのブランチを確認"
    case .debug:
      "Debug"
    case .activity:
      "Agents"
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
      "arrow.triangle.branch"
    case .debug:
      "ladybug"
    case .activity:
      "terminal"
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

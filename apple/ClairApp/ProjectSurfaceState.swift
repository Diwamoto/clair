import Foundation
import Observation

// Project surface state is split by domain so that a change in one domain does
// not invalidate views that only read another. Each domain is an independent
// `@Observable` object and `ProjectSurfaceModel` keeps the same read-only
// property names it always exposed, forwarding each one to its owning domain.
//
// The split matters for the text engine seams: a Git refresh no longer
// re-evaluates the file tree, and a pane or tab change no longer re-evaluates
// search results.

/// Editor caret and scroll position for one tab. It belongs to the persisted
/// workspace snapshot rather than to any view, so it is held outside the
/// observable tab store.
struct ProjectEditorViewportState: Equatable, Sendable {
  var selection: ProjectEditorUTF16Range?
  var scrollTop: Double?
}

/// File tree and tree selection state.
@MainActor
@Observable
final class ProjectFileTreeState {
  var fileTree: ProjectFileTreeSnapshot
  var selectedNodeID: String?
  /// Expanded directory IDs are rendered by the tree rows and persisted with
  /// the workspace snapshot, so collapsing a directory has to reach the tree
  /// view without republishing anything else.
  var expandedNodeIDs: Set<String>

  init(
    fileTree: ProjectFileTreeSnapshot,
    selectedNodeID: String?,
    expandedNodeIDs: Set<String>
  ) {
    self.fileTree = fileTree
    self.selectedNodeID = selectedNodeID
    self.expandedNodeIDs = expandedNodeIDs
  }
}

/// Pane, tab, focus, and activity state.
@MainActor
@Observable
final class ProjectLayoutState {
  var tabStore: [ProjectPaneTab]
  var layout: ProjectPaneNode
  var focusedPaneID: UUID
  var maximizedPaneID: UUID?
  var lastEditorErrorMessage: String?
  var workspaceActivityRawValue: String

  init(
    tabStore: [ProjectPaneTab],
    layout: ProjectPaneNode,
    focusedPaneID: UUID,
    maximizedPaneID: UUID?,
    lastEditorErrorMessage: String? = nil,
    workspaceActivityRawValue: String
  ) {
    self.tabStore = tabStore
    self.layout = layout
    self.focusedPaneID = focusedPaneID
    self.maximizedPaneID = maximizedPaneID
    self.lastEditorErrorMessage = lastEditorErrorMessage
    self.workspaceActivityRawValue = workspaceActivityRawValue
  }
}

/// Quick Open, search, and replacement state.
@MainActor
@Observable
final class ProjectSearchState {
  var searchResults: [ProjectSearchMatch] = []
  var quickOpenResults: [ProjectQuickOpenItem] = []
  var quickOpenIsLoading = false
  var searchIsLoading = false
  var replacementIsLoading = false
  var replacementPreview: ProjectSearchReplacementPreview?
  var lastNavigationErrorMessage: String?
  var lastNavigationStatusMessage: String?

  init() {}
}

/// Git status and diff state.
@MainActor
@Observable
final class ProjectGitState {
  var gitStatus: ProjectGitSnapshot?
  var selectedGitDiff: ProjectGitDiff?
  var lastGitErrorMessage: String?

  init() {}
}

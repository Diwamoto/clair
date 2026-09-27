import Foundation

/// `INV-RVW-006`: `.open` or `.resolved`. Resolving does not freeze the
/// thread's anchor (`INV-RVW-005`) — it keeps rebasing like an open thread.
public enum ReviewThreadState: Sendable, Equatable {
  case open
  case resolved
}

/// An ordered list of comments with a lifecycle state.
public struct ReviewThread: Sendable, Equatable, Identifiable {
  public let id: UUID
  public var comments: [ReviewComment]
  public var state: ReviewThreadState

  public init(
    id: UUID = UUID(),
    comments: [ReviewComment],
    state: ReviewThreadState = .open
  ) {
    self.id = id
    self.comments = comments
    self.state = state
  }

  /// `INV-RVW-007`: the anchor of the first visible (non-deleted) comment.
  public var anchor: ReviewAnchor? {
    comments.first(where: { $0.state == .visible })?.anchor
  }
}

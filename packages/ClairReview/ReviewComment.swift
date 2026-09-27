import Foundation

/// Soft-delete state for a comment. Deleting a comment does not delete the
/// thread or affect anchor rebasing (`INV-RVW-006`).
public enum ReviewCommentState: Sendable, Equatable {
  case visible
  case deleted
}

/// One comment in a review thread. Comments are immutable except for the
/// soft-delete flag; edit history is not tracked at this layer.
public struct ReviewComment: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let author: ReviewAuthor
  public let body: String
  public let createdAt: Date
  public var anchor: ReviewAnchor
  public var state: ReviewCommentState

  public init(
    id: UUID = UUID(),
    author: ReviewAuthor,
    body: String,
    createdAt: Date = Date(),
    anchor: ReviewAnchor,
    state: ReviewCommentState = .visible
  ) {
    self.id = id
    self.author = author
    self.body = body
    self.createdAt = createdAt
    self.anchor = anchor
    self.state = state
  }
}

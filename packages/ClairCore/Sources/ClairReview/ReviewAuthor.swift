/// Identifies who wrote a review comment. The kind is metadata only; it does
/// not grant different edit permissions at the model layer (`INV-RVW-008`).
public struct ReviewAuthor: Sendable, Equatable {
  public let displayName: String
  public let kind: ReviewAuthorKind

  public init(displayName: String, kind: ReviewAuthorKind) {
    self.displayName = displayName
    self.kind = kind
  }
}

public enum ReviewAuthorKind: Sendable, Equatable {
  case human
  case agent
}

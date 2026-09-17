import ClairV2EditorCore
import Foundation

/// One UTF-8 range + replacement within a suggestion. Reuses `ReviewAnchor`
/// so it rebases through the same mapping as thread anchors (`INV-RVW-010`).
public struct ReviewSuggestionHunk: Sendable, Equatable, Identifiable {
  public let id: UUID
  public var anchor: ReviewAnchor
  public let replacement: String

  public init(id: UUID = UUID(), anchor: ReviewAnchor, replacement: String) {
    self.id = id
    self.anchor = anchor
    self.replacement = replacement
  }

  func asTextEdit() -> TextEdit {
    TextEdit(range: anchor.range, replacement: replacement)
  }
}

/// `INV-RVW-011`, `INV-RVW-019`: only `.pending` may move to `.applied` or
/// `.partiallyApplied`; every other state is terminal for that suggestion.
public enum ReviewSuggestionState: Sendable, Equatable {
  case pending
  case applied
  case rejected
  case partiallyApplied
}

/// A set of hunks bound to a base revision (`INV-RVW-009`).
public struct ReviewSuggestion: Sendable, Equatable, Identifiable {
  public let id: UUID
  public var hunks: [ReviewSuggestionHunk]
  public let description: String?
  public var baseRevision: TextRevision
  public var state: ReviewSuggestionState

  public init(
    id: UUID = UUID(),
    hunks: [ReviewSuggestionHunk],
    description: String? = nil,
    baseRevision: TextRevision,
    state: ReviewSuggestionState = .pending
  ) {
    self.id = id
    self.hunks = hunks
    self.description = description
    self.baseRevision = baseRevision
    self.state = state
  }

  /// `INV-RVW-012`/test 10: apply is refused if any hunk anchor drifted stale
  /// or orphaned, even when the base revision still matches.
  var isAttached: Bool { hunks.allSatisfy(\.anchor.isAttached) }
}

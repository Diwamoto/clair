import ClairV2EditorCore
import Foundation

public enum ReviewThreadManagerError: Error, Sendable, Equatable {
  case unknownThread(UUID)
  case unknownSuggestion(UUID)
  case unknownComment(UUID)
  case suggestionNotPending
  case suggestionNotApplicable
  case suggestionRevisionMismatch
  case cannotUndoSuggestionNotOnTop
  case noApplicableHunks
}

/// Owns review threads and AI suggestions for one document and exposes the
/// single rebase entry point (`INV-RVW-020`).
///
/// The manager is not isolated to an actor: like `EditorTransactionManager`, it
/// must be used from the same serial context (usually `@MainActor`) that owns
/// the view and the transaction manager.
public final class ReviewThreadManager {
  public private(set) var threads: [ReviewThread]
  public private(set) var suggestions: [ReviewSuggestion]

  public init(threads: [ReviewThread] = [], suggestions: [ReviewSuggestion] = []) {
    self.threads = threads
    self.suggestions = suggestions
  }

  // MARK: - Threads

  @discardableResult
  public func addThread(
    author: ReviewAuthor,
    body: String,
    anchor: ReviewAnchor,
    state: ReviewThreadState = .open
  ) -> ReviewThread {
    let comment = ReviewComment(author: author, body: body, anchor: anchor)
    let thread = ReviewThread(comments: [comment], state: state)
    threads.append(thread)
    return thread
  }

  @discardableResult
  public func addComment(
    to threadID: UUID,
    author: ReviewAuthor,
    body: String,
    anchor: ReviewAnchor
  ) throws -> ReviewComment {
    guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
      throw ReviewThreadManagerError.unknownThread(threadID)
    }
    let comment = ReviewComment(author: author, body: body, anchor: anchor)
    threads[index].comments.append(comment)
    return comment
  }

  public func resolveThread(id: UUID) throws {
    guard let index = threads.firstIndex(where: { $0.id == id }) else {
      throw ReviewThreadManagerError.unknownThread(id)
    }
    threads[index].state = .resolved
  }

  public func deleteComment(threadID: UUID, commentID: UUID) throws {
    guard let tIndex = threads.firstIndex(where: { $0.id == threadID }) else {
      throw ReviewThreadManagerError.unknownThread(threadID)
    }
    guard let cIndex = threads[tIndex].comments.firstIndex(where: { $0.id == commentID }) else {
      throw ReviewThreadManagerError.unknownComment(commentID)
    }
    threads[tIndex].comments[cIndex].state = .deleted
  }

  // MARK: - Suggestions

  @discardableResult
  public func addSuggestion(
    hunks: [ReviewSuggestionHunk],
    description: String? = nil,
    baseRevision: TextRevision
  ) -> ReviewSuggestion {
    let suggestion = ReviewSuggestion(
      hunks: hunks, description: description, baseRevision: baseRevision)
    suggestions.append(suggestion)
    return suggestion
  }

  public func rejectSuggestion(id: UUID) throws {
    guard let index = suggestions.firstIndex(where: { $0.id == id }) else {
      throw ReviewThreadManagerError.unknownSuggestion(id)
    }
    guard suggestions[index].state == .pending else {
      throw ReviewThreadManagerError.suggestionNotPending
    }
    suggestions[index].state = .rejected
  }

  /// Applies every hunk of a pending suggestion as one undo unit. The hunk
  /// ranges must be non-overlapping and grapheme-aligned (`INV-RVW-013`).
  /// Every other thread and suggestion is rebased through the same edits
  /// (`INV-RVW-020`, `INV-RVW-021`) so nothing else drifts.
  @discardableResult
  public func applySuggestion(
    id: UUID,
    in transactionManager: EditorTransactionManager
  ) throws -> TextSnapshot {
    guard let index = suggestions.firstIndex(where: { $0.id == id }) else {
      throw ReviewThreadManagerError.unknownSuggestion(id)
    }
    let suggestion = suggestions[index]
    try validateSuggestionForApply(suggestion, against: transactionManager.buffer.snapshot.revision)

    let preApplyHunks = suggestion.hunks
    let edits = suggestion.hunks.map { $0.asTextEdit() }
    let snapshot = try transactionManager.apply(edits, label: suggestionApplyLabel(for: id))
    rebase(through: transactionManager.lastCommittedEdits)
    // The rebase above also touched this suggestion's own hunks (they now
    // point at the just-applied text); restore them so a later undo has the
    // exact pre-apply anchors to reattach (`INV-RVW-018`).
    suggestions[index].hunks = preApplyHunks
    suggestions[index].state = .applied
    return snapshot
  }

  /// Undoes a full suggestion apply, but only while that apply is still the
  /// newest edit in the transaction manager (`INV-RVW-017`).
  @discardableResult
  public func undoSuggestionApply(
    id: UUID,
    in transactionManager: EditorTransactionManager
  ) throws -> TextSnapshot? {
    guard transactionManager.lastUndoLabel == suggestionApplyLabel(for: id) else {
      throw ReviewThreadManagerError.cannotUndoSuggestionNotOnTop
    }
    guard let index = suggestions.firstIndex(where: { $0.id == id }) else {
      throw ReviewThreadManagerError.unknownSuggestion(id)
    }
    let preApplyHunks = suggestions[index].hunks
    guard suggestions[index].state == .applied else {
      throw ReviewThreadManagerError.suggestionNotApplicable
    }
    guard let snapshot = try transactionManager.undo() else {
      return nil
    }
    // Reverses the forward rebase `applySuggestion` did for every other
    // thread/suggestion, using undo's own (inverse) edits.
    rebase(through: transactionManager.lastCommittedEdits)
    // INV-RVW-018: undo restores the buffer to the pre-apply content, but the
    // revision keeps advancing (undo is itself a transaction), so re-attach
    // the suggestion's base revision and its exact pre-apply hunk anchors
    // here rather than leaving them stale or drifted by the rebase above.
    suggestions[index].hunks = preApplyHunks
    suggestions[index].baseRevision = snapshot.revision
    suggestions[index].state = .pending
    return snapshot
  }

  /// Applies a subset of hunks and leaves the rest as a new pending suggestion
  /// rebased to the post-apply revision (`INV-RVW-015`).
  ///
  /// Returns the snapshot after the apply and the new pending suggestion, or
  /// `nil` for the remaining suggestion if every hunk was accepted.
  @discardableResult
  public func partiallyApplySuggestion(
    id: UUID,
    acceptedHunkIDs: Set<UUID>,
    in transactionManager: EditorTransactionManager
  ) throws -> (appliedSnapshot: TextSnapshot, remainingSuggestion: ReviewSuggestion?) {
    guard let index = suggestions.firstIndex(where: { $0.id == id }) else {
      throw ReviewThreadManagerError.unknownSuggestion(id)
    }
    let preApplyHunks = suggestions[index].hunks
    try validateSuggestionForApply(
      suggestions[index], against: transactionManager.buffer.snapshot.revision)

    let accepted = preApplyHunks.filter { acceptedHunkIDs.contains($0.id) }
    let remainingIDs = Set(preApplyHunks.map(\.id)).subtracting(acceptedHunkIDs)
    guard !accepted.isEmpty else { throw ReviewThreadManagerError.noApplicableHunks }

    let edits = accepted.map { $0.asTextEdit() }
    let snapshot = try transactionManager.apply(edits, label: suggestionApplyLabel(for: id))
    // Rebases every other thread/suggestion, plus this suggestion's own
    // remaining hunks, through the applied edits (`INV-RVW-015`, `INV-RVW-020`).
    rebase(through: transactionManager.lastCommittedEdits)
    let rebasedRemaining = suggestions[index].hunks.filter { remainingIDs.contains($0.id) }
    suggestions[index].hunks = preApplyHunks

    guard !rebasedRemaining.isEmpty else {
      suggestions[index].state = .applied
      return (snapshot, nil)
    }

    let remainingSuggestion = ReviewSuggestion(
      hunks: rebasedRemaining,
      description: suggestions[index].description,
      baseRevision: snapshot.revision
    )
    suggestions.append(remainingSuggestion)
    suggestions[index].state = .partiallyApplied
    return (snapshot, remainingSuggestion)
  }

  // MARK: - Rebase

  /// Rebase every anchor through `edits`. Call after an external edit or any
  /// direct `EditorTransactionManager.apply` that bypassed this manager
  /// (`INV-RVW-020`).
  public func rebase(through edits: [TextEdit]) {
    for tIndex in threads.indices {
      for cIndex in threads[tIndex].comments.indices {
        threads[tIndex].comments[cIndex].anchor.rebase(through: edits)
      }
    }
    for sIndex in suggestions.indices {
      for hIndex in suggestions[sIndex].hunks.indices {
        suggestions[sIndex].hunks[hIndex].anchor.rebase(through: edits)
      }
    }
  }

  // MARK: - Private

  private func validateSuggestionForApply(
    _ suggestion: ReviewSuggestion,
    against currentRevision: TextRevision
  ) throws {
    guard suggestion.state == .pending else {
      throw ReviewThreadManagerError.suggestionNotPending
    }
    guard suggestion.baseRevision == currentRevision else {
      throw ReviewThreadManagerError.suggestionRevisionMismatch
    }
    guard suggestion.isAttached else {
      throw ReviewThreadManagerError.suggestionNotApplicable
    }
  }

  private func suggestionApplyLabel(for suggestionID: UUID) -> String {
    "clair.review.apply-suggestion:\(suggestionID.uuidString)"
  }
}

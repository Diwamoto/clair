import Foundation

enum ProjectEditorCommentAnchorStatus: String, Codable, Equatable, Sendable {
  case active
  case orphan
}

struct ProjectEditorCommentAnchor: Codable, Equatable, Sendable {
  let id: String
  let documentID: String
  let range: ProjectEditorUTF16Range
  let revision: UInt64
  let status: ProjectEditorCommentAnchorStatus

  init(
    id: String,
    documentID: String,
    range: ProjectEditorUTF16Range,
    revision: UInt64,
    status: ProjectEditorCommentAnchorStatus = .active
  ) {
    self.id = id
    self.documentID = documentID
    self.range = range
    self.revision = revision
    self.status = status
  }
}

struct ProjectEditorCommentAnchorSnapshot: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let documentID: String
  let documentRevision: UInt64
  let anchors: [ProjectEditorCommentAnchor]

  static let currentSchemaVersion = 1
}

enum ProjectEditorCommentAnchorError: Error, Equatable, LocalizedError, Sendable {
  case staleRevision(expected: UInt64, actual: UInt64)
  case invalidRevision(UInt64)
  case invalidRange(String)
  case overlappingEdits
  case documentMismatch(expectedID: String, actualID: String, expectedRevision: UInt64, actualRevision: UInt64)
  case historyUnavailable

  var errorDescription: String? {
    switch self {
    case .staleRevision(let expected, let actual):
      "Comment anchors target revision \(expected), but the document is at revision \(actual)."
    case .invalidRevision(let revision):
      "Comment anchor revision \(revision) is not newer than the current document revision."
    case .invalidRange(let anchorID):
      "Comment anchor \(anchorID) has an invalid UTF-16 range."
    case .overlappingEdits:
      "Comment anchor edits must not overlap."
    case .documentMismatch(let expectedID, let actualID, let expectedRevision, let actualRevision):
      "Comment anchors belong to \(expectedID) at revision \(expectedRevision), not \(actualID) at revision \(actualRevision)."
    case .historyUnavailable:
      "The requested comment anchor history entry is unavailable."
    }
  }
}

enum ProjectEditorCommentAnchorOperation: String, Codable, Equatable, Sendable {
  case apply
  case undo
  case redo
  case orphaned
  case restore
}

struct ProjectEditorCommentAnchorChange: Equatable, Sendable {
  let operation: ProjectEditorCommentAnchorOperation
  let documentRevision: UInt64
  let affectedAnchorIDs: [String]
  let historyID: UUID?
}

/// Keeps comments separate from document text and maps their ranges using the
/// same pre-edit UTF-16 coordinates as ProjectEditorDocumentModel.
final class ProjectEditorCommentAnchorStore {
  private struct HistoryEntry: Sendable {
    let id: UUID
    let before: [String: ProjectEditorCommentAnchor]
    let after: [String: ProjectEditorCommentAnchor]
    let baseRevision: UInt64
    let resultingRevision: UInt64
  }

  private enum BoundaryAffinity {
    case before
    case after
  }

  let documentID: String
  private(set) var documentRevision: UInt64
  private(set) var anchors: [String: ProjectEditorCommentAnchor]

  private var undoStack: [HistoryEntry] = []
  private var redoStack: [HistoryEntry] = []

  init(
    documentID: String,
    documentRevision: UInt64 = 0,
    anchors: [ProjectEditorCommentAnchor] = []
  ) {
    self.documentID = documentID
    self.documentRevision = documentRevision
    self.anchors = Dictionary(uniqueKeysWithValues: anchors.map { ($0.id, $0) })
  }

  func anchor(withID id: String) -> ProjectEditorCommentAnchor? {
    anchors[id]
  }

  @discardableResult
  func addAnchor(
    id: String,
    range: ProjectEditorUTF16Range,
    revision: UInt64? = nil
  ) throws -> ProjectEditorCommentAnchor {
    guard range.location >= 0, range.length >= 0,
      range.location <= Int.max - range.length
    else {
      throw ProjectEditorCommentAnchorError.invalidRange(id)
    }

    let anchor = ProjectEditorCommentAnchor(
      id: id,
      documentID: documentID,
      range: range,
      revision: revision ?? documentRevision
    )
    anchors[id] = anchor
    return anchor
  }

  @discardableResult
  func apply(
    _ transaction: ProjectEditorTransaction,
    resultingRevision: UInt64
  ) throws -> ProjectEditorCommentAnchorChange {
    guard transaction.baseRevision == documentRevision else {
      throw ProjectEditorCommentAnchorError.staleRevision(
        expected: transaction.baseRevision,
        actual: documentRevision
      )
    }
    guard resultingRevision > documentRevision else {
      throw ProjectEditorCommentAnchorError.invalidRevision(resultingRevision)
    }
    try validateEdits(transaction.edits)

    let before = anchors
    var next: [String: ProjectEditorCommentAnchor] = [:]
    for anchor in anchors.values {
      let mapped = map(anchor: anchor, edits: transaction.edits, revision: resultingRevision)
      next[anchor.id] = mapped
    }

    let historyID = UUID()
    let entry = HistoryEntry(
      id: historyID,
      before: before,
      after: next,
      baseRevision: documentRevision,
      resultingRevision: resultingRevision
    )
    anchors = next
    documentRevision = resultingRevision
    undoStack.append(entry)
    redoStack.removeAll()

    return ProjectEditorCommentAnchorChange(
      operation: .apply,
      documentRevision: resultingRevision,
      affectedAnchorIDs: next.keys.sorted(),
      historyID: historyID
    )
  }

  /// Applies the anchor side of a document undo transaction. The document
  /// revision is monotonic: undo is a new revision, while the previous anchor
  /// state is recovered from the exact history entry, never by text search.
  @discardableResult
  func undo(toDocumentRevision revision: UInt64) throws -> ProjectEditorCommentAnchorChange {
    guard let entry = undoStack.popLast(), revision > documentRevision else {
      throw ProjectEditorCommentAnchorError.historyUnavailable
    }
    anchors = entry.before.mapValues { anchor in
      ProjectEditorCommentAnchor(
        id: anchor.id,
        documentID: anchor.documentID,
        range: anchor.range,
        revision: revision,
        status: anchor.status
      )
    }
    documentRevision = revision
    redoStack.append(entry)
    return ProjectEditorCommentAnchorChange(
      operation: .undo,
      documentRevision: revision,
      affectedAnchorIDs: entry.before.keys.sorted(),
      historyID: entry.id
    )
  }

  @discardableResult
  func redo(toDocumentRevision revision: UInt64) throws -> ProjectEditorCommentAnchorChange {
    guard let entry = redoStack.popLast(), revision > documentRevision else {
      throw ProjectEditorCommentAnchorError.historyUnavailable
    }
    anchors = entry.after.mapValues { anchor in
      ProjectEditorCommentAnchor(
        id: anchor.id,
        documentID: anchor.documentID,
        range: anchor.range,
        revision: revision,
        status: anchor.status
      )
    }
    documentRevision = revision
    undoStack.append(entry)
    return ProjectEditorCommentAnchorChange(
      operation: .redo,
      documentRevision: revision,
      affectedAnchorIDs: entry.after.keys.sorted(),
      historyID: entry.id
    )
  }

  func snapshot() -> ProjectEditorCommentAnchorSnapshot {
    ProjectEditorCommentAnchorSnapshot(
      schemaVersion: ProjectEditorCommentAnchorSnapshot.currentSchemaVersion,
      documentID: documentID,
      documentRevision: documentRevision,
      anchors: anchors.values.sorted { $0.id < $1.id }
    )
  }

  @discardableResult
  func restore(
    _ snapshot: ProjectEditorCommentAnchorSnapshot,
    currentDocumentID: String = "",
    currentDocumentRevision: UInt64
  ) throws -> ProjectEditorCommentAnchorChange {
    let actualID = currentDocumentID.isEmpty ? documentID : currentDocumentID
    guard snapshot.schemaVersion == ProjectEditorCommentAnchorSnapshot.currentSchemaVersion,
      snapshot.documentID == documentID,
      actualID == documentID,
      snapshot.documentRevision == currentDocumentRevision,
      currentDocumentRevision == documentRevision
    else {
      throw ProjectEditorCommentAnchorError.documentMismatch(
        expectedID: snapshot.documentID,
        actualID: actualID,
        expectedRevision: snapshot.documentRevision,
        actualRevision: currentDocumentRevision
      )
    }

    anchors = Dictionary(uniqueKeysWithValues: snapshot.anchors.map { ($0.id, $0) })
    undoStack.removeAll()
    redoStack.removeAll()
    return ProjectEditorCommentAnchorChange(
      operation: .restore,
      documentRevision: documentRevision,
      affectedAnchorIDs: anchors.keys.sorted(),
      historyID: nil
    )
  }

  @discardableResult
  func markAllOrphaned(at revision: UInt64) throws -> ProjectEditorCommentAnchorChange {
    guard revision >= documentRevision else {
      throw ProjectEditorCommentAnchorError.invalidRevision(revision)
    }
    anchors = anchors.mapValues {
      ProjectEditorCommentAnchor(
        id: $0.id,
        documentID: $0.documentID,
        range: $0.range,
        revision: revision,
        status: .orphan
      )
    }
    documentRevision = revision
    undoStack.removeAll()
    redoStack.removeAll()
    return ProjectEditorCommentAnchorChange(
      operation: .orphaned,
      documentRevision: revision,
      affectedAnchorIDs: anchors.keys.sorted(),
      historyID: nil
    )
  }

  private func validateEdits(_ edits: [ProjectEditorReplacement]) throws {
    guard !edits.isEmpty else {
      return
    }
    for edit in edits {
      guard edit.range.location >= 0, edit.range.length >= 0,
        edit.range.location <= Int.max - edit.range.length
      else {
        throw ProjectEditorCommentAnchorError.overlappingEdits
      }
    }
    let sorted = edits.sorted { $0.range.location < $1.range.location }
    for pair in zip(sorted, sorted.dropFirst()) where pair.0.range.end > pair.1.range.location {
      throw ProjectEditorCommentAnchorError.overlappingEdits
    }
  }

  private func map(
    anchor: ProjectEditorCommentAnchor,
    edits: [ProjectEditorReplacement],
    revision: UInt64
  ) -> ProjectEditorCommentAnchor {
    guard anchor.status == .active else {
      return ProjectEditorCommentAnchor(
        id: anchor.id,
        documentID: anchor.documentID,
        range: anchor.range,
        revision: revision,
        status: .orphan
      )
    }

    let sortedEdits = edits.sorted { $0.range.location < $1.range.location }
    let isFullyReplaced = anchor.range.length > 0 && isCovered(
      anchor.range,
      by: sortedEdits
    )
    let start = mapBoundary(
      anchor.range.location,
      affinity: .after,
      edits: sortedEdits
    )
    let end = mapBoundary(
      anchor.range.end,
      affinity: .before,
      edits: sortedEdits
    )
    let mappedLength = max(0, end - start)
    let status: ProjectEditorCommentAnchorStatus =
      isFullyReplaced || (anchor.range.length > 0 && mappedLength == 0)
      ? .orphan
      : .active
    return ProjectEditorCommentAnchor(
      id: anchor.id,
      documentID: anchor.documentID,
      range: ProjectEditorUTF16Range(location: start, length: mappedLength),
      revision: revision,
      status: status
    )
  }

  private func isCovered(
    _ range: ProjectEditorUTF16Range,
    by edits: [ProjectEditorReplacement]
  ) -> Bool {
    var coveredUntil = range.location
    for edit in edits where edit.range.length > 0 {
      guard edit.range.end > coveredUntil else {
        continue
      }
      guard edit.range.location <= coveredUntil else {
        break
      }
      coveredUntil = max(coveredUntil, edit.range.end)
      if coveredUntil >= range.end {
        return true
      }
    }
    return false
  }

  private func mapBoundary(
    _ position: Int,
    affinity: BoundaryAffinity,
    edits: [ProjectEditorReplacement]
  ) -> Int {
    var delta = 0
    for edit in edits {
      let start = edit.range.location
      let end = edit.range.end
      let insertedLength = edit.text.utf16.count
      if position < start {
        break
      }
      if position > end {
        delta += insertedLength - edit.range.length
        continue
      }

      if start == end {
        if position == start, affinity == .after {
          delta += insertedLength
        }
        continue
      }

      if position == start {
        return start + delta + (affinity == .after ? insertedLength : 0)
      }
      if position == end {
        return start + delta + (affinity == .before ? 0 : insertedLength)
      }
      return start + delta + (affinity == .after ? insertedLength : 0)
    }
    return position + delta
  }
}

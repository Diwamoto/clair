import Foundation

struct ProjectEditorUTF16Range: Codable, Equatable, Hashable, Sendable {
  let location: Int
  let length: Int

  init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }

  var end: Int {
    location + length
  }

  var nsRange: NSRange {
    NSRange(location: location, length: length)
  }
}

enum ProjectEditorDocumentError: Error, Equatable, LocalizedError, Sendable {
  case emptyTransaction
  case staleRevision(expected: UInt64, actual: UInt64)
  case invalidRange(index: Int, range: ProjectEditorUTF16Range, documentLength: Int)
  case invalidUTF16Boundary(index: Int, range: ProjectEditorUTF16Range)
  case overlappingEdits(firstIndex: Int, secondIndex: Int)

  var errorDescription: String? {
    switch self {
    case .emptyTransaction:
      "The editor transaction does not contain any text edits."
    case .staleRevision(let expected, let actual):
      "The editor transaction targets revision \(expected), but the document is at revision \(actual)."
    case .invalidRange(let index, let range, let documentLength):
      "Editor edit \(index) has invalid UTF-16 range \(range.location):\(range.length) for document length \(documentLength)."
    case .invalidUTF16Boundary(let index, let range):
      "Editor edit \(index) splits a Unicode scalar in UTF-16 range \(range.location):\(range.length)."
    case .overlappingEdits(let firstIndex, let secondIndex):
      "Editor edits \(firstIndex) and \(secondIndex) overlap and cannot be applied atomically."
    }
  }
}

enum ProjectEditorChangeSource: String, Codable, Equatable, Sendable {
  case user
  case agent
  case restore
  case external
  case system
}

enum ProjectEditorUndoUnit: String, Codable, Equatable, Sendable {
  case typing
  case deletion
  case paste
  case formatting
  case suggestion
  case restore
  case externalReload
}

enum ProjectEditorSnapshotReason: String, Codable, Equatable, Sendable {
  case initialLoad
  case save
  case diff
}

struct ProjectEditorReplacement: Codable, Equatable, Sendable {
  let range: ProjectEditorUTF16Range
  let text: String

  init(range: ProjectEditorUTF16Range, text: String) {
    self.range = range
    self.text = text
  }
}

struct ProjectEditorTransaction: Codable, Equatable, Sendable {
  let baseRevision: UInt64
  let edits: [ProjectEditorReplacement]
  let source: ProjectEditorChangeSource
  let undoUnit: ProjectEditorUndoUnit

  init(
    baseRevision: UInt64,
    edits: [ProjectEditorReplacement],
    source: ProjectEditorChangeSource,
    undoUnit: ProjectEditorUndoUnit
  ) {
    self.baseRevision = baseRevision
    self.edits = edits
    self.source = source
    self.undoUnit = undoUnit
  }
}

struct ProjectEditorSnapshot: Codable, Equatable, Sendable {
  let revision: UInt64
  let content: String
  let reason: ProjectEditorSnapshotReason
}

struct ProjectEditorDocumentChange: Equatable, Sendable {
  let revision: UInt64
  let source: ProjectEditorChangeSource
  let undoUnit: ProjectEditorUndoUnit
  /// Ranges are expressed in the resulting document, not the transaction's
  /// pre-edit coordinate space.
  let changedRanges: [ProjectEditorUTF16Range]
}

/// Engine-independent document contract shared by native editor adapters.
///
/// Transactions use one revision and one coordinate space: every edit in a
/// transaction addresses the document at `baseRevision`. Validation happens
/// before mutation so a failed transaction cannot partially change the text.
///
/// The text itself lives in a `TextBuffer` piece table, so applying a
/// transaction costs the size of the edit rather than the size of the document.
/// The contract above the model is unchanged: revisions, UTF-16 ranges, the
/// validation order, and the change notification are exactly what they were when
/// the model held a `String`.
final class ProjectEditorDocumentModel {
  private let buffer: TextBuffer
  private var materializedContent: String?
  private(set) var revision: UInt64
  private(set) var selection: ProjectEditorUTF16Range?

  /// These counters are intentionally observable for contract tests. Production
  /// callers should use `snapshot(reason:)` only at load/save/diff boundaries,
  /// and applying a transaction must not materialize the whole document.
  private(set) var snapshotCaptureCount = 0
  private(set) var contentMaterializationCount = 0

  var onChange: ((ProjectEditorDocumentChange) -> Void)?
  var onSelectionChange: ((ProjectEditorUTF16Range?) -> Void)?

  init(content: String, revision: UInt64 = 0) {
    self.buffer = TextBuffer(content)
    self.materializedContent = content
    self.revision = revision
  }

  /// The whole document as a string. It is rebuilt from the buffer only after an
  /// edit, and then cached, so repeated reads between edits stay free.
  var content: String {
    if let materializedContent {
      return materializedContent
    }
    let text = buffer.content
    materializedContent = text
    contentMaterializationCount += 1
    return text
  }

  var utf16Length: Int {
    buffer.utf16Length
  }

  var lineCount: Int {
    buffer.lineCount
  }

  func snapshot(reason: ProjectEditorSnapshotReason) -> ProjectEditorSnapshot {
    snapshotCaptureCount += 1
    return ProjectEditorSnapshot(
      revision: revision,
      content: content,
      reason: reason
    )
  }

  /// Replaces the document at an explicit synchronization boundary.
  ///
  /// External reloads and native host restores are not represented as a
  /// collection of user edits. They invalidate the old coordinate space, so
  /// the caller supplies the revision that the next bridge snapshot should
  /// advertise (or lets the model advance it once).
  func replaceSnapshot(content newContent: String, revision newRevision: UInt64? = nil) {
    buffer.replaceAll(with: newContent)
    materializedContent = newContent
    revision = newRevision ?? revision &+ 1
    selection = nil
  }

  /// 1-based line and column for a UTF-16 offset, the coordinate space gutters,
  /// diffs, and `clair open path:line:column` use.
  func position(forUTF16Offset offset: Int) -> TextBufferPosition? {
    buffer.position(forUTF16Offset: offset)
  }

  func utf16Offset(for position: TextBufferPosition) -> Int? {
    buffer.utf16Offset(for: position)
  }

  /// Grapheme-cluster boundaries for caret motion. Callers must move the caret
  /// with these rather than by adding UTF-16 units.
  func characterBoundary(after offset: Int) -> Int? {
    buffer.characterBoundary(after: offset)
  }

  func characterBoundary(before offset: Int) -> Int? {
    buffer.characterBoundary(before: offset)
  }

  func text(in range: ProjectEditorUTF16Range) -> String? {
    buffer.text(inUTF16Range: range.location..<range.end)
  }

  func setSelection(_ nextSelection: ProjectEditorUTF16Range?) throws {
    if let nextSelection {
      try validate(
        nextSelection,
        at: 0,
        allowEnd: true
      )
    }
    guard selection != nextSelection else {
      return
    }
    selection = nextSelection
    onSelectionChange?(nextSelection)
  }

  @discardableResult
  func apply(_ transaction: ProjectEditorTransaction) throws -> ProjectEditorDocumentChange {
    guard !transaction.edits.isEmpty else {
      throw ProjectEditorDocumentError.emptyTransaction
    }
    guard transaction.baseRevision == revision else {
      throw ProjectEditorDocumentError.staleRevision(
        expected: transaction.baseRevision,
        actual: revision
      )
    }

    let indexedEdits = transaction.edits.enumerated().map { (index: $0.offset, edit: $0.element) }
    for item in indexedEdits {
      try validate(item.edit.range, at: item.index, allowEnd: true)
    }

    let sortedEdits = indexedEdits.sorted {
      if $0.edit.range.location == $1.edit.range.location {
        return $0.index < $1.index
      }
      return $0.edit.range.location < $1.edit.range.location
    }
    for pair in zip(sortedEdits, sortedEdits.dropFirst()) {
      let first = pair.0
      let second = pair.1
      if first.edit.range.end > second.edit.range.location {
        throw ProjectEditorDocumentError.overlappingEdits(
          firstIndex: first.index,
          secondIndex: second.index
        )
      }
    }

    // Applying from the end keeps every remaining edit addressed in the
    // transaction's pre-edit coordinate space. Every range has already been
    // bounds- and boundary-checked above, which is what lets the buffer mutate
    // here without any risk of a half-applied transaction.
    for item in sortedEdits.reversed() {
      try buffer.replace(
        utf16Range: item.edit.range.location..<item.edit.range.end,
        with: item.edit.text
      )
    }

    var changedRanges: [ProjectEditorUTF16Range] = []
    var offsetDelta = 0
    for item in sortedEdits {
      let replacementLength = item.edit.text.utf16.count
      let resultingLocation = item.edit.range.location + offsetDelta
      changedRanges.append(
        ProjectEditorUTF16Range(
          location: resultingLocation,
          length: replacementLength
        )
      )
      offsetDelta += replacementLength - item.edit.range.length
    }

    materializedContent = nil
    revision += 1
    let change = ProjectEditorDocumentChange(
      revision: revision,
      source: transaction.source,
      undoUnit: transaction.undoUnit,
      changedRanges: changedRanges
    )
    onChange?(change)
    return change
  }

  private func validate(
    _ range: ProjectEditorUTF16Range,
    at index: Int,
    allowEnd: Bool
  ) throws {
    guard range.location >= 0, range.length >= 0,
      range.location <= Int.max - range.length,
      range.end <= utf16Length,
      allowEnd || range.end < utf16Length
    else {
      throw ProjectEditorDocumentError.invalidRange(
        index: index,
        range: range,
        documentLength: utf16Length
      )
    }

    guard isUTF16Boundary(range.location), isUTF16Boundary(range.end) else {
      throw ProjectEditorDocumentError.invalidUTF16Boundary(index: index, range: range)
    }
  }

  private func isUTF16Boundary(_ offset: Int) -> Bool {
    buffer.isCharacterBoundary(utf16Offset: offset)
  }
}

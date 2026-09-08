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
final class ProjectEditorDocumentModel {
  private(set) var content: String
  private(set) var revision: UInt64
  private(set) var selection: ProjectEditorUTF16Range?

  /// This counter is intentionally observable for contract tests. Production
  /// callers should use `snapshot(reason:)` only at load/save/diff boundaries.
  private(set) var snapshotCaptureCount = 0

  var onChange: ((ProjectEditorDocumentChange) -> Void)?
  var onSelectionChange: ((ProjectEditorUTF16Range?) -> Void)?

  init(content: String, revision: UInt64 = 0) {
    self.content = content
    self.revision = revision
  }

  var utf16Length: Int {
    content.utf16.count
  }

  func snapshot(reason: ProjectEditorSnapshotReason) -> ProjectEditorSnapshot {
    snapshotCaptureCount += 1
    return ProjectEditorSnapshot(
      revision: revision,
      content: content,
      reason: reason
    )
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

    let updatedContent = NSMutableString(string: content)
    for item in sortedEdits.reversed() {
      updatedContent.replaceCharacters(
        in: item.edit.range.nsRange,
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

    content = updatedContent as String
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
    guard offset >= 0, offset <= utf16Length else {
      return false
    }
    let utf16Index = content.utf16.index(
      content.utf16.startIndex,
      offsetBy: offset
    )
    return String.Index(utf16Index, within: content) != nil
  }
}

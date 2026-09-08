import Foundation

enum ProjectEditorSuggestionSelection: Equatable, Sendable {
  case all
  case line(id: String)
  case lines(ids: Set<String>)
  case hunk(id: String)
  case hunks(ids: Set<String>)
  case range(ProjectEditorUTF16Range)
}

enum ProjectEditorSuggestionError: Error, Equatable, LocalizedError, Sendable {
  case documentMismatch(expected: String, actual: String)
  case staleRevision(expected: UInt64, actual: UInt64)
  case conflictingBase
  case unknownSelection(String)
  case emptySelection
  case unsupportedPartialSelection(ProjectEditorUTF16Range)
  case noChanges
  case undoUnavailable
  case undoConflict

  var errorDescription: String? {
    switch self {
    case .documentMismatch(let expected, let actual):
      "The suggestion targets document \(expected), not \(actual)."
    case .staleRevision(let expected, let actual):
      "The suggestion targets revision \(expected), but the document is at revision \(actual)."
    case .conflictingBase:
      "The document changed after this suggestion was created. Request a new suggestion."
    case .unknownSelection(let id):
      "The suggestion selection \(id) is no longer available."
    case .emptySelection:
      "The suggestion selection does not contain any changes."
    case .unsupportedPartialSelection(let range):
      "Only complete changed lines or hunks can be selected; partial range \(range.location):\(range.length) is unsupported."
    case .noChanges:
      "The suggestion does not contain any changes."
    case .undoUnavailable:
      "There is no suggestion application to undo."
    case .undoConflict:
      "The document changed after the suggestion was applied, so its undo is no longer safe."
    }
  }
}

struct ProjectEditorSuggestionEdit: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let lineID: String
  let hunkID: String
  let range: ProjectEditorUTF16Range
  let expectedText: String
  let replacementText: String
}

struct ProjectEditorSuggestionProposal: Codable, Equatable, Sendable {
  let id: String
  let documentID: String
  let path: String
  let baseRevision: UInt64
  let baseContent: String
  let proposedContent: String
  let edits: [ProjectEditorSuggestionEdit]

  var lineIDs: Set<String> {
    Set(edits.map(\.lineID))
  }

  var hunkIDs: Set<String> {
    Set(edits.map(\.hunkID))
  }

  func transaction(
    for selection: ProjectEditorSuggestionSelection,
    source: ProjectEditorChangeSource = .agent
  ) throws -> ProjectEditorTransaction {
    let selectedEdits: [ProjectEditorSuggestionEdit]
    switch selection {
    case .all:
      selectedEdits = edits
    case .line(let id):
      selectedEdits = try edits(matching: [id], keyPath: \.lineID)
    case .lines(let ids):
      selectedEdits = try edits(matching: ids, keyPath: \.lineID)
    case .hunk(let id):
      selectedEdits = try edits(matching: [id], keyPath: \.hunkID)
    case .hunks(let ids):
      selectedEdits = try edits(matching: ids, keyPath: \.hunkID)
    case .range(let range):
      throw ProjectEditorSuggestionError.unsupportedPartialSelection(range)
    }

    guard !selectedEdits.isEmpty else {
      throw ProjectEditorSuggestionError.emptySelection
    }
    return ProjectEditorTransaction(
      baseRevision: baseRevision,
      edits: selectedEdits.map {
        ProjectEditorReplacement(range: $0.range, text: $0.replacementText)
      },
      source: source,
      undoUnit: .suggestion
    )
  }

  private func edits(
    matching ids: Set<String>,
    keyPath: KeyPath<ProjectEditorSuggestionEdit, String>
  ) throws -> [ProjectEditorSuggestionEdit] {
    guard !ids.isEmpty else {
      throw ProjectEditorSuggestionError.emptySelection
    }
    let selected = edits.filter { ids.contains($0[keyPath: keyPath]) }
    guard ids.allSatisfy({ id in selected.contains { $0[keyPath: keyPath] == id } }) else {
      let unknown =
        ids.first { id in !selected.contains { $0[keyPath: keyPath] == id } } ?? "unknown"
      throw ProjectEditorSuggestionError.unknownSelection(unknown)
    }
    return selected
  }
}

struct ProjectEditorSuggestionRequest: Codable, Equatable, Sendable {
  let documentID: String
  let path: String
  let baseRevision: UInt64
  let baseContent: String
}

protocol ProjectEditorSuggestionProvider: Sendable {
  func propose(_ request: ProjectEditorSuggestionRequest) async throws
    -> ProjectEditorSuggestionProposal
}

/// A local-only model boundary for fixtures. It deliberately has no service,
/// credential, network, or vendor-specific behavior.
struct ProjectEditorFakeSuggestionProvider: ProjectEditorSuggestionProvider {
  let proposedContent: String

  func propose(_ request: ProjectEditorSuggestionRequest) async throws
    -> ProjectEditorSuggestionProposal
  {
    try ProjectEditorSuggestionModel.makeProposal(
      documentID: request.documentID,
      path: request.path,
      baseRevision: request.baseRevision,
      baseContent: request.baseContent,
      proposedContent: proposedContent
    )
  }
}

enum ProjectEditorSuggestionModel {
  private struct LineSlice {
    let start: Int
    let end: Int
  }

  static func makeProposal(
    documentID: String,
    path: String,
    baseRevision: UInt64,
    baseContent: String,
    proposedContent: String
  ) throws -> ProjectEditorSuggestionProposal {
    let old = ProjectEditorDiffInput(
      documentID: documentID,
      path: path,
      revision: baseRevision,
      content: baseContent
    )
    let new = ProjectEditorDiffInput(
      documentID: documentID,
      path: path,
      revision: baseRevision &+ 1,
      content: proposedContent
    )
    let diff = ProjectEditorDiffModel.calculate(old: old, new: new, contextLines: 0)
    let oldLines = lineSlices(in: baseContent)
    var edits: [ProjectEditorSuggestionEdit] = []

    for (rowIndex, row) in diff.rows.enumerated() where row.kind != .context {
      guard let hunkID = row.hunkID else {
        continue
      }
      let range: ProjectEditorUTF16Range
      let expectedText: String
      if let oldLineNumber = row.oldLineNumber {
        let slice = oldLines[oldLineNumber - 1]
        range = ProjectEditorUTF16Range(location: slice.start, length: slice.end - slice.start)
        expectedText = substring(of: baseContent, range: range)
      } else {
        let location = insertionLocation(
          for: rowIndex,
          rows: diff.rows,
          oldLines: oldLines,
          oldLength: baseContent.utf16.count
        )
        range = ProjectEditorUTF16Range(location: location, length: 0)
        expectedText = ""
      }

      edits.append(
        ProjectEditorSuggestionEdit(
          id: "\(row.id):base:\(baseRevision)",
          lineID: row.id,
          hunkID: hunkID,
          range: range,
          expectedText: expectedText,
          replacementText: row.newSource ?? ""
        )
      )
    }

    let proposalID =
      "\(documentID):suggestion:\(baseRevision):\(edits.map(\.id).joined(separator: ","))"
    return ProjectEditorSuggestionProposal(
      id: proposalID,
      documentID: documentID,
      path: path,
      baseRevision: baseRevision,
      baseContent: baseContent,
      proposedContent: proposedContent,
      edits: edits
    )
  }

  private static func lineSlices(in content: String) -> [LineSlice] {
    guard !content.isEmpty else {
      return []
    }
    let scalars = content.unicodeScalars
    var result: [LineSlice] = []
    var lineStart = scalars.startIndex
    var cursor = scalars.startIndex

    while cursor < scalars.endIndex {
      let scalar = scalars[cursor]
      guard scalar == "\n" || scalar == "\r" else {
        cursor = scalars.index(after: cursor)
        continue
      }
      let afterTerminator: String.Index
      if scalar == "\r" {
        let next = scalars.index(after: cursor)
        afterTerminator =
          next < scalars.endIndex && scalars[next] == "\n"
          ? scalars.index(after: next)
          : next
      } else {
        afterTerminator = scalars.index(after: cursor)
      }
      result.append(
        LineSlice(
          start: content.utf16.distance(
            from: content.startIndex, to: String.Index(lineStart, within: content)!),
          end: content.utf16.distance(
            from: content.startIndex, to: String.Index(afterTerminator, within: content)!)
        )
      )
      lineStart = afterTerminator
      cursor = afterTerminator
    }
    if lineStart < scalars.endIndex {
      result.append(
        LineSlice(
          start: content.utf16.distance(
            from: content.startIndex, to: String.Index(lineStart, within: content)!),
          end: content.utf16.count
        )
      )
    }
    return result
  }

  private static func insertionLocation(
    for rowIndex: Int,
    rows: [ProjectEditorDiffLine],
    oldLines: [LineSlice],
    oldLength: Int
  ) -> Int {
    if rowIndex > 0 {
      for previousIndex in stride(from: rowIndex - 1, through: 0, by: -1) {
        if let oldLineNumber = rows[previousIndex].oldLineNumber {
          return oldLines[oldLineNumber - 1].end
        }
      }
    }
    if rowIndex + 1 < rows.count {
      for nextIndex in (rowIndex + 1)..<rows.count {
        if let oldLineNumber = rows[nextIndex].oldLineNumber {
          return oldLines[oldLineNumber - 1].start
        }
      }
    }
    return oldLength
  }

  private static func substring(of content: String, range: ProjectEditorUTF16Range) -> String {
    (content as NSString).substring(with: range.nsRange)
  }
}

struct ProjectEditorSuggestionApplication: Equatable, Sendable {
  let change: ProjectEditorDocumentChange
  let remainingProposal: ProjectEditorSuggestionProposal?
}

enum ProjectEditorSuggestionDecision: Equatable, Sendable {
  case rejected
  case applied(ProjectEditorSuggestionApplication)
}

/// Applies a validated proposal through the document transaction boundary and
/// keeps one transaction-sized inverse for safe, single-step undo.
final class ProjectEditorSuggestionApplier {
  private struct UndoEntry {
    let documentID: String
    let revision: UInt64
    let contentAfterApply: String
    let inverseEdits: [ProjectEditorReplacement]
  }

  private var undoEntries: [UndoEntry] = []

  func reject(_ proposal: ProjectEditorSuggestionProposal) -> ProjectEditorSuggestionDecision {
    .rejected
  }

  @discardableResult
  func approve(
    _ proposal: ProjectEditorSuggestionProposal,
    selection: ProjectEditorSuggestionSelection = .all,
    documentID: String,
    document: ProjectEditorDocumentModel
  ) throws -> ProjectEditorSuggestionApplication {
    guard proposal.documentID == documentID else {
      throw ProjectEditorSuggestionError.documentMismatch(
        expected: proposal.documentID, actual: documentID)
    }
    guard proposal.baseRevision == document.revision else {
      throw ProjectEditorSuggestionError.staleRevision(
        expected: proposal.baseRevision, actual: document.revision)
    }
    guard proposal.baseContent == document.content else {
      throw ProjectEditorSuggestionError.conflictingBase
    }

    let selectedEdits = try selectedEdits(in: proposal, selection: selection)
    let transaction = try proposal.transaction(for: selection)
    let change = try document.apply(transaction)
    let inverseEdits = zip(selectedEdits, change.changedRanges).map { edit, resultingRange in
      ProjectEditorReplacement(range: resultingRange, text: edit.expectedText)
    }
    undoEntries.append(
      UndoEntry(
        documentID: documentID,
        revision: change.revision,
        contentAfterApply: document.content,
        inverseEdits: inverseEdits
      )
    )

    let remainingProposal: ProjectEditorSuggestionProposal?
    if document.content == proposal.proposedContent {
      remainingProposal = nil
    } else {
      remainingProposal = try ProjectEditorSuggestionModel.makeProposal(
        documentID: proposal.documentID,
        path: proposal.path,
        baseRevision: document.revision,
        baseContent: document.content,
        proposedContent: proposal.proposedContent
      )
    }
    return ProjectEditorSuggestionApplication(change: change, remainingProposal: remainingProposal)
  }

  @discardableResult
  func undoLast(
    documentID: String,
    document: ProjectEditorDocumentModel
  ) throws -> ProjectEditorDocumentChange {
    guard let entry = undoEntries.last, entry.documentID == documentID else {
      throw ProjectEditorSuggestionError.undoUnavailable
    }
    guard entry.revision <= document.revision, entry.contentAfterApply == document.content else {
      throw ProjectEditorSuggestionError.undoConflict
    }
    let change = try document.apply(
      ProjectEditorTransaction(
        baseRevision: document.revision,
        edits: entry.inverseEdits,
        source: .user,
        undoUnit: .suggestion
      )
    )
    undoEntries.removeLast()
    return change
  }

  private func selectedEdits(
    in proposal: ProjectEditorSuggestionProposal,
    selection: ProjectEditorSuggestionSelection
  ) throws -> [ProjectEditorSuggestionEdit] {
    switch selection {
    case .all:
      guard !proposal.edits.isEmpty else { throw ProjectEditorSuggestionError.noChanges }
      return proposal.edits
    case .line(let id):
      return try selectedEdits(in: proposal, ids: [id], keyPath: \.lineID)
    case .lines(let ids):
      return try selectedEdits(in: proposal, ids: ids, keyPath: \.lineID)
    case .hunk(let id):
      return try selectedEdits(in: proposal, ids: [id], keyPath: \.hunkID)
    case .hunks(let ids):
      return try selectedEdits(in: proposal, ids: ids, keyPath: \.hunkID)
    case .range(let range):
      throw ProjectEditorSuggestionError.unsupportedPartialSelection(range)
    }
  }

  private func selectedEdits(
    in proposal: ProjectEditorSuggestionProposal,
    ids: Set<String>,
    keyPath: KeyPath<ProjectEditorSuggestionEdit, String>
  ) throws -> [ProjectEditorSuggestionEdit] {
    guard !ids.isEmpty else { throw ProjectEditorSuggestionError.emptySelection }
    let selected = proposal.edits.filter { ids.contains($0[keyPath: keyPath]) }
    guard ids.allSatisfy({ id in selected.contains { $0[keyPath: keyPath] == id } }) else {
      let unknown =
        ids.first { id in !selected.contains { $0[keyPath: keyPath] == id } } ?? "unknown"
      throw ProjectEditorSuggestionError.unknownSelection(unknown)
    }
    return selected
  }
}

import Foundation

enum ProjectEditorDiffLineKind: String, Codable, Equatable, Sendable {
  case context
  case added
  case removed
  case replaced
}

struct ProjectEditorDiffInput: Codable, Equatable, Sendable {
  let documentID: String
  let path: String
  let revision: UInt64
  let content: String?
  let isBinary: Bool
  let renameFrom: String?
  let renameTo: String?

  init(
    documentID: String,
    path: String,
    revision: UInt64,
    content: String?,
    isBinary: Bool = false,
    renameFrom: String? = nil,
    renameTo: String? = nil
  ) {
    self.documentID = documentID
    self.path = path
    self.revision = revision
    self.content = content
    self.isBinary = isBinary
    self.renameFrom = renameFrom
    self.renameTo = renameTo
  }
}

struct ProjectEditorDiffMetadata: Codable, Equatable, Sendable {
  let oldPath: String
  let newPath: String
  let renameFrom: String?
  let renameTo: String?
  let isBinary: Bool
  let unsupportedReason: String?
}

struct ProjectEditorDiffLine: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let kind: ProjectEditorDiffLineKind
  let oldLineNumber: Int?
  let newLineNumber: Int?
  let oldText: String?
  let newText: String?
  let oldLineEnding: String?
  let newLineEnding: String?
  let hunkID: String?

  var oldSource: String? {
    guard let oldText else { return nil }
    return oldText + (oldLineEnding ?? "")
  }

  var newSource: String? {
    guard let newText else { return nil }
    return newText + (newLineEnding ?? "")
  }
}

struct ProjectEditorDiffHunk: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let rowStart: Int
  let rowCount: Int
  let oldLineStart: Int
  let oldLineCount: Int
  let newLineStart: Int
  let newLineCount: Int
}

struct ProjectEditorDiffResult: Codable, Equatable, Sendable {
  let pairID: String
  let oldDocumentID: String
  let newDocumentID: String
  let oldRevision: UInt64
  let newRevision: UInt64
  let metadata: ProjectEditorDiffMetadata
  let rows: [ProjectEditorDiffLine]
  let hunks: [ProjectEditorDiffHunk]

  var isBinary: Bool {
    metadata.isBinary
  }

  func reconstructOldSource() -> String {
    rows.compactMap(\.oldSource).joined()
  }

  func reconstructNewSource() -> String {
    rows.compactMap(\.newSource).joined()
  }
}

/// A deterministic, engine-independent line diff. It intentionally keeps line
/// terminators out of the displayed text so a diff view never needs to insert
/// a fake blank line for its layout.
enum ProjectEditorDiffModel {
  private struct LineValue: Equatable, Sendable {
    let text: String
    let terminator: String
  }

  private enum Operation: Sendable {
    case equal(old: Int, new: Int)
    case delete(old: Int)
    case insert(new: Int)
  }

  private struct PendingRow {
    let kind: ProjectEditorDiffLineKind
    let oldIndex: Int?
    let newIndex: Int?
  }

  static func calculate(
    old: ProjectEditorDiffInput,
    new: ProjectEditorDiffInput,
    contextLines: Int = 3
  ) -> ProjectEditorDiffResult {
    let pairID = "\(old.documentID)->\(new.documentID)"
    let metadata = ProjectEditorDiffMetadata(
      oldPath: old.path,
      newPath: new.path,
      renameFrom: new.renameFrom ?? old.renameFrom,
      renameTo: new.renameTo ?? old.renameTo,
      isBinary: old.isBinary || new.isBinary,
      unsupportedReason: old.isBinary || new.isBinary ? "Binary documents are not supported by the text diff model." : nil
    )

    guard !metadata.isBinary, let oldContent = old.content, let newContent = new.content else {
      return ProjectEditorDiffResult(
        pairID: pairID,
        oldDocumentID: old.documentID,
        newDocumentID: new.documentID,
        oldRevision: old.revision,
        newRevision: new.revision,
        metadata: metadata,
        rows: [],
        hunks: []
      )
    }

    let oldLines = splitLines(oldContent)
    let newLines = splitLines(newContent)
    let operations = myers(oldLines, newLines)
    var pendingRows: [PendingRow] = []
    var index = 0

    while index < operations.count {
      switch operations[index] {
      case .equal(let oldIndex, let newIndex):
        pendingRows.append(PendingRow(kind: .context, oldIndex: oldIndex, newIndex: newIndex))
        index += 1
      case .delete, .insert:
        var deleted: [Int] = []
        var inserted: [Int] = []
        while index < operations.count {
          switch operations[index] {
          case .equal:
            break
          case .delete(let oldIndex):
            deleted.append(oldIndex)
            index += 1
            continue
          case .insert(let newIndex):
            inserted.append(newIndex)
            index += 1
            continue
          }
          break
        }
        let pairedCount = min(deleted.count, inserted.count)
        for pairIndex in 0..<pairedCount {
          pendingRows.append(
            PendingRow(
              kind: .replaced,
              oldIndex: deleted[pairIndex],
              newIndex: inserted[pairIndex]
            )
          )
        }
        for oldIndex in deleted.dropFirst(pairedCount) {
          pendingRows.append(PendingRow(kind: .removed, oldIndex: oldIndex, newIndex: nil))
        }
        for newIndex in inserted.dropFirst(pairedCount) {
          pendingRows.append(PendingRow(kind: .added, oldIndex: nil, newIndex: newIndex))
        }
      }
    }

    var rows = pendingRows.enumerated().map { index, pending in
      ProjectEditorDiffLine(
        id: "\(pairID):row:\(index)",
        kind: pending.kind,
        oldLineNumber: pending.oldIndex.map { $0 + 1 },
        newLineNumber: pending.newIndex.map { $0 + 1 },
        oldText: pending.oldIndex.map { oldLines[$0].text },
        newText: pending.newIndex.map { newLines[$0].text },
        oldLineEnding: pending.oldIndex.map { oldLines[$0].terminator },
        newLineEnding: pending.newIndex.map { newLines[$0].terminator },
        hunkID: nil
      )
    }

    let hunks = makeHunks(
      rows: &rows,
      pairID: pairID,
      oldRevision: old.revision,
      newRevision: new.revision,
      contextLines: max(0, contextLines)
    )
    return ProjectEditorDiffResult(
      pairID: pairID,
      oldDocumentID: old.documentID,
      newDocumentID: new.documentID,
      oldRevision: old.revision,
      newRevision: new.revision,
      metadata: metadata,
      rows: rows,
      hunks: hunks
    )
  }

  private static func splitLines(_ source: String) -> [LineValue] {
    guard !source.isEmpty else {
      return []
    }
    var result: [LineValue] = []
    let scalars = source.unicodeScalars
    var lineStart = scalars.startIndex
    var cursor = scalars.startIndex

    while cursor < scalars.endIndex {
      let scalar = scalars[cursor]
      if scalar == "\n" || scalar == "\r" {
        let terminator: String
        let next = scalars.index(after: cursor)
        if scalar == "\r", next < scalars.endIndex, scalars[next] == "\n" {
          terminator = "\r\n"
          cursor = scalars.index(after: next)
        } else {
          terminator = String(scalar)
          cursor = next
        }
        result.append(LineValue(text: String(scalars[lineStart..<cursor].dropLast(terminator.unicodeScalars.count)), terminator: terminator))
        lineStart = cursor
      } else {
        cursor = scalars.index(after: cursor)
      }
    }
    if lineStart < scalars.endIndex {
      result.append(LineValue(text: String(scalars[lineStart...]), terminator: ""))
    }
    return result
  }

  private static func myers(_ old: [LineValue], _ new: [LineValue]) -> [Operation] {
    let maxDistance = old.count + new.count
    guard maxDistance > 0 else { return [] }
    let offset = maxDistance
    var vector = [Int](repeating: 0, count: maxDistance * 2 + 1)
    var trace: [[Int]] = []

    for distance in 0...maxDistance {
      var next = vector
      var diagonal = -distance
      while diagonal <= distance {
        let vectorIndex = offset + diagonal
        let x: Int
        if diagonal == -distance
          || (diagonal != distance && vector[offset + diagonal - 1] < vector[offset + diagonal + 1])
        {
          x = vector[offset + diagonal + 1]
        } else {
          x = vector[offset + diagonal - 1] + 1
        }
        var advancedX = x
        var advancedY = advancedX - diagonal
        while advancedX < old.count,
          advancedY < new.count,
          old[advancedX] == new[advancedY]
        {
          advancedX += 1
          advancedY += 1
        }
        next[vectorIndex] = advancedX
        if advancedX >= old.count, advancedY >= new.count {
          trace.append(next)
          return backtrack(
            trace: trace,
            distance: distance,
            oldCount: old.count,
            newCount: new.count,
            offset: offset
          )
        }
        diagonal += 2
      }
      trace.append(next)
      vector = next
    }
    return []
  }

  private static func backtrack(
    trace: [[Int]],
    distance: Int,
    oldCount: Int,
    newCount: Int,
    offset: Int
  ) -> [Operation] {
    var oldIndex = oldCount
    var newIndex = newCount
    var reversed: [Operation] = []

    if distance > 0 {
      for currentDistance in stride(from: distance, through: 1, by: -1) {
        let previous = trace[currentDistance - 1]
        let diagonal = oldIndex - newIndex
        let previousDiagonal: Int
        if diagonal == -currentDistance
          || (diagonal != currentDistance && previous[offset + diagonal - 1] < previous[offset + diagonal + 1])
        {
          previousDiagonal = diagonal + 1
        } else {
          previousDiagonal = diagonal - 1
        }
        let previousOldIndex = previous[offset + previousDiagonal]
        let previousNewIndex = previousOldIndex - previousDiagonal
        while oldIndex > previousOldIndex, newIndex > previousNewIndex {
          reversed.append(.equal(old: oldIndex - 1, new: newIndex - 1))
          oldIndex -= 1
          newIndex -= 1
        }
        if oldIndex == previousOldIndex {
          reversed.append(.insert(new: newIndex - 1))
          newIndex -= 1
        } else {
          reversed.append(.delete(old: oldIndex - 1))
          oldIndex -= 1
        }
      }
    }
    while oldIndex > 0, newIndex > 0 {
      reversed.append(.equal(old: oldIndex - 1, new: newIndex - 1))
      oldIndex -= 1
      newIndex -= 1
    }
    while oldIndex > 0 {
      reversed.append(.delete(old: oldIndex - 1))
      oldIndex -= 1
    }
    while newIndex > 0 {
      reversed.append(.insert(new: newIndex - 1))
      newIndex -= 1
    }
    return reversed.reversed()
  }

  private static func makeHunks(
    rows: inout [ProjectEditorDiffLine],
    pairID: String,
    oldRevision: UInt64,
    newRevision: UInt64,
    contextLines: Int
  ) -> [ProjectEditorDiffHunk] {
    let changedRows = rows.indices.filter { rows[$0].kind != .context }
    guard let firstChanged = changedRows.first else {
      return []
    }

    var spans: [(start: Int, end: Int)] = []
    var start = max(0, firstChanged - contextLines)
    var end = min(rows.count - 1, firstChanged + contextLines)
    for changedRow in changedRows.dropFirst() {
      let candidateStart = max(0, changedRow - contextLines)
      let candidateEnd = min(rows.count - 1, changedRow + contextLines)
      if candidateStart <= end + 1 {
        end = max(end, candidateEnd)
      } else {
        spans.append((start, end))
        start = candidateStart
        end = candidateEnd
      }
    }
    spans.append((start, end))

    return spans.enumerated().map { hunkIndex, span in
      let id = "\(pairID):old:\(oldRevision):new:\(newRevision):hunk:\(hunkIndex):\(span.start)-\(span.end)"
      let range = span.start...span.end
      let oldNumbers = range.compactMap { rows[$0].oldLineNumber }
      let newNumbers = range.compactMap { rows[$0].newLineNumber }
      let hunk = ProjectEditorDiffHunk(
        id: id,
        rowStart: span.start,
        rowCount: span.end - span.start + 1,
        oldLineStart: oldNumbers.min() ?? 0,
        oldLineCount: oldNumbers.count,
        newLineStart: newNumbers.min() ?? 0,
        newLineCount: newNumbers.count
      )
      for rowIndex in range {
        let row = rows[rowIndex]
        rows[rowIndex] = ProjectEditorDiffLine(
          id: row.id,
          kind: row.kind,
          oldLineNumber: row.oldLineNumber,
          newLineNumber: row.newLineNumber,
          oldText: row.oldText,
          newText: row.newText,
          oldLineEnding: row.oldLineEnding,
          newLineEnding: row.newLineEnding,
          hunkID: id
        )
      }
      return hunk
    }
  }
}

/// Serializes diff computation off the main actor and discards stale results.
actor ProjectEditorDiffCoordinator {
  private var generation = 0
  private var activeTask: Task<ProjectEditorDiffResult?, Never>?

  func cancel() {
    generation += 1
    activeTask?.cancel()
    activeTask = nil
  }

  func calculate(
    old: ProjectEditorDiffInput,
    new: ProjectEditorDiffInput,
    contextLines: Int = 3
  ) async -> ProjectEditorDiffResult? {
    cancel()
    let requestedGeneration = generation
    let task: Task<ProjectEditorDiffResult?, Never> = Task.detached(priority: .userInitiated) {
      guard !Task.isCancelled else { return nil }
      let result = ProjectEditorDiffModel.calculate(
        old: old,
        new: new,
        contextLines: contextLines
      )
      return Task.isCancelled ? nil : result
    }
    activeTask = task
    let result = await task.value
    guard requestedGeneration == generation else {
      return nil
    }
    activeTask = nil
    return result
  }
}

/// One replacement within a simultaneous multi-edit transaction. All edits in a
/// transaction are expressed in the same pre-transaction coordinate space, the
/// same way ProseMirror/CodeMirror steps are: unlike sequential single edits,
/// none of them needs to account for an earlier edit in the same batch shifting
/// offsets.
public struct TextEdit: Sendable, Hashable {
  public let range: TextUTF8Range
  public let replacement: String

  public init(range: TextUTF8Range, replacement: String) {
    self.range = range
    self.replacement = replacement
  }

  var insertedUTF8Count: Int { replacement.utf8.count }
}

public enum TextTransactionError: Error, Sendable, Equatable {
  case emptyTransaction
  case overlappingEdits
}

extension TextEdit {
  /// Sorts by position and rejects an empty batch or any overlap; bounds and
  /// grapheme-boundary validity of each range are still enforced later by
  /// `TextBuffer.replace` itself, which is the single place that owns them.
  static func sortedNonOverlapping(_ edits: [TextEdit]) throws -> [TextEdit] {
    guard !edits.isEmpty else { throw TextTransactionError.emptyTransaction }
    let sorted = edits.sorted { $0.range.lowerBound.value < $1.range.lowerBound.value }
    for index in 1..<sorted.count {
      guard sorted[index - 1].range.upperBound.value <= sorted[index].range.lowerBound.value else {
        throw TextTransactionError.overlappingEdits
      }
    }
    return sorted
  }

  /// Maps a single pre-transaction offset through `edits` (sorted, non-overlapping,
  /// in the same pre-transaction space) to its position after they are applied.
  /// An offset inside a replaced range collapses to the end of its replacement,
  /// matching the common "typing pushes the caret past what it typed" behavior.
  public static func map(_ offset: Int, through edits: [TextEdit]) -> Int {
    var delta = 0
    for edit in edits {
      let start = edit.range.lowerBound.value
      let end = edit.range.upperBound.value
      if offset < start { return offset + delta }
      if offset <= end { return start + delta + edit.insertedUTF8Count }
      delta += edit.insertedUTF8Count - (end - start)
    }
    return offset + delta
  }
}

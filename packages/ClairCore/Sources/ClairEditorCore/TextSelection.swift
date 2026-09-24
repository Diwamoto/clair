/// One cursor or range selection. `anchor` is where the selection started,
/// `head` is the end the user is actively moving; `head < anchor` is a
/// backward selection.
public struct TextSelection: Sendable, Hashable {
  public let anchor: UTF8Offset
  public let head: UTF8Offset

  public init(anchor: UTF8Offset, head: UTF8Offset) {
    self.anchor = anchor
    self.head = head
  }

  public init(cursor: UTF8Offset) {
    self.init(anchor: cursor, head: cursor)
  }

  public var isEmpty: Bool { anchor == head }
  public var range: TextUTF8Range {
    anchor.value <= head.value ? TextUTF8Range(anchor, head) : TextUTF8Range(head, anchor)
  }

  func mapped(through edits: [TextEdit]) -> TextSelection {
    TextSelection(
      anchor: UTF8Offset(TextEdit.map(anchor.value, through: edits)),
      head: UTF8Offset(TextEdit.map(head.value, through: edits))
    )
  }
}

public enum TextSelectionError: Error, Sendable, Equatable {
  case empty
}

/// Zero or more non-overlapping selections, i.e. multi-cursor / multi-range
/// selection state. Always has at least one selection.
public struct TextSelectionSet: Sendable {
  public private(set) var selections: [TextSelection]

  public init(_ selections: [TextSelection]) throws {
    guard !selections.isEmpty else { throw TextSelectionError.empty }
    self.selections = Self.normalize(selections)
  }

  public init(cursor: UTF8Offset) {
    selections = [TextSelection(cursor: cursor)]
  }

  private init(normalized: [TextSelection]) {
    selections = normalized
  }

  /// Merges selections that overlap or touch after a move/edit so multi-cursor
  /// state never holds redundant or crossing entries. Direction (anchor vs.
  /// head) is not preserved across a merge; a merged run becomes forward.
  private static func normalize(_ selections: [TextSelection]) -> [TextSelection] {
    let sorted = selections.sorted { $0.range.lowerBound.value < $1.range.lowerBound.value }
    var result: [TextSelection] = []
    for selection in sorted {
      if let last = result.last, selection.range.lowerBound.value <= last.range.upperBound.value {
        let upper = max(last.range.upperBound.value, selection.range.upperBound.value)
        result[result.count - 1] = TextSelection(
          anchor: last.range.lowerBound, head: UTF8Offset(upper))
      } else {
        result.append(selection)
      }
    }
    return result
  }

  func mapped(through edits: [TextEdit]) -> TextSelectionSet {
    TextSelectionSet(normalized: Self.normalize(selections.map { $0.mapped(through: edits) }))
  }

  /// One edit per cursor, replacing each selection's range with `replacement`
  /// (e.g. typing the same character at every cursor, or deleting every
  /// selection). Ranges are already non-overlapping by construction.
  public func edits(replacingEachWith replacement: String) -> [TextEdit] {
    selections.map { TextEdit(range: $0.range, replacement: replacement) }
  }

  /// A block/column selection spanning `fromLine...toLine`, clamped per line to
  /// that line's actual content length. Lines shorter than the column range
  /// collapse to a cursor at their end rather than a virtual/padded column.
  /// ponytail: no virtual-space padding past line end; add if product needs
  /// the visual (Sublime/VS Code style) block-selection ragged-edge behavior.
  public static func rectangular<Column: TextCoordinateUnit>(
    fromLine: TextLineIndex, toLine: TextLineIndex,
    fromColumn: TextOffset<Column>, toColumn: TextOffset<Column>,
    in snapshot: TextSnapshot
  ) throws -> TextSelectionSet {
    let (lowLine, highLine) =
      fromLine.value <= toLine.value ? (fromLine, toLine) : (toLine, fromLine)
    let (lowColumn, highColumn) =
      fromColumn.value <= toColumn.value ? (fromColumn, toColumn) : (toColumn, fromColumn)
    var selections: [TextSelection] = []
    for index in lowLine.value...highLine.value {
      let lineIndex = TextLineIndex(index)
      let line = try snapshot.line(at: lineIndex)
      let start = try snapshot.convert(line.contentRange.lowerBound, to: Column.self)
      let end = try snapshot.convert(line.contentRange.upperBound, to: Column.self)
      let lineLength = end.value - start.value
      let anchorColumn = min(lowColumn.value, lineLength)
      let headColumn = min(highColumn.value, lineLength)
      let anchor = try snapshot.offset(
        at: TextLinePosition(line: lineIndex, column: TextOffset<Column>(anchorColumn)))
      let head = try snapshot.offset(
        at: TextLinePosition(line: lineIndex, column: TextOffset<Column>(headColumn)))
      selections.append(TextSelection(anchor: anchor, head: head))
    }
    return try TextSelectionSet(selections)
  }
}

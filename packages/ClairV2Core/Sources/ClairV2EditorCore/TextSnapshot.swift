/// An immutable revision. Copying a snapshot shares the entire persistent tree;
/// it neither copies nor materializes document text. Safe to read on any actor.
public struct TextSnapshot: Sendable {
  public let revision: TextRevision
  public let firstLineID: TextLineID
  let root: TextNode?

  var metrics: TextMetrics { root?.metrics ?? TextMetrics() }
  public var utf8Count: Int { metrics.utf8 }
  public var utf16Count: Int { metrics.utf16 }
  public var scalarCount: Int { metrics.scalars }
  public var graphemeCount: Int { metrics.graphemes }
  public var lineCount: Int { metrics.breaks + 1 }
  public var fullRange: TextUTF8Range { TextUTF8Range(UTF8Offset(0), UTF8Offset(utf8Count)) }

  public func convert<Source: TextCoordinateUnit, Destination: TextCoordinateUnit>(
    _ offset: TextOffset<Source>, to: Destination.Type,
    rounding: TextBoundaryRounding = .strict
  ) throws -> TextOffset<Destination> {
    let prefix = try boundary(at: offset.value, in: Source.space, rounding: rounding)
    return TextOffset<Destination>(prefix[Destination.space])
  }

  /// Expand a possibly interior byte range outwards to complete graphemes.
  public func expandingToGraphemes(_ range: TextUTF8Range) throws -> TextUTF8Range {
    guard range.lowerBound <= range.upperBound else { throw TextStorageError.reversedRange }
    return try TextUTF8Range(
      convert(range.lowerBound, to: UTF8Unit.self, rounding: .down),
      convert(range.upperBound, to: UTF8Unit.self, rounding: .up)
    )
  }

  public func line(at index: TextLineIndex) throws -> TextLine {
    guard index.value >= 0 && index.value < lineCount else { throw TextStorageError.outOfBounds }
    let preceding = index.value == 0 ? nil : root!.lineBreak(at: index.value - 1)
    let following = index.value < metrics.breaks ? root!.lineBreak(at: index.value) : nil
    let start = preceding.map { $0.offset + $0.length } ?? 0
    let end = following?.offset ?? utf8Count
    return TextLine(
      index: index, id: preceding?.id ?? firstLineID,
      contentRange: TextUTF8Range(UTF8Offset(start), UTF8Offset(end)),
      terminatorRange: TextUTF8Range(UTF8Offset(end), UTF8Offset(end + (following?.length ?? 0))),
      ending: following?.ending
    )
  }

  public func position<Source: TextCoordinateUnit, Column: TextCoordinateUnit>(
    at offset: TextOffset<Source>, columnUnit: Column.Type,
    rounding: TextBoundaryRounding = .strict
  ) throws -> TextLinePosition<Column> {
    let prefix = try boundary(at: offset.value, in: Source.space, rounding: rounding)
    let line = try line(at: TextLineIndex(prefix.breaks))
    let start = try boundary(at: line.contentRange.lowerBound.value, in: .utf8, rounding: .strict)
    return TextLinePosition(
      line: line.index, column: TextOffset<Column>(prefix[Column.space] - start[Column.space])
    )
  }

  public func offset<Column: TextCoordinateUnit>(
    at position: TextLinePosition<Column>, rounding: TextBoundaryRounding = .strict
  ) throws -> UTF8Offset {
    let line = try line(at: position.line)
    let start = try boundary(at: line.contentRange.lowerBound.value, in: .utf8, rounding: .strict)
    let end = try boundary(at: line.contentRange.upperBound.value, in: .utf8, rounding: .strict)
    guard position.column.value >= 0,
      position.column.value <= end[Column.space] - start[Column.space]
    else { throw TextStorageError.outOfBounds }
    return try convert(
      TextOffset<Column>(start[Column.space] + position.column.value), to: UTF8Unit.self,
      rounding: rounding
    )
  }

  /// Explicit materialization boundary for save/export/test consumers.
  public func string() -> String {
    var result = String()
    result.reserveCapacity(utf8Count)
    forEachTextChunk { result.append(contentsOf: $0) }
    return result
  }

  public func text(in range: TextUTF8Range) throws -> String {
    let range = try validated(range)
    var result = String()
    result.reserveCapacity(range.count)
    root?.visit(range) { result.append(contentsOf: $0) }
    return result
  }

  /// A streaming export alternative; each chunk ends on a grapheme boundary.
  public func forEachTextChunk(_ body: (Substring) -> Void) {
    root?.visit(0..<utf8Count, body)
  }

  func boundary(
    at offset: Int, in space: TextCoordinateSpace, rounding: TextBoundaryRounding
  ) throws -> TextMetrics {
    guard offset >= 0 && offset <= metrics[space] else { throw TextStorageError.outOfBounds }
    return try root?.boundary(at: offset, in: space, rounding: rounding) ?? TextMetrics()
  }

  func validated(_ range: TextUTF8Range) throws -> Range<Int> {
    guard range.lowerBound <= range.upperBound else { throw TextStorageError.reversedRange }
    _ = try convert(range.lowerBound, to: UTF8Unit.self)
    _ = try convert(range.upperBound, to: UTF8Unit.self)
    return range.lowerBound.value..<range.upperBound.value
  }

  func matches(_ range: Range<Int>, _ replacement: String) -> Bool {
    guard range.count == replacement.utf8.count else { return false }
    var iterator = replacement.utf8.makeIterator()
    var equal = true
    root?.visit(range) { chunk in
      guard equal else { return }
      for byte in chunk.utf8 {
        if iterator.next() != byte {
          equal = false
          return
        }
      }
    }
    return equal
  }
}

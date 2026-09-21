import ClairEditorCore
import LanguageServerProtocol

/// Converts between `ClairEditorCore`'s UTF-8 byte offsets and LSP's wire
/// `Position`/`LSPRange`, whose `character` is a UTF-16 code unit offset (LSP
/// 3.17's default `PositionEncodingKind.utf16`). `ClairEditorCore` already
/// tracks UTF-16 as one of its four coordinate spaces, so this is a thin
/// adapter rather than its own conversion logic.
public enum LSPCoordinates {
  public static func position(_ offset: UTF8Offset, in snapshot: TextSnapshot) throws -> Position {
    let position = try snapshot.position(at: offset, columnUnit: UTF16Unit.self)
    return Position(line: position.line.value, character: position.column.value)
  }

  public static func range(_ range: TextUTF8Range, in snapshot: TextSnapshot) throws -> LSPRange {
    try LSPRange(
      start: position(range.lowerBound, in: snapshot),
      end: position(range.upperBound, in: snapshot)
    )
  }

  public static func offset(_ position: Position, in snapshot: TextSnapshot) throws -> UTF8Offset {
    guard position.line >= 0, position.character >= 0 else { throw TextStorageError.outOfBounds }
    let lspPosition = TextLinePosition<UTF16Unit>(
      line: TextLineIndex(position.line), column: UTF16Offset(position.character)
    )
    return try snapshot.offset(at: lspPosition)
  }

  public static func utf8Range(_ range: LSPRange, in snapshot: TextSnapshot) throws -> TextUTF8Range
  {
    try TextUTF8Range(offset(range.start, in: snapshot), offset(range.end, in: snapshot))
  }
}

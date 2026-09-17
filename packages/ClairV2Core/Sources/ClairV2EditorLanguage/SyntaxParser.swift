import ClairV2EditorCore
import Foundation
import SwiftTreeSitter
import TreeSitter

public enum SyntaxParserError: Error, Sendable, Equatable {
  case languageIncompatible
  case parseFailed
}

/// Tree-sitter incremental parse over a `TextSnapshot`. `update` never
/// restrings the whole document: it feeds tree-sitter the edit deltas via
/// `Tree.edit`, then reparses by reading bytes directly out of the rope
/// (`TextSnapshot.text(in:)`), so unaffected subtrees are reused instead of
/// rescanned. Not Sendable: like `TextBuffer`/`EditorTransactionManager`, keep
/// one instance on its owning actor.
public final class SyntaxParser {
  private let parser: Parser
  private var tree: MutableTree?

  /// The snapshot this parser's tree currently reflects, or `nil` before the
  /// first parse. `update` compares its `oldSnapshot` argument against this to
  /// decide whether an incremental edit is even applicable.
  public private(set) var revision: TextRevision?

  /// Total UTF-8 bytes tree-sitter actually asked for during the most recent
  /// `reset`/`update` call. tree-sitter's incremental algorithm skips reading
  /// (and reparsing) any byte range it can prove is unaffected by the edit
  /// deltas passed to `Tree.edit`, so this is the concrete, deterministic
  /// evidence — the same role `TextBuffer.lastEditWork` plays for storage
  /// edits — that `update` reparses only around the edit instead of restarting
  /// from scratch: a small edit in a large document leaves this far below the
  /// document's total byte count, unlike `reset`, which always reads all of it.
  public private(set) var lastReadByteCount = 0

  public init(language: Language) throws {
    parser = Parser()
    do {
      try parser.setLanguage(language)
    } catch {
      throw SyntaxParserError.languageIncompatible
    }
  }

  /// An immutable copy of the current parse tree, if any parse has completed.
  public var currentTree: Tree? { tree?.copy() }

  /// Parses `snapshot` from scratch, discarding any previous tree. Used for
  /// the first parse of a document, and as `update`'s fallback when its
  /// `oldSnapshot` does not match this parser's tracked revision (there is no
  /// delta to apply an edit on top of).
  @discardableResult
  public func reset(to snapshot: TextSnapshot) throws -> Tree {
    var bytesRead = 0
    guard
      let parsed = parser.parse(
        tree: MutableTree?.none, encoding: TSInputEncodingUTF8,
        readBlock: Self.readBlock(for: snapshot) { bytesRead += $0 }
      )
    else {
      throw SyntaxParserError.parseFailed
    }
    tree = parsed
    revision = snapshot.revision
    lastReadByteCount = bytesRead
    guard let result = parsed.copy() else { throw SyntaxParserError.parseFailed }
    return result
  }

  /// Applies `edits` (in the same pre-transaction coordinate space
  /// `EditorTransactionManager.apply`/`applyExternal` take, i.e. against
  /// `oldSnapshot`) to the current tree and reparses against `newSnapshot`.
  @discardableResult
  public func update(
    edits: [TextEdit], oldSnapshot: TextSnapshot, newSnapshot: TextSnapshot
  ) throws -> Tree {
    guard let current = tree, revision == oldSnapshot.revision else {
      return try reset(to: newSnapshot)
    }
    // Descending order: each `InputEdit` below is self-contained (computed
    // only from `oldSnapshot` and that one edit), so applying the
    // highest-offset edit first means every edit still below the one just
    // applied is guaranteed untouched by it when its own turn comes — the
    // same reason `EditorTransactionManager.commit` replays edits high-to-low.
    for edit in edits.sorted(by: { $0.range.lowerBound.value > $1.range.lowerBound.value }) {
      current.edit(try Self.inputEdit(for: edit, in: oldSnapshot))
    }
    var bytesRead = 0
    guard
      let reparsed = parser.parse(
        tree: current, encoding: TSInputEncodingUTF8,
        readBlock: Self.readBlock(for: newSnapshot) { bytesRead += $0 }
      )
    else {
      throw SyntaxParserError.parseFailed
    }
    tree = reparsed
    revision = newSnapshot.revision
    lastReadByteCount = bytesRead
    guard let result = reparsed.copy() else { throw SyntaxParserError.parseFailed }
    return result
  }

  static func inputEdit(for edit: TextEdit, in oldSnapshot: TextSnapshot) throws -> InputEdit {
    let startByte = edit.range.lowerBound.value
    let oldEndByte = edit.range.upperBound.value
    let newEndByte = startByte + edit.replacement.utf8.count
    let startPoint = try point(UTF8Offset(startByte), in: oldSnapshot)
    let oldEndPoint = try point(UTF8Offset(oldEndByte), in: oldSnapshot)
    // The new end point cannot be read from either snapshot: `oldSnapshot`
    // does not contain the replacement text, and `newSnapshot`'s absolute
    // offset for it depends on sibling edits in the same batch. Deriving it
    // by walking the replacement string forward from `startPoint` keeps this
    // edit's `InputEdit` self-contained regardless of batch order.
    let newEndPoint = advance(startPoint, by: edit.replacement)
    return InputEdit(
      startByte: startByte, oldEndByte: oldEndByte, newEndByte: newEndByte,
      startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: newEndPoint
    )
  }

  private static func point(_ offset: UTF8Offset, in snapshot: TextSnapshot) throws -> Point {
    // tree-sitter, fed via `TSInputEncodingUTF8`, expects `Point.column` in
    // bytes since line start, exactly `UTF8Unit`'s column space.
    let position = try snapshot.position(at: offset, columnUnit: UTF8Unit.self)
    return Point(row: position.line.value, column: position.column.value)
  }

  private static func advance(_ start: Point, by text: String) -> Point {
    var row = start.row
    var column = start.column
    for byte in text.utf8 {
      if byte == UInt8(ascii: "\n") {
        row += 1
        column = 0
      } else {
        column += 1
      }
    }
    return Point(row: row, column: column)
  }

  /// Reads `snapshot` in fixed-size chunks, each expanded to a grapheme
  /// boundary so it never asks the rope for a mid-scalar/mid-cluster split
  /// (a byte offset tree-sitter can seek back to is always one this same
  /// function returned before, so every offset it ever presents is already
  /// grapheme-aligned by construction).
  private static func readBlock(
    for snapshot: TextSnapshot, onRead: @escaping (Int) -> Void
  ) -> Parser.ReadBlock {
    let total = snapshot.utf8Count
    let chunkSize = 4096
    return { start, _ in
      guard start >= 0, start < total else { return nil }
      let tentativeEnd = min(start + chunkSize, total)
      guard
        let range = try? snapshot.expandingToGraphemes(
          TextUTF8Range(UTF8Offset(start), UTF8Offset(tentativeEnd))),
        let text = try? snapshot.text(in: range)
      else { return nil }
      let data = Data(text.utf8)
      onRead(data.count)
      return data
    }
  }
}

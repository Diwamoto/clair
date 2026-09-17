import ClairV2EditorLanguageFixtures
import SwiftTreeSitter
import XCTest

@testable import ClairV2EditorCore
@testable import ClairV2EditorLanguage

private func jsonLanguage() -> Language {
  Language(tree_sitter_json())
}

private func text(of node: Node, in snapshot: TextSnapshot) throws -> String {
  try snapshot.text(
    in: TextUTF8Range(
      UTF8Offset(Int(node.byteRange.lowerBound)), UTF8Offset(Int(node.byteRange.upperBound))))
}

final class EditorLanguageSyntaxTests: XCTestCase {
  func testFreshParseProducesJSONDocument() throws {
    let buffer = try TextBuffer(#"{"a": 1}"#)
    let parser = try SyntaxParser(language: jsonLanguage())
    let tree = try parser.reset(to: buffer.snapshot)

    XCTAssertFalse(tree.rootNode?.hasError ?? true)
    XCTAssertEqual(tree.rootNode?.nodeType, "document")
    XCTAssertEqual(Int(tree.rootNode!.byteRange.upperBound), buffer.snapshot.utf8Count)
  }

  func testIncrementalUpdateMatchesFreshReparse() throws {
    let buffer = try TextBuffer(#"{"greeting": "hello", "count": 1}"#)
    let parser = try SyntaxParser(language: jsonLanguage())
    try parser.reset(to: buffer.snapshot)

    // Change just the number, deep inside the document.
    let old = buffer.snapshot
    let range = try old.expandingToGraphemes(TextUTF8Range(UTF8Offset(31), UTF8Offset(32)))
    let edit = TextEdit(range: range, replacement: "42")
    try buffer.replace(edit.range, with: edit.replacement, basedOn: old.revision)
    let new = buffer.snapshot

    let incremental = try parser.update(edits: [edit], oldSnapshot: old, newSnapshot: new)

    let freshParser = try SyntaxParser(language: jsonLanguage())
    let fresh = try freshParser.reset(to: new)

    XCTAssertFalse(incremental.rootNode?.hasError ?? true)
    XCTAssertEqual(incremental.rootNode?.sExpressionString, fresh.rootNode?.sExpressionString)
    XCTAssertEqual(new.string(), #"{"greeting": "hello", "count": 42}"#)
  }

  func testIncrementalUpdateReadsFarFewerBytesThanFullReparse() throws {
    // A document large enough that an edit touching only the last pair should
    // leave the other ~199 unread by an incremental reparse.
    let pairs = (0..<200).map { "\"k\($0)\": \($0)" }.joined(separator: ", ")
    let source = "{\(pairs)}"
    let buffer = try TextBuffer(source)
    let parser = try SyntaxParser(language: jsonLanguage())
    try parser.reset(to: buffer.snapshot)
    XCTAssertGreaterThan(parser.lastReadByteCount, source.utf8.count - 100)

    let old = buffer.snapshot
    let insertAt = old.utf8Count - 1
    let range = TextUTF8Range(UTF8Offset(insertAt), UTF8Offset(insertAt))
    let edit = TextEdit(range: range, replacement: #", "extra": 1"#)
    try buffer.replace(edit.range, with: edit.replacement, basedOn: old.revision)
    let new = buffer.snapshot

    let after = try parser.update(edits: [edit], oldSnapshot: old, newSnapshot: new)
    XCTAssertFalse(after.rootNode?.hasError ?? true)

    // The actual, deterministic proof of "edit delta だけで parse を更新する":
    // tree-sitter only asked for bytes near the edit, nowhere close to
    // rescanning the ~2KB document `reset` above just read in full.
    XCTAssertLessThan(parser.lastReadByteCount, source.utf8.count / 4)
  }

  func testMultiEditBatchMatchesFreshReparse() throws {
    // Two simultaneous, non-overlapping edits in one batch (same shape as an
    // `EditorTransactionManager.apply` multi-cursor transaction), expressed in
    // the same pre-transaction coordinate space.
    let buffer = try TextBuffer(#"{"a": 1, "b": 2}"#)
    let parser = try SyntaxParser(language: jsonLanguage())
    try parser.reset(to: buffer.snapshot)

    let old = buffer.snapshot
    let editA = TextEdit(range: TextUTF8Range(UTF8Offset(6), UTF8Offset(7)), replacement: "11")
    let editB = TextEdit(range: TextUTF8Range(UTF8Offset(14), UTF8Offset(15)), replacement: "22")
    for edit in [editA, editB].sorted(by: { $0.range.lowerBound.value > $1.range.lowerBound.value })
    {
      try buffer.replace(edit.range, with: edit.replacement, basedOn: buffer.snapshot.revision)
    }
    let new = buffer.snapshot
    XCTAssertEqual(new.string(), #"{"a": 11, "b": 22}"#)

    let incremental = try parser.update(edits: [editA, editB], oldSnapshot: old, newSnapshot: new)
    let fresh = try SyntaxParser(language: jsonLanguage()).reset(to: new)

    XCTAssertFalse(incremental.rootNode?.hasError ?? true)
    XCTAssertEqual(incremental.rootNode?.sExpressionString, fresh.rootNode?.sExpressionString)
  }

  func testEditAcrossMultiByteTextStaysGraphemeSafe() throws {
    // A Japanese string value spans several 3-byte UTF-8 scalars; editing
    // right after it (an ASCII-only edit) must not corrupt the read chunking
    // that has to stay grapheme-aligned around that span.
    let buffer = try TextBuffer(#"{"name": "こんにちは世界", "n": 1}"#)
    let parser = try SyntaxParser(language: jsonLanguage())
    try parser.reset(to: buffer.snapshot)

    let old = buffer.snapshot
    let numberValueStart = old.utf8Count - 2
    let range = TextUTF8Range(UTF8Offset(numberValueStart), UTF8Offset(numberValueStart + 1))
    let edit = TextEdit(range: range, replacement: "9")
    try buffer.replace(edit.range, with: edit.replacement, basedOn: old.revision)
    let new = buffer.snapshot

    let incremental = try parser.update(edits: [edit], oldSnapshot: old, newSnapshot: new)
    let fresh = try SyntaxParser(language: jsonLanguage()).reset(to: new)

    XCTAssertFalse(incremental.rootNode?.hasError ?? true)
    XCTAssertEqual(incremental.rootNode?.sExpressionString, fresh.rootNode?.sExpressionString)

    let object = try XCTUnwrap(incremental.rootNode?.namedChild(at: 0))
    let nameValue = try XCTUnwrap(object.namedChild(at: 0)?.namedChild(at: 1))
    XCTAssertEqual(try text(of: nameValue, in: new), "\"こんにちは世界\"")
  }

  func testUpdateFallsBackToFullParseOnRevisionMismatch() throws {
    let buffer = try TextBuffer(#"{"a": 1}"#)
    let parser = try SyntaxParser(language: jsonLanguage())
    let stale = buffer.snapshot
    try parser.reset(to: stale)

    try buffer.replace(
      TextUTF8Range(UTF8Offset(6), UTF8Offset(7)), with: "2", basedOn: buffer.snapshot.revision)
    try buffer.replace(
      TextUTF8Range(UTF8Offset(6), UTF8Offset(7)), with: "3", basedOn: buffer.snapshot.revision)
    let new = buffer.snapshot

    // `stale` is two revisions behind `new`; the edit below is only valid
    // against the most recent one, so this exercises the no-matching-tree path.
    let edit = TextEdit(range: TextUTF8Range(UTF8Offset(6), UTF8Offset(7)), replacement: "3")
    let tree = try parser.update(edits: [edit], oldSnapshot: stale, newSnapshot: new)

    XCTAssertEqual(
      tree.rootNode?.sExpressionString,
      try SyntaxParser(language: jsonLanguage()).reset(to: new).rootNode?.sExpressionString)
    XCTAssertEqual(parser.revision, new.revision)
  }
}

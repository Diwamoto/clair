import Foundation
import LanguageServerProtocol
import XCTest

@testable import ClairEditorCore
@testable import ClairEditorLanguage

/// Pure parts of the language features: snippet expansion, edit conversion, workspace-edit decoding.
final class LanguageServerFeaturesTests: XCTestCase {
  func testSnippetExpandsStopsPlaceholdersChoicesAndEscapes() {
    var e = LanguageServerSnippet.expand("fmt.Println(${1:a}, $2)$0")
    XCTAssertEqual(e.text, "fmt.Println(a, )")
    XCTAssertEqual(e.selection, 12..<13)  // "a" selected
    e = LanguageServerSnippet.expand("for ${1:i} := range ${2:xs} {\n\t$0\n}")
    XCTAssertEqual(e.text, "for i := range xs {\n\t\n}")
    XCTAssertEqual(e.selection, 4..<5)
    e = LanguageServerSnippet.expand("if err != nil {\n\treturn $0\n}")
    XCTAssertEqual(e.selection, 24..<24)  // only $0: the caret
    XCTAssertEqual(LanguageServerSnippet.expand("${1|public,private|} x").text, "public x")
    XCTAssertEqual(LanguageServerSnippet.expand(#"cost: \$5 ${1:{\}}"#).text, "cost: $5 {}")
    XCTAssertEqual(LanguageServerSnippet.expand("${1:outer ${2:inner}}").text, "outer inner")
    XCTAssertEqual(LanguageServerSnippet.expand("$TM_FILENAME-${VAR:dflt}").text, "-dflt")
    let plain = LanguageServerSnippet.expand("abc")
    XCTAssertEqual(plain.selection, 3..<3)  // no stops: caret after the text
    XCTAssertEqual(LanguageServerSnippet.expand("é$1").selection, 2..<2)  // UTF-8 offsets
  }

  private func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ text: String) -> LanguageServerTextEdit {
    LanguageServerTextEdit(startLine: l1, startCharacter: c1, endLine: l2, endCharacter: c2, newText: text)
  }

  func testEditsBecomeOneSortedTransactionWithTouchingInsertsMerged() throws {
    let snap = try TextBuffer("let a = 1\nlet b = a\n").snapshot
    // Renames from the server arrive in any order; two inserts at the same point apply in array order.
    let edits = try XCTUnwrap(
      LanguageServerTextEdit.editorEdits(
        [edit(1, 8, 1, 9, "x"), edit(0, 4, 0, 5, "x"), edit(1, 0, 1, 0, "// "), edit(1, 0, 1, 0, "!")], in: snap))
    XCTAssertEqual(edits.map(\.range.lowerBound.value), [4, 10, 18])
    XCTAssertEqual(edits[1].replacement, "// !")
    XCTAssertNil(LanguageServerTextEdit.editorEdits([edit(5, 0, 5, 1, "x")], in: snap))  // outside the document
    XCTAssertNil(LanguageServerTextEdit.editorEdits([edit(0, 0, 0, 5, "x"), edit(0, 2, 0, 3, "y")], in: snap))  // overlapping
    XCTAssertEqual(
      LanguageServerTextEdit.apply([edit(1, 8, 1, 9, "x"), edit(0, 4, 0, 5, "x")], to: "let a = 1\nlet b = a\n"),
      "let x = 1\nlet b = x\n")
    XCTAssertEqual(LanguageServerTextEdit.apply([edit(0, 0, 0, 0, "é")], to: "日本"), "é日本")
    XCTAssertEqual(LanguageServerTextEdit.apply([edit(0, 1, 0, 2, "x")], to: "日本"), "日x")  // UTF-16 columns
  }

  func testWorkspaceEditCollectsChangesAndDocumentChangesAndFlagsFileOperations() {
    let range = LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 1))
    let a = WorkspaceEdit(
      changes: ["file:///p/a.go": [LanguageServerProtocol.TextEdit(range: range, newText: "x")]],
      documentChanges: [
        .textDocumentEdit(
          TextDocumentEdit(
            textDocument: VersionedTextDocumentIdentifier(uri: "file:///p/b%20c.go", version: 3),
            edits: [LanguageServerProtocol.TextEdit(range: range, newText: "y")]))
      ])
    let converted = LanguageServerWorkspaceEdit(a)
    XCTAssertEqual(converted.files.keys.sorted(), ["/p/a.go", "/p/b c.go"])
    XCTAssertEqual(converted.files["/p/b c.go"]?.first?.newText, "y")
    XCTAssertFalse(converted.unsupported)
    XCTAssertFalse(converted.isEmpty)
    let ops = LanguageServerWorkspaceEdit(
      WorkspaceEdit(changes: nil, documentChanges: [.createFile(CreateFile(kind: "create", uri: "file:///p/new.go", options: nil))]))
    XCTAssertTrue(ops.unsupported)
    XCTAssertTrue(ops.isEmpty)
  }
}

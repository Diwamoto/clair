import XCTest

@testable import ClairEditorCore
@testable import ClairEditorLanguage
@testable import ClairEditorView

/// Bracket pair colorization: depth cycles across bracket kinds, strings/comments are skipped,
/// and a bracket with no partner is `.unmatchedBracket`.
final class BracketPairColorizationTests: XCTestCase {
  private func brackets(_ source: String, _ id: EditorLanguageID) throws -> [(String, EditorTokenKind)] {
    let highlighter = try SyntaxHighlighter(languageID: id)
    let snapshot = try TextBuffer(source).snapshot
    _ = try highlighter.reset(to: snapshot)
    let bytes = Array(source.utf8)
    return highlighter.bracketSpans.map {
      (String(decoding: bytes[$0.range.lowerBound.value..<$0.range.upperBound.value], as: UTF8.self), $0.kind)
    }
  }

  func testDepthCyclesAndStringsAreSkipped() throws {
    let got = try brackets("f(a[{b: \"(\"}]); // )\n", .javascript)
    XCTAssertEqual(got.map(\.0), ["(", "[", "{", "}", "]", ")"])
    XCTAssertEqual(
      got.map(\.1),
      [.bracket(depth: 0), .bracket(depth: 1), .bracket(depth: 2), .bracket(depth: 2), .bracket(depth: 1),
       .bracket(depth: 0)])
  }

  func testTemplateSubstitutionPairsWithItsBrace() throws {
    let got = try brackets("g(`${x}`);\n", .javascript)
    XCTAssertEqual(got.map(\.0), ["(", "${", "}", ")"])
    XCTAssertFalse(got.contains { $0.1 == .unmatchedBracket })
  }

  func testUnpairedClosingBracketIsUnmatched() throws {
    let got = try brackets("[1, 2]]\n", .json)
    XCTAssertEqual(got.last?.0, "]")
    XCTAssertEqual(got.last?.1, .unmatchedBracket)
    XCTAssertEqual(got.first?.1, .bracket(depth: 0))
  }
}

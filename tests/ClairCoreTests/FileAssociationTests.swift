import XCTest

@testable import ClairEditorCore
@testable import ClairEditorLanguage
import ClairEditorView
@testable import ClairWorkspace

final class FileAssociationTests: XCTestCase {
  func testAssociationsOverrideDetection() {
    defer { EditorLanguageID.associations = [:] }
    XCTAssertNil(EditorLanguageID.detect(path: "main.tpl"))
    EditorLanguageID.associations = WorkbenchState().fileAssociations
    XCTAssertEqual(EditorLanguageID.detect(path: "infra/main.tpl"), .terraform)
    EditorLanguageID.associations = ["md": "nope"]  // unknown language falls back to the built-in table
    XCTAssertEqual(EditorLanguageID.detect(path: "a.md"), .markdown)
  }

  func testParseAndFormatRoundTrip() {
    let map = WorkbenchState.parseAssociations(" .TPL = terraform, j2=python, bad, x= ")
    XCTAssertEqual(map, ["tpl": "terraform", "j2": "python"])
    XCTAssertEqual(WorkbenchState.formatAssociations(map), "j2=python, tpl=terraform")
  }
}

final class TerraformCommentTests: XCTestCase {
  /// `@comment @spell` used to add a trailing plain span over the comment, painting it white.
  func testTerraformCommentHasNoPlainSpanOverIt() throws {
    let spans = try SyntaxHighlighter(languageID: .terraform).reset(to: TextBuffer("# note\nx = 1\n").snapshot)
    let onComment = spans.filter { $0.range.lowerBound.value == 0 }.map(\.kind)
    XCTAssertEqual(onComment, [.comment])
  }
}

final class AddedLanguageHighlightTests: XCTestCase {
  func testDetectsAddedExtensions() {
    let cases: [(String, EditorLanguageID)] = [
      ("a.html", .html), ("a.htm", .html), ("ci.yml", .yaml), ("a.yaml", .yaml),
      ("a.css", .css), ("Cargo.toml", .toml), ("a.c", .c), ("a.h", .c),
    ]
    for (path, id) in cases { XCTAssertEqual(EditorLanguageID.detect(path: path), id, path) }
  }

  /// Every added grammar compiles its query and paints the sample's first token.
  func testAddedLanguagesHighlight() throws {
    let samples: [(EditorLanguageID, String, EditorTokenKind)] = [
      (.html, "<div class=\"x\">hi</div>\n", .tag),  // `<` is punctuation; `div` at 1
      (.yaml, "key: \"value\"\n", .tag),
      (.css, "a { color: red; }\n", .tag),
      (.toml, "key = \"value\"\n", .tag),
      (.c, "int main(void) { return 0; }\n", .type),
    ]
    for (id, text, kind) in samples {
      XCTAssertNotNil(id.grammar.query, "\(id) query failed to compile")
      let spans = try SyntaxHighlighter(languageID: id).reset(to: TextBuffer(text).snapshot)
      let offset = id == .html ? 1 : 0
      XCTAssertTrue(
        spans.contains { $0.range.lowerBound.value == offset && $0.kind == kind },
        "\(id): \(spans.map { ($0.range.lowerBound.value, $0.kind) })")
    }
  }
}

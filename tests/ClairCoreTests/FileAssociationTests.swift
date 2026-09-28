import XCTest

@testable import ClairEditorCore
@testable import ClairEditorLanguage
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

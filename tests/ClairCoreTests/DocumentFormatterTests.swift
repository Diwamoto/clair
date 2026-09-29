import ClairWorkspace
import XCTest

final class DocumentFormatterTests: XCTestCase {
  func testFormatsNestedStructurePreservingKeyOrderAndLiterals() {
    let text = #"{"b":1,"a":[1,2,{"x":true,"y":null}],"c":"hi \"there\"","d":1.50e2,"e":[]}"#
    let expected = [
      #"{"#,
      #"  "b": 1,"#,
      #"  "a": ["#,
      #"    1,"#,
      #"    2,"#,
      #"    {"#,
      #"      "x": true,"#,
      #"      "y": null"#,
      #"    }"#,
      #"  ],"#,
      #"  "c": "hi \"there\"","#,
      #"  "d": 1.50e2,"#,
      #"  "e": []"#,
      #"}"#,
      #""#,
    ].joined(separator: "\n")
    XCTAssertEqual(JSONFormatter.format(text), expected)
  }

  func testEmptyContainersStayOnOneLine() {
    XCTAssertEqual(JSONFormatter.format("{}"), "{}\n")
    XCTAssertEqual(JSONFormatter.format("[ ]"), "[]\n")
  }

  func testIsIdempotent() {
    let once = JSONFormatter.format(#"{"a":[1,{"b":2}]}"#)!
    XCTAssertEqual(JSONFormatter.format(once), once)
  }

  func testRejectsMalformedJSON() {
    XCTAssertNil(JSONFormatter.format(#"{"a":1,}"#))
    XCTAssertNil(JSONFormatter.format(#"{"a":}"#))
    XCTAssertNil(JSONFormatter.format(#"{"a":1"#))
    XCTAssertNil(JSONFormatter.format("not json"))
    XCTAssertNil(JSONFormatter.format(#"{"a":1} trailing"#))
  }

  func testDocumentFormatterOnlySupportsJSON() {
    XCTAssertTrue(DocumentFormatter.supports("a/b.JSON"))
    XCTAssertFalse(DocumentFormatter.supports("a/b.md"))
    XCTAssertNil(DocumentFormatter.format("a.md", "{}"))
    XCTAssertEqual(DocumentFormatter.format("a.json", "{\"a\":1}"), "{\n  \"a\": 1\n}\n")
  }

  func testFormatCommandRequiresAnOpenSupportedFile() throws {
    var s = WorkbenchState()
    XCTAssertThrowsError(try CommandRegistry.workbench.execute("editor.format", state: &s).get())
    s.tabs = ["notes.md"]; s.active = "notes.md"
    XCTAssertThrowsError(try CommandRegistry.workbench.execute("editor.format", state: &s).get())
    s.tabs.append("data.json"); s.active = "data.json"
    XCTAssertNoThrow(try CommandRegistry.workbench.execute("editor.format", state: &s).get())
  }
}

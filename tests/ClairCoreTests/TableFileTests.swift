import ClairWorkspace
import XCTest

final class TableFileTests: XCTestCase {
  func testRoundTripsQuotingAndLineEndings() {
    XCTAssertEqual(TableFile.separator("a/b.CSV"), ",")
    XCTAssertEqual(TableFile.separator("x.tsv"), "\t")
    XCTAssertNil(TableFile.separator("x.md"))
    let text = "name,note\r\n\"Doe, J\",\"say \"\"hi\"\"\nthere\"\r\nx,\r\n"
    let rows = TableFile.parse(text, separator: ",")
    XCTAssertEqual(rows, [["name", "note"], ["Doe, J", "say \"hi\"\nthere"], ["x", ""]])
    XCTAssertEqual(TableFile.serialize(rows, separator: ",", lineEnding: "\r\n"), text)
    XCTAssertEqual(TableFile.parse("a\tb\n1\t2", separator: "\t"), [["a", "b"], ["1", "2"]])
    XCTAssertEqual(TableFile.serialize([["a", "b"]], separator: "\t", trailingNewline: false), "a\tb")
  }

  func testPreviewCommandAcceptsTables() throws {
    var s = WorkbenchState()
    s.tabs = ["data/x.csv"]; s.active = "data/x.csv"
    _ = try CommandRegistry.workbench.execute("editor.markdownPreview", state: &s).get()
    XCTAssertEqual(s.tree.leaves.filter { $0.kind == .preview }.count, 1)
    // A second file gets its own pane; the first keeps showing the CSV.
    s.tabs.append("notes.md"); s.active = "notes.md"
    _ = try CommandRegistry.workbench.execute("editor.markdownPreview", state: &s).get()
    let previews = s.tree.leaves.filter { $0.kind == .preview }.map { s.previews[$0.id] }
    XCTAssertEqual(Set(previews), ["data/x.csv", "notes.md"])
  }

  func testColumnNames() {
    XCTAssertEqual([0, 25, 26, 27, 701, 702].map(TableFile.columnName), ["A", "Z", "AA", "AB", "ZZ", "AAA"])
  }
}

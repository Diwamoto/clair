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

  func testBuiltinFormatterByExtensionOrSniffedText() {
    XCTAssertEqual(DocumentFormatter.builtin("a/b.JSON", ""), .json)
    XCTAssertEqual(DocumentFormatter.builtin("q.sql", ""), .sql)
    XCTAssertNil(DocumentFormatter.builtin("a/b.md", "{}"))
    XCTAssertNil(DocumentFormatter.format("a.md", "{}"))
    XCTAssertEqual(DocumentFormatter.format("a.json", "{\"a\":1}"), "{\n  \"a\": 1\n}\n")
    // No extension: JSON / SQL by content.
    XCTAssertEqual(DocumentFormatter.format(".eslintrc", " [1,2]"), "[\n  1,\n  2\n]\n")
    XCTAssertEqual(DocumentFormatter.builtin("scratch/query", "\n select 1"), .sql)
    XCTAssertNil(DocumentFormatter.builtin("Makefile", "all:\n\tgo build"))
  }

  func testSQLFormatterLaysOutClauses() {
    let sql = """
      -- users
      select u.id, count(*) as n, 'it''s' from users u left join orders o on o.user_id = u.id \
      where u.age between 18 and 30 and o.status in ('a', 'b') group by u.id order by n desc limit 10; \
      select * from (select id from t) x
      """
    let want = """
      -- users
      SELECT
        u.id,
        count(*) AS n,
        'it''s'
      FROM
        users u
        LEFT JOIN orders o ON o.user_id = u.id
      WHERE
        u.age BETWEEN 18 AND 30
        AND o.status IN ('a', 'b')
      GROUP BY
        u.id
      ORDER BY
        n DESC
      LIMIT
        10;

      SELECT
        *
      FROM
        (
          SELECT
            id
          FROM
            t
        ) x

      """
    XCTAssertEqual(SQLFormatter.format(sql), want)
    XCTAssertEqual(SQLFormatter.format(want), want)  // idempotent
    XCTAssertEqual(
      SQLFormatter.format("insert into t (a, b) values (1, 'x'), ($1, :n) on conflict (a) do update set b = excluded.b;\n/* x */"),
      "INSERT INTO\n  t (a, b)\nVALUES\n  (1, 'x'),\n  ($1, :n)\nON CONFLICT (a) DO UPDATE\nSET\n  b = excluded.b;\n\n/* x */\n")
    XCTAssertEqual(SQLFormatter.format("select a::int -- why\nfrom t"), "SELECT\n  a::int -- why\nFROM\n  t\n")
  }

  func testFormatCommandRequiresAnOpenFormattableFile() throws {
    var s = WorkbenchState()
    s.tabs = []; s.active = nil
    XCTAssertThrowsError(try CommandRegistry.workbench.execute("editor.format", state: &s).get())
    s.tabs = ["notes.md"]; s.active = "notes.md"
    XCTAssertThrowsError(try CommandRegistry.workbench.execute("editor.format", state: &s).get())
    s.tabs.append("data.json"); s.active = "data.json"
    XCTAssertNoThrow(try CommandRegistry.workbench.execute("editor.format", state: &s).get())
    // Source files go to their language server, which the GUI asks.
    s.tabs.append("main.go"); s.active = "main.go"
    XCTAssertNoThrow(try CommandRegistry.workbench.execute("editor.format", state: &s).get())
    XCTAssertTrue(DocumentFormatter.mayFormat("a/b.swift"))
    XCTAssertTrue(DocumentFormatter.mayFormat("a/query.sql"))
    XCTAssertTrue(DocumentFormatter.mayFormat("a/.eslintrc"))
    XCTAssertFalse(DocumentFormatter.mayFormat("a/b.md"))
  }

  func testChangedLinesKeepsUnchangedLinesOutOfTheEdit() {
    let old = "a\nb\nc\nd"
    let new = "a\nB\nx\nd"
    let (range, replacement) = DocumentFormatter.changedLines(from: old, to: new)
    XCTAssertEqual(range, 2..<5)
    XCTAssertEqual(replacement, "B\nx")
    var bytes = Array(old.utf8)
    bytes.replaceSubrange(range, with: Array(replacement.utf8))
    XCTAssertEqual(String(decoding: bytes, as: UTF8.self), new)
    let (all, rep) = DocumentFormatter.changedLines(from: "{\"é\":1}", to: "{\n  \"é\": 1\n}\n")
    XCTAssertEqual(all, 0..<"{\"é\":1}".utf8.count)
    XCTAssertEqual(rep, "{\n  \"é\": 1\n}\n")
  }
}

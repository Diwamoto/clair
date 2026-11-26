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

  func testBuiltinFormatterGoesByLanguage() {
    XCTAssertTrue(DocumentFormatter.isBuiltin("json"))
    XCTAssertTrue(DocumentFormatter.isBuiltin("sql"))
    XCTAssertFalse(DocumentFormatter.isBuiltin("go"))
    XCTAssertFalse(DocumentFormatter.isBuiltin(nil))
    XCTAssertNil(DocumentFormatter.format(language: "markdown", "{}"))
    XCTAssertEqual(DocumentFormatter.format(language: "json", "{\"a\":1}"), "{\n  \"a\": 1\n}\n")
    XCTAssertEqual(DocumentFormatter.format(language: "sql", "select 1"), "SELECT\n  1\n")
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

  func testFormatCommandRequiresAnOpenFile() throws {
    var s = WorkbenchState()
    s.tabs = []; s.active = nil
    XCTAssertThrowsError(try CommandRegistry.workbench.execute("editor.format", state: &s).get())
    // Any file: an extensionless one may have had its language picked in the status bar.
    s.tabs = ["query"]; s.active = "query"
    XCTAssertNoThrow(try CommandRegistry.workbench.execute("editor.format", state: &s).get())
  }

  func testLanguageCommandPinsAndClearsTheActiveFile() throws {
    var s = WorkbenchState()
    s.projects = [WorkbenchProject(name: "p", path: "/r")]; s.project = "p"
    s.tabs = ["query"]; s.active = "query"
    XCTAssertNoThrow(try CommandRegistry.workbench.execute("editor.language", ["language": .string("sql")], state: &s).get())
    XCTAssertEqual(s.languageOverrides, ["/r/query": "sql"])
    XCTAssertNoThrow(try CommandRegistry.workbench.execute("editor.language", ["language": .string("")], state: &s).get())
    XCTAssertEqual(s.languageOverrides, [:])
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

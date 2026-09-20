#if os(macOS)
  import XCTest

  @testable import ClairV2AppKit
  @testable import ClairV2EditorCore

  @MainActor final class ReviewViewsTests: XCTestCase {
    func testDiffRowsNumberNewSideOnly() {
      let d = "diff --git a/f b/f\nindex 1..2\n--- a/f\n+++ b/f\n@@ -1,2 +5,3 @@\n ctx\n-old\n+new\n+more"
      let r = DiffView.rows(d)
      XCTAssertEqual(r.map(\.newLine), [nil, 5, nil, 6, 7])  // hunk header, ctx, removed, added, added
      XCTAssertEqual(DiffView.rows("Binary files a/x and b/x differ").map(\.newLine), [nil])
      XCTAssertTrue(DiffView.rows("").isEmpty)
    }

    func testThreadAnchorsToLineAndResolves() throws {
      let snap = try TextBuffer("a\nbb\nccc").snapshot
      let s = ReviewStore()
      s.add(path: "f", line: 2, body: "  ", snapshot: snap)  // blank body is refused
      s.add(path: "f", line: 9, body: "x", snapshot: snap)  // past EOF is refused
      XCTAssertTrue(s.threads("f").isEmpty)
      s.add(path: "f", line: 2, body: "直して", snapshot: snap)
      let t = try XCTUnwrap(s.threads("f")[2]?.first)
      XCTAssertEqual(t.anchor?.range, TextUTF8Range(UTF8Offset(2), UTF8Offset(4)))
      s.resolve(path: "f", id: t.id)
      XCTAssertEqual(s.threads("f")[2]?.first?.state, .resolved)
    }
  }
#endif

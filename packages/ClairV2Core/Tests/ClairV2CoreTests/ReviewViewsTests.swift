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
      let s = ReviewStore(file: nil)
      s.add(root: "/r", path: "f", line: 2, body: "  ", snapshot: snap)  // blank body is refused
      s.add(root: "/r", path: "f", line: 9, body: "x", snapshot: snap)  // past EOF is refused
      XCTAssertTrue(s.threads(root: "/r", "f").isEmpty)
      s.add(root: "/r", path: "f", line: 2, body: "直して", snapshot: snap)
      let t = try XCTUnwrap(s.threads(root: "/r", "f")[2]?.first)
      XCTAssertEqual(t.anchor?.range, TextUTF8Range(UTF8Offset(2), UTF8Offset(4)))
      s.resolve(root: "/r", path: "f", id: t.id)
      XCTAssertEqual(s.threads(root: "/r", "f")[2]?.first?.state, .resolved)
      XCTAssertTrue(s.threads(root: "/other", "f").isEmpty)  // same path in another Project is separate
    }

    func testThreadsSurviveReload() throws {
      let f = FileManager.default.temporaryDirectory.appending(path: "reviews-\(UUID()).json")
      defer { try? FileManager.default.removeItem(at: f) }
      let s = ReviewStore(file: f)
      s.add(root: "/r", path: "f", line: 1, body: "x", snapshot: try TextBuffer("a\nb").snapshot)
      let t = try XCTUnwrap(s.threads(root: "/r", "f")[1]?.first)
      s.resolve(root: "/r", path: "f", id: t.id)
      let again = try XCTUnwrap(ReviewStore(file: f).threads(root: "/r", "f")[1]?.first)
      XCTAssertEqual(again.id, t.id); XCTAssertEqual(again.state, .resolved)
    }
  }
#endif

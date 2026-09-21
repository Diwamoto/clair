#if os(macOS)
  import XCTest

  @testable import ClairAppKit
  @testable import ClairEditorCore
  @testable import ClairReview

  @MainActor final class ReviewViewsTests: XCTestCase {
    func testDiffRowsNumberNewSideOnly() {
      let d = "diff --git a/f b/f\nindex 1..2\n--- a/f\n+++ b/f\n@@ -1,2 +5,3 @@\n ctx\n-old\n+new\n+more"
      let r = DiffView.rows(d)
      XCTAssertEqual(r.map(\.newLine), [nil, 5, nil, 6, 7])  // hunk header, ctx, removed, added, added
      XCTAssertEqual(DiffView.rows("Binary files a/x and b/x differ").map(\.newLine), [nil])
      XCTAssertTrue(DiffView.rows("").isEmpty)
      let st = DiffView.stats(r)
      XCTAssertEqual([st.added, st.removed], [2, 1])
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

    func testPromptListsOpenThreadsOnly() throws {
      let s = ReviewStore(file: nil), snap = try TextBuffer("a\nb").snapshot
      XCTAssertNil(s.prompt(root: "/r", path: "f"))
      s.add(root: "/r", path: "f", line: 2, body: "B", snapshot: snap)
      s.add(root: "/r", path: "f", line: 1, body: "A", snapshot: snap)
      let done = try XCTUnwrap(s.threads(root: "/r", "f")[2]?.first)
      XCTAssertTrue(try XCTUnwrap(s.prompt(root: "/r", path: "f")).hasSuffix("f:1\n- A\n\nf:2\n- B"))
      s.resolve(root: "/r", path: "f", id: done.id)
      XCTAssertFalse(try XCTUnwrap(s.prompt(root: "/r", path: "f")).contains("f:2"))
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

    func testThreadFollowsItsLineAndGoesStale() throws {
      let s = ReviewStore(file: nil), snap = try TextBuffer("a\nb\nc").snapshot
      s.add(root: "/r", path: "f", line: 2, text: "b", body: "B", snapshot: snap)
      func at(_ file: String) -> [Int: [ReviewThread]] { s.threads(root: "/r", "f", in: file.split(separator: "\n", omittingEmptySubsequences: false)) }
      XCTAssertEqual(at("a\nb\nc").keys.sorted(), [2])
      XCTAssertEqual(at("x\ny\na\nb\nc").keys.sorted(), [4])  // lines inserted above: follows
      XCTAssertEqual(at("a\nB\nc").keys.sorted(), [0])  // line reworded: stale
      XCTAssertTrue(try XCTUnwrap(s.prompt(root: "/r", path: "f", in: ["a", "B", "c"])).contains("f:2（コメント後に行が変更"))
    }

    func testSuggestionAppliesOnceAndGoesStaleAfterEdit() throws {
      let s = ReviewStore(file: nil)
      let m = EditorTransactionManager(buffer: try TextBuffer("a\nbb\nc"), selection: TextSelectionSet(cursor: UTF8Offset(0)))
      s.suggest(root: "/r", path: "f", line: 2, replacement: "BB", snapshot: m.buffer.snapshot)
      let p = try XCTUnwrap(s.suggestions(root: "/r", "f", current: m.buffer.snapshot.revision).first)
      XCTAssertFalse(p.stale)
      XCTAssertNil(s.apply(root: "/r", path: "f", id: p.id, in: m))
      XCTAssertEqual(m.buffer.snapshot.string(), "a\nBB\nc")
      XCTAssertNotNil(s.apply(root: "/r", path: "f", id: p.id, in: m))  // already applied
      // a second suggestion made before an edit is refused after it
      let m2 = EditorTransactionManager(buffer: try TextBuffer("a\nb"), selection: TextSelectionSet(cursor: UTF8Offset(0)))
      s.suggest(root: "/r", path: "g", line: 2, replacement: "z", snapshot: m2.buffer.snapshot)
      try m2.apply([TextEdit(range: TextUTF8Range(UTF8Offset(0), UTF8Offset(0)), replacement: "x")])
      let q = try XCTUnwrap(s.suggestions(root: "/r", "g", current: m2.buffer.snapshot.revision).first)
      XCTAssertTrue(q.stale)
      XCTAssertNotNil(s.apply(root: "/r", path: "g", id: q.id, in: m2))
    }
  }
#endif

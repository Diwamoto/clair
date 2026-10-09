#if os(macOS)
  import XCTest

  @testable import ClairAppKit
  @testable import ClairEditorCore
  import ClairEditorView
  @testable import ClairReview
  @testable import ClairWorkspace

  @MainActor final class ReviewViewsTests: XCTestCase {
    func testDiffRowsNumberNewSideOnly() {
      let d = "diff --git a/f b/f\nindex 1..2\n--- a/f\n+++ b/f\n@@ -1,2 +5,3 @@\n ctx\n-old\n+new\n+more"
      let r = DiffView.rows(d)
      XCTAssertEqual(r.map(\.newLine), [nil, 5, nil, 6, 7])  // hunk header, ctx, removed, added, added
      XCTAssertEqual(r.map(\.oldLine), [nil, 1, 2, nil, nil])
      XCTAssertEqual(DiffView.rows("Binary files a/x and b/x differ").map(\.newLine), [nil])
      XCTAssertTrue(DiffView.rows("").isEmpty)
      let st = DiffView.stats(r)
      XCTAssertEqual([st.added, st.removed], [2, 1])
    }

    func testSubmoduleDiffKeepsFileHeadersAndDropsPatchMetadata() {
      let d = "diff --git a/s/a b/s/a\nindex 1..2\n--- a/s/a\n+++ b/s/a\n@@ -1 +1 @@\n-x\n+y\n"
        + "diff --git a/s/b b/s/b\nnew file mode 100644\n--- /dev/null\n+++ b/s/b\n@@ -0,0 +1 @@\n+z"
      let r = DiffView.rows(d)
      XCTAssertEqual(r.map(\.text), ["diff --git a/s/a b/s/a", "@@ -1 +1 @@", "-x", "+y", "diff --git a/s/b b/s/b", "@@ -0,0 +1 @@", "+z"])
      XCTAssertEqual(r.map(\.newLine), [nil, nil, nil, 1, nil, nil, 1])
    }

    func testDiffFoldsKeepThreeLinesAroundChanges() {
      let ctx = (1...10).map { " c\($0)" }.joined(separator: "\n")
      let f = DiffView.folds(DiffView.rows("@@ -1,11 +1,11 @@\n" + ctx + "\n-x\n+y"))
      // header(0) keeps c1-c3 visible, c4-c7 fold as one run starting at row 4, c8-c10 sit next to the change.
      XCTAssertEqual(f, [nil, nil, nil, nil, 4, 4, 4, 4, nil, nil, nil, nil, nil])
    }

    func testLargeDiffParsingStaysWithinInteractionBudget() {
      let text = "@@ -1,5000 +1,5000 @@\n" + (0..<5000).map { $0.isMultiple(of: 3) ? "+line \($0)" : " line \($0)" }.joined(separator: "\n")
      let start = Date()
      let model = DiffView.model(text)
      let elapsed = Date().timeIntervalSince(start)
      XCTAssertEqual(model.rows.count, DiffView.maxLines)
      XCTAssertLessThan(elapsed, 0.2, "5,000-line diff parsing took \(elapsed)s")
    }

    func testTwentyThousandFileExplorerModelStaysWithinInteractionBudget() {
      let files = (0..<20_000).map { WorkbenchFile(path: "Sources/G\($0 % 100)/file\($0).swift", status: nil) }
      let start = Date()
      let rows = ClairAppShell.explorerRows(for: files)
      let elapsed = Date().timeIntervalSince(start)
      XCTAssertGreaterThan(rows.count, files.count)
      XCTAssertLessThan(elapsed, 0.2, "20,000-file explorer model took \(elapsed)s")
    }

    func testFolderTakesHighestChangeRank() {
      let files = [("a/new.swift", "U"), ("a/b/edit.swift", "M"), ("a/b/gone.swift", "D"), ("c/new.swift", "A"), ("c/typed.swift", nil), ("d/x", nil)]
        .map { WorkbenchFile(path: $0.0, status: $0.1) }
      let r = ClairAppShell.changeRanks(files, dirty: ["c/typed.swift"])
      XCTAssertEqual(r["a/new.swift"], 1)
      XCTAssertEqual(r["a/b"], 3)
      XCTAssertEqual(r["a"], 3)
      XCTAssertEqual(r["c"], 2)
      XCTAssertNil(r["d"])
      XCTAssertFalse(ClairAppShell.explorerRows(for: files).contains { $0.id == "a/b/gone.swift" })
    }

    func testIgnoredRowsAreDimmedAndNotChanges() {
      let files = [("a/x.swift", nil), ("a/.env", "!"), ("dist/b/out.js", "!")].map { WorkbenchFile(path: $0.0, status: $0.1) }
      let rows = Dictionary(uniqueKeysWithValues: ClairAppShell.explorerRows(for: files).map { ($0.id, $0.ignored) })
      XCTAssertEqual(rows, ["a": false, "a/x.swift": false, "a/.env": true, "dist": true, "dist/b": true, "dist/b/out.js": true])
      XCTAssertTrue(ClairAppShell.changeRanks(files, dirty: []).isEmpty)
    }

    func testAddedFolderIsOneTopLevelRow() {
      let files = ["main.go", "../../x/docs/a/b.md"].map { WorkbenchFile(path: $0, status: nil) }
      let rows = ClairAppShell.explorerRows(for: files, roots: ["../../x/docs"])
      XCTAssertEqual(rows.map(\.label), ["main.go", "docs", "a", "b.md"])
      XCTAssertEqual(rows.map(\.depth), [1, 1, 2, 3])
      XCTAssertEqual(rows[1].id, "../../x/docs")
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
      func at(_ file: String) -> [Int: [ReviewThread]] {
        s.threads(root: "/r", "f", in: file.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
      }
      XCTAssertEqual(at("a\nb\nc").keys.sorted(), [2])
      XCTAssertEqual(at("x\ny\na\nb\nc").keys.sorted(), [4])  // lines inserted above: follows
      XCTAssertEqual(at("a\nB\nc").keys.sorted(), [0])  // line reworded: stale
      XCTAssertTrue(try XCTUnwrap(s.prompt(root: "/r", path: "f", in: ["a", "B", "c"])).contains("f:2 (the line changed after the comment)"))
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

    func testAgentThreadsSpanLinesAndListForAgents() throws {
      let s = ReviewStore(file: nil), snap = try TextBuffer("a\nbb\nc").snapshot
      XCTAssertFalse(s.add(root: "/r", path: "f", line: 4, body: "x", snapshot: snap))
      XCTAssertTrue(s.add(root: "/r", path: "f", line: 2, endLine: 3, text: "bb", body: "racy", author: ReviewStore.agent, snapshot: snap))
      s.add(root: "/r", path: "g", line: 1, body: "mine", snapshot: snap)
      let t = try XCTUnwrap(s.threads(root: "/r", "f")[2]?.first)
      XCTAssertEqual(t.anchor?.range, TextUTF8Range(UTF8Offset(2), UTF8Offset(6)))  // "bb\nc"
      XCTAssertEqual(t.comments.first?.author.kind, .agent)
      let all = s.list(root: "/r") { $0 == "f" ? ["x", "a", "bb", "c"] : nil }
      XCTAssertEqual(all.map(\.path), ["f", "g"])
      XCTAssertEqual(all[0].line, 3)  // followed its line in the current file
      XCTAssertEqual(all[0].comments, [.init(author: "Agent", body: "racy")])
      XCTAssertEqual(s.list(root: "/r", path: "g") { _ in nil }.map(\.comments.first?.body), ["mine"])
      XCTAssertTrue(s.list(root: "/other") { _ in nil }.isEmpty)
    }

    func testMultiLineSuggestionReplacesItsRange() throws {
      let s = ReviewStore(file: nil)
      let m = EditorTransactionManager(buffer: try TextBuffer("a\nb\nc\nd"), selection: TextSelectionSet(cursor: UTF8Offset(0)))
      XCTAssertFalse(s.suggest(root: "/r", path: "f", line: 5, replacement: "x", snapshot: m.buffer.snapshot))
      XCTAssertTrue(s.suggest(root: "/r", path: "f", line: 2, endLine: 3, replacement: "B", description: "merge", snapshot: m.buffer.snapshot))
      let p = try XCTUnwrap(s.suggestions(root: "/r", "f", current: m.buffer.snapshot.revision).first)
      XCTAssertEqual(p.endLine, 3); XCTAssertEqual(p.suggestion.description, "merge")
      XCTAssertNil(s.apply(root: "/r", path: "f", id: p.id, in: m))
      XCTAssertEqual(m.buffer.snapshot.string(), "a\nB\nd")
    }

    func testDiagnosticsReportOneBasedLinesAndUTF16Columns() throws {
      let snap = try TextBuffer("let a = 1\n  é = x\n").snapshot
      let spans = [
        EditorDiagnosticSpan(range: TextUTF8Range(UTF8Offset(15), UTF8Offset(16)), severity: .warning, message: "w"),
        EditorDiagnosticSpan(range: TextUTF8Range(UTF8Offset(4), UTF8Offset(5)), severity: .error, message: "e"),
      ]
      let d = ClairWorkbenchStore.diagnostics(spans, in: snap, path: "/r/f.go")
      XCTAssertEqual(d.map(\.message), ["e", "w"])
      XCTAssertEqual(d[0], WorkbenchDiagnostic(path: "/r/f.go", line: 1, column: 4, endLine: 1, endColumn: 5, severity: "error", message: "e"))
      XCTAssertEqual([d[1].line, d[1].column, d[1].endColumn], [2, 4, 5])  // é is 2 UTF-8 bytes, 1 UTF-16 unit
    }

    func testLargeDiffModelIsBounded() {
      let body = (1...8_000).map { "+line \($0)" }.joined(separator: "\n")
      let model = DiffView.model("@@ -0,0 +1,8000 @@\n" + body)
      XCTAssertEqual(model.rows.count, DiffView.maxLines)
      XCTAssertEqual(model.added, DiffView.maxLines - 1)
      XCTAssertEqual(model.hunks, [0])
    }
  }
#endif

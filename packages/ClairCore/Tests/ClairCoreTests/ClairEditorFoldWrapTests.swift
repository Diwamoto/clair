#if os(macOS)
  import AppKit
  import XCTest

  @testable import ClairEditorCore
  @testable import ClairEditorLanguage
  @testable import ClairEditorView

  /// E13: code folding and soft wrap — the row arithmetic, the wrap grid, and
  /// the view driven through its real handlers.
  @MainActor final class ClairEditorFoldWrapTests: XCTestCase {
    // MARK: - EditorRowMap / EditorWrap

    func testRowMapSkipsHiddenLinesAndCountsWrappedRows() {
      var map = EditorRowMap(lineCount: 10)
      map.setWraps([(1, 2), (4, 1)], lineCount: 10)
      map.setHidden([3...5])
      // line0 r0 · line1 r1-3 · line2 r4 · (3,4,5 hidden; 4's wrap does not count) · line6 r5 … line9 r8
      XCTAssertEqual(map.rowCount, 9)
      XCTAssertEqual(map.row(of: 2), 4)
      XCTAssertEqual(map.row(of: 6), 5)
      XCTAssertEqual(map.rows(of: 1), 3)
      XCTAssertEqual(map.rows(of: 4), 0)
      XCTAssertEqual(map.line(atRow: 2).line, 1)
      XCTAssertEqual(map.line(atRow: 2).subrow, 1)
      XCTAssertEqual(map.line(atRow: 5).line, 6)
      XCTAssertEqual(map.lines(inRows: 0..<9).map(\.line), [0, 1, 2, 6, 7, 8, 9])
      // An edit that inserts 2 lines at line 1 shifts the wraps below it and re-measures only line 1…3.
      map.replaceWraps(first: 1, oldLast: 1, newLast: 3, recomputed: [(1, 0), (2, 0), (3, 1)], lineCount: 12)
      XCTAssertEqual(map.wraps.map(\.line), [3, 6])
      XCTAssertTrue(EditorRowMap(lineCount: 3).isIdentity)
    }

    func testWrapBreaksOnTheMonospaceGridCountingWideGlyphsAsTwo() {
      XCTAssertEqual(EditorWrap.breaks("abcdef", columns: 4), [4])
      XCTAssertEqual(EditorWrap.breaks("abcd", columns: 4), [])
      // Each kana is two columns and one UTF-16 unit: two per row.
      XCTAssertEqual(EditorWrap.breaks("あいうえ", columns: 4), [2])
      // An emoji cluster is never split.
      XCTAssertEqual(EditorWrap.breaks("ab👍🏽cd", columns: 3), [2, 7])  // 👍🏽 is 4 UTF-16 units
    }

    // MARK: - View

    private static let source = """
      func a() {
      \tx := 1
      \ty := 2
      }
      func b() {}

      """

    private func makeView(_ text: String = source, width: CGFloat = 400) throws -> ClairEditorView {
      let view = ClairEditorView(snapshot: try TextBuffer(text).snapshot, selection: TextSelectionSet(cursor: UTF8Offset(0)))
      view.setFrameSize(NSSize(width: width, height: 400))
      view.gutterWidth = 46
      return view
    }

    private func byteRange(_ text: String, from: String, through: String) -> TextUTF8Range {
      let lower = text.range(of: from)!.lowerBound
      let upper = text.range(of: through, range: lower..<text.endIndex)!.upperBound
      return TextUTF8Range(
        UTF8Offset(text.utf8.distance(from: text.startIndex, to: lower)),
        UTF8Offset(text.utf8.distance(from: text.startIndex, to: upper)))
    }

    /// Commits one edit the way the host does: apply to a buffer, then `applyEdits`.
    private func commit(_ view: ClairEditorView, _ manager: EditorTransactionManager, _ edit: TextEdit) throws {
      let old = manager.buffer.snapshot
      let new = try manager.apply([edit])
      view.applyEdits([edit], oldSnapshot: old, newSnapshot: new, selection: manager.selection)
    }

    func testFoldHidesTheBodyKeepsTheClosingBraceAndReopensWhenTheCaretLandsInside() throws {
      let view = try makeView()
      view.foldRanges = [byteRange(Self.source, from: "func a", through: "}")]
      view.toggleFold(line: 0)
      XCTAssertEqual(view.rowMap.hidden, [1...2])
      XCTAssertEqual(view.rowMap.rowCount, view.snapshot.lineCount - 2)
      XCTAssertEqual(view.frame.height, CGFloat(view.rowMap.rowCount) * view.lineHeight)
      // Row 1 is now the closing brace (line 3).
      let hit = try XCTUnwrap(view.hitTestOffset(at: NSPoint(x: view.textInset + 1, y: 1.5 * view.lineHeight)))
      XCTAssertEqual(try view.snapshot.position(at: hit, columnUnit: UTF8Unit.self).line.value, 3)
      // ↓ from the header skips the folded body.
      view.selection = TextSelectionSet(cursor: UTF8Offset(0))
      view.doCommand(by: #selector(NSResponder.moveDown(_:)))
      XCTAssertEqual(view.folds.count, 1)
      XCTAssertEqual(try view.snapshot.position(at: view.selection.selections[0].head, columnUnit: UTF8Unit.self).line.value, 3)
      // A jump into the body (search hit, definition, review anchor) opens it.
      view.reveal(line: 2)
      XCTAssertTrue(view.folds.isEmpty)
      XCTAssertTrue(view.rowMap.hidden.isEmpty)
    }

    func testFoldFollowsEditsAboveAndIsDroppedByAnEditInsideIt() throws {
      let manager = EditorTransactionManager(buffer: try TextBuffer(Self.source), selection: TextSelectionSet(cursor: UTF8Offset(0)))
      let view = ClairEditorView(snapshot: manager.buffer.snapshot, selection: manager.selection)
      view.setFrameSize(NSSize(width: 400, height: 400))
      view.foldRanges = [byteRange(Self.source, from: "func a", through: "}")]
      view.toggleFold(line: 0)
      // Two lines inserted above: the fold moves with its text (position mapping, INV-TXN-003).
      try commit(view, manager, TextEdit(range: TextUTF8Range(UTF8Offset(0), UTF8Offset(0)), replacement: "// a\n// b\n"))
      XCTAssertEqual(view.rowMap.hidden, [3...4])
      // Typing at the end of the header line keeps it.
      let headerEnd = UTF8Offset("// a\n// b\nfunc a() {".utf8.count)
      manager.setSelection(TextSelectionSet(cursor: headerEnd))
      try commit(view, manager, TextEdit(range: TextUTF8Range(headerEnd, headerEnd), replacement: " "))
      XCTAssertEqual(view.folds.count, 1)
      // An edit inside the hidden body drops the fold rather than guessing.
      let body = UTF8Offset("// a\n// b\nfunc a() { \n\tx".utf8.count)
      try commit(view, manager, TextEdit(range: TextUTF8Range(body, body), replacement: "x"))
      XCTAssertTrue(view.folds.isEmpty)
    }

    func testGutterClickAndCaretCommandsFoldAndUnfold() throws {
      let view = try makeView()
      view.foldRanges = [byteRange(Self.source, from: "func a", through: "}")]
      let event = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: view.convert(NSPoint(x: view.gutterWidth - 6, y: 0.5 * view.lineHeight), to: nil),
          modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      view.mouseDown(with: event)
      XCTAssertEqual(view.folds.count, 1)
      view.mouseDown(with: event)
      XCTAssertTrue(view.folds.isEmpty)
      // ⌥⌘[ with the caret inside the body folds and parks the caret on the header.
      view.selection = TextSelectionSet(cursor: UTF8Offset("func a() {\n\tx".utf8.count))
      view.foldAtCaret()
      XCTAssertEqual(view.folds.count, 1)
      XCTAssertEqual(try view.snapshot.position(at: view.selection.selections[0].head, columnUnit: UTF8Unit.self).line.value, 0)
      view.unfoldAtCaret()
      XCTAssertTrue(view.folds.isEmpty)
      view.foldAll()
      XCTAssertEqual(view.folds.count, 1)  // `func b() {}` is one line: nothing to fold
      view.unfoldAll()
      XCTAssertTrue(view.folds.isEmpty)
    }

    func testSoftWrapBreaksALongLineIntoRowsAndFollowsEditsIncrementally() throws {
      let long = String(repeating: "abcdefghij", count: 20)  // 200 columns
      let text = "short\n" + long + "\nend\n"
      let manager = EditorTransactionManager(buffer: try TextBuffer(text), selection: TextSelectionSet(cursor: UTF8Offset(0)))
      let view = ClairEditorView(snapshot: manager.buffer.snapshot, selection: manager.selection)
      view.setFrameSize(NSSize(width: 400, height: 400))
      view.softWrap = true
      let columns = view.wrapColumns
      let rows = (200 + columns - 1) / columns
      XCTAssertGreaterThan(rows, 1)
      XCTAssertEqual(view.rowMap.rowCount, 4 + rows - 1)
      XCTAssertEqual(view.frame.height, CGFloat(view.rowMap.rowCount) * view.lineHeight)
      // The second row of the long line hits text past the first break.
      let hit = try XCTUnwrap(view.hitTestOffset(at: NSPoint(x: view.textInset + 1, y: 2.5 * view.lineHeight)))
      XCTAssertEqual(hit.value, 6 + columns)
      // …and the caret there is drawn on that row, at the left edge.
      let rect = try XCTUnwrap(view.caretRect(for: hit))
      XCTAssertEqual(rect.minY, 2 * view.lineHeight)
      XCTAssertEqual(rect.minX, view.textInset, accuracy: 0.5)
      // ↓ from row 1 of the long line steps to its row 2, not past the whole line.
      view.selection = TextSelectionSet(cursor: UTF8Offset(7))
      view.doCommand(by: #selector(NSResponder.moveDown(_:)))
      XCTAssertEqual(view.selection.selections[0].head.value, 7 + columns)
      // Deleting most of the long line re-measures only it.
      try commit(view, manager, TextEdit(range: TextUTF8Range(UTF8Offset(6), UTF8Offset(6 + 190)), replacement: ""))
      XCTAssertEqual(view.rowMap.rowCount, 4)
      XCTAssertTrue(view.rowMap.isIdentity)
      view.softWrap = false
      XCTAssertTrue(view.rowMap.isIdentity)
    }

    func testFoldRangesComeFromTheSyntaxTree() throws {
      let go = "package main\n\nfunc main() {\n\tx := 1\n\t_ = x\n}\n"
      let highlighter = try SyntaxHighlighter(languageID: .go)
      _ = try highlighter.reset(to: try TextBuffer(go).snapshot)
      let header = UTF8Offset(go.utf8.distance(from: go.startIndex, to: go.range(of: "func main")!.lowerBound))
      XCTAssertTrue(highlighter.foldRanges.contains { $0.lowerBound == header && $0.upperBound.value == go.utf8.count - 1 })
      XCTAssertFalse(highlighter.foldRanges.contains { $0.lowerBound.value == 0 })  // the root is not a fold
    }

    func testMarkdownFoldsSectionsAndCodeBlocksButNotListItems() throws {
      let markdown = """
        # Decision
        - First item
          continued text
        - Second item
          continued text

        ```swift
        let value = 1
        ```

        ## Next section
        More text
        """
      let highlighter = try SyntaxHighlighter(languageID: .markdown)
      _ = try highlighter.reset(to: try TextBuffer(markdown).snapshot)
      let startLines = highlighter.foldRanges.map { range in
        markdown.utf8.prefix(range.lowerBound.value).filter { $0 == 10 }.count
      }
      XCTAssertTrue(startLines.contains(0))
      XCTAssertTrue(startLines.contains(6))
      XCTAssertFalse(startLines.contains(1))
      XCTAssertFalse(startLines.contains(3))
    }

    func testCodeFoldsDeclarationsButNotMultilineValues() throws {
      let examples: [(EditorLanguageID, String)] = [
        (.swift, "func run() {\n  let values = [\n    1,\n    2\n  ]\n}\n"),
        (.python, "def run():\n    values = [\n        1,\n        2,\n    ]\n"),
        (.ruby, "def run\n  values = [\n    1,\n    2\n  ]\nend\n"),
      ]
      for (language, source) in examples {
        let highlighter = try SyntaxHighlighter(languageID: language)
        _ = try highlighter.reset(to: try TextBuffer(source).snapshot)
        let startLines = highlighter.foldRanges.map { range in
          source.utf8.prefix(range.lowerBound.value).filter { $0 == 10 }.count
        }
        XCTAssertTrue(startLines.contains(0), "\(language)")
        XCTAssertFalse(startLines.contains(1), "\(language)")
      }
    }

    func testEveryOtherLanguageKeepsStructuralFolds() throws {
      let examples: [(EditorLanguageID, String, Int?)] = [
        (.go, "package main\nfunc run() {\n  values := []int{\n    1,\n    2,\n  }\n}\n", 2),
        (.javascript, "function run() {\n  const values = [\n    1,\n    2\n  ];\n}\n", 1),
        (.typescript, "function run(): void {\n  const values = [\n    1,\n    2\n  ];\n}\n", 1),
        (.json, "{\n  \"values\": [\n    1,\n    2\n  ]\n}\n", nil),
        (.rust, "fn run() {\n  let values = [\n    1,\n    2\n  ];\n}\n", 1),
        (.shell, "run() {\n  values=(\n    one\n    two\n  )\n}\n", 1),
        (.java, "class Example {\n  int[] values = {\n    1,\n    2\n  };\n}\n", 1),
        (.php, "<?php\nfunction run() {\n  $values = [\n    1,\n    2\n  ];\n}\n", 2),
        (.terraform, "resource \"test\" \"example\" {\n  tags = {\n    one = \"1\"\n    two = \"2\"\n  }\n}\n", nil),
      ]
      for (language, source, valueLine) in examples {
        let highlighter = try SyntaxHighlighter(languageID: language)
        _ = try highlighter.reset(to: try TextBuffer(source).snapshot)
        let startLines = highlighter.foldRanges.map { range in
          source.utf8.prefix(range.lowerBound.value).filter { $0 == 10 }.count
        }
        let declarationLine = language == .go || language == .php ? 1 : 0
        XCTAssertTrue(startLines.contains(declarationLine), "\(language)")
        if let valueLine { XCTAssertFalse(startLines.contains(valueLine), "\(language)") }
      }
    }
  }
#endif

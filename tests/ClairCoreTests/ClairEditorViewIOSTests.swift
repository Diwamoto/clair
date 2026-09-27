#if os(iOS)
  import CoreText
  import UIKit
  import XCTest

  @testable import ClairEditorCore
  @testable import ClairEditorView

  /// E08: iOS/iPadOS `ClairEditorView` (`UIView`/`UITextInput`).
  ///
  /// Mirrors `ClairEditorViewTests.swift`'s macOS coverage (`EditingHarness`
  /// wired to a real `EditorTransactionManager`, so the acceptance
  /// criteria's "same Mac transaction fixture" is literally the same
  /// scenario re-run against this platform's commit path) plus iOS-specific
  /// coverage: touch hit-testing through `UITextInput`'s `closestPosition`/
  /// `characterRange`, marked-text lifecycle through `setMarkedText`/
  /// `unmarkText`/`insertText`, and viewport-virtualization bounds for the
  /// `UIView` draw path.
  @MainActor
  private final class EditingHarness {
    let manager: EditorTransactionManager
    let view: ClairEditorView

    init(_ text: String) throws {
      let buffer = try TextBuffer(text)
      let manager = EditorTransactionManager(
        buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
      let view = ClairEditorView(snapshot: buffer.snapshot, selection: manager.selection)
      self.manager = manager
      self.view = view
      view.onCommitEdits = { [weak view, weak manager] edits in
        guard let view, let manager else { return }
        let old = manager.buffer.snapshot
        guard let new = try? manager.apply(edits) else { return }
        view.applyEdits(edits, oldSnapshot: old, newSnapshot: new, selection: manager.selection)
      }
      view.onSelectionChange = { [weak manager] selection in
        manager?.setSelection(selection)
      }
    }

    /// Test-only convenience, same rationale as the macOS harness: a real
    /// host only changes `view.selection` through a gesture that also
    /// fires `onSelectionChange`, which keeps `manager.selection` synced.
    /// Tests that set up a precondition selection bypass that gesture, so
    /// they sync both sides themselves.
    func select(_ selection: TextSelectionSet) {
      view.selection = selection
      manager.setSelection(selection)
    }
  }

  @MainActor
  final class ClairEditorViewIOSTests: XCTestCase {
    private func harness(_ text: String) throws -> EditingHarness { try EditingHarness(text) }

    private func renderOffscreen(
      _ view: ClairEditorView, size: CGSize = CGSize(width: 400, height: 200)
    )
      throws
    {
      view.frame = CGRect(origin: .zero, size: size)
      UIGraphicsBeginImageContextWithOptions(size, true, 1)
      defer { UIGraphicsEndImageContext() }
      let context = try XCTUnwrap(UIGraphicsGetCurrentContext())
      UIGraphicsPushContext(context)
      defer { UIGraphicsPopContext() }
      view.draw(CGRect(origin: .zero, size: size))
    }

    // MARK: - Viewport virtualization

    func testDrawDoesNotCrashAndSizesFrameToLineCount() throws {
      let text = (0..<50).map { "line \($0) hello world" }.joined(separator: "\n")
      let h = try harness(text)
      try renderOffscreen(h.view)
      XCTAssertEqual(
        h.view.frame.height, CGFloat(h.manager.buffer.snapshot.lineCount) * h.view.lineHeight,
        accuracy: 0.01)
    }

    func testHighlightAndDiagnosticSpansDoNotCrashRendering() throws {
      let h = try harness(#"{"a": 1}"#)
      h.view.highlights = [
        EditorHighlightSpan(range: TextUTF8Range(UTF8Offset(1), UTF8Offset(4)), kind: .string)
      ]
      h.view.diagnostics = [
        EditorDiagnosticSpan(range: TextUTF8Range(UTF8Offset(6), UTF8Offset(7)), severity: .error)
      ]
      try renderOffscreen(h.view)
    }

    // MARK: - Touch hit-testing (`UITextInput`)

    func testHitTestOffsetRoundTripsToClickedCharacter() throws {
      let h = try harness("hello world\nsecond line")
      try renderOffscreen(h.view)

      guard let offset = h.view.hitTestOffset(at: CGPoint(x: 5, y: 5)) else {
        return XCTFail("expected a hit-test offset")
      }
      let position = try h.manager.buffer.snapshot.position(at: offset, columnUnit: UTF8Unit.self)
      XCTAssertEqual(position.line.value, 0)
    }

    func testHitTestSecondLineReturnsSecondLineOffset() throws {
      let h = try harness("hello world\nsecond line")
      try renderOffscreen(h.view)

      guard let offset = h.view.hitTestOffset(at: CGPoint(x: 5, y: h.view.lineHeight + 2)) else {
        return XCTFail("expected a hit-test offset")
      }
      let position = try h.manager.buffer.snapshot.position(at: offset, columnUnit: UTF8Unit.self)
      XCTAssertEqual(position.line.value, 1)
    }

    func testHitTestPastEndOfLineSnapsToLineEnd() throws {
      let h = try harness("hello world\nsecond line")
      try renderOffscreen(h.view)

      guard let offset = h.view.hitTestOffset(at: CGPoint(x: 1000, y: 5)) else {
        return XCTFail("expected a hit-test offset")
      }
      let position = try h.manager.buffer.snapshot.position(at: offset, columnUnit: UTF8Unit.self)
      XCTAssertEqual(position.line.value, 0)
      XCTAssertEqual(position.column.value, 11)
    }

    func testHitTestEmptyLinePlacesCaretOnThatLine() throws {
      let h = try harness("hello\n\nworld")
      try renderOffscreen(h.view)

      guard let offset = h.view.hitTestOffset(at: CGPoint(x: 100, y: h.view.lineHeight + 5)) else {
        return XCTFail("expected a hit-test offset")
      }
      let position = try h.manager.buffer.snapshot.position(at: offset, columnUnit: UTF8Unit.self)
      XCTAssertEqual(position.line.value, 1)
      XCTAssertEqual(position.column.value, 0)
    }

    /// Regression for a D5 review finding: `hitTestOffset` used to call
    /// `renderer.line(at:...)` directly — the plain, cached, committed-
    /// buffer `CTLine` — even while an IME composition was live on the
    /// touched line, so a tap past the composition's on-screen splice
    /// hit-tested against glyph positions that were no longer what was
    /// actually drawn. `hitTestOffset` must go through the same
    /// composition-aware `renderedLine(at:)` `draw(_:)` uses, and map the
    /// resulting index back to a *buffer* column.
    func testHitTestDuringCompositionAccountsForComposedSpliceNotBufferGlyphs() throws {
      // Buffer: "hello world" (11 UTF-16 units, one line). Compose "かな"
      // (2 UTF-16 units) at buffer offset 5 — right after "hello", before
      // the space — so the on-screen line becomes "helloかな world" (13
      // UTF-16 units): 2 units wider than the committed buffer.
      let h = try harness("hello world")
      h.select(TextSelectionSet(cursor: UTF8Offset(5)))
      h.view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
      try renderOffscreen(h.view)

      // Composed-local UTF-16 index 10 sits inside "world", between "wo"
      // and "rld" on screen: "helloかな wo|rld" (indices 0-4 "hello", 5-6
      // "かな", 7-12 " world"). Ask the actually-rendered (composed)
      // `CTLine` for that index's own X position rather than guessing a
      // pixel value, so the test doesn't depend on font-metric assumptions
      // beyond what `hitTestOffset` itself already relies on.
      guard let (_, ctLine) = h.view.renderedLine(at: TextLineIndex(0)) else {
        return XCTFail("expected a rendered composing line")
      }
      let composedLocalIndex = 10
      let x = CTLineGetOffsetForStringIndex(ctLine, composedLocalIndex, nil)

      guard let offset = h.view.hitTestOffset(at: CGPoint(x: x + h.view.textInset, y: 5)) else {
        return XCTFail("expected a hit-test offset")
      }

      // The correct buffer offset for composed-local index 10 is buffer
      // column 8 ("hello wo|rld") — the 2-UTF-16-unit composed splice
      // subtracted back out. Before the fix this instead treated 10 as a
      // raw buffer column, landing inside "rld" one character later than
      // the user actually touched.
      XCTAssertEqual(offset, UTF8Offset(8))
    }

    func testClosestPositionToPointRoundTripsThroughUITextInput() throws {
      let h = try harness("abcdef")
      try renderOffscreen(h.view)

      guard let bufferOffset = h.view.hitTestOffset(at: CGPoint(x: 0, y: 5)) else {
        return XCTFail("expected a hit-test offset")
      }
      guard let position = h.view.closestPosition(to: CGPoint(x: 0, y: 5)) as? EditorTextPosition
      else {
        return XCTFail("expected a UITextInput position")
      }
      XCTAssertEqual(position.offset, bufferOffset)
    }

    func testCharacterRangeAtPointCoversOneGraphemeCluster() throws {
      // "é" is "e" + U+0301 COMBINING ACUTE ACCENT: two scalars, one
      // grapheme cluster (`INV-COORD-004`), so a touch landing anywhere on
      // it must select the whole cluster, never split it.
      let combining = "e\u{0301}"
      let h = try harness("caf" + combining)
      try renderOffscreen(h.view)

      guard let range = h.view.characterRange(at: CGPoint(x: 0, y: 5)) as? EditorTextRange
      else {
        return XCTFail("expected a UITextInput range")
      }
      let text = try h.manager.buffer.snapshot.text(in: range.range)
      XCTAssertEqual(text.count, 1, "must not split a grapheme cluster")
    }

    // MARK: - Selection through `selectedTextRange`

    func testSelectedTextRangeGetSetRoundTrips() throws {
      let h = try harness("hello world")
      h.select(
        try TextSelectionSet([TextSelection(anchor: UTF8Offset(0), head: UTF8Offset(5))]))

      guard let range = h.view.selectedTextRange as? EditorTextRange else {
        return XCTFail("expected a selected range")
      }
      XCTAssertEqual(range.range, TextUTF8Range(UTF8Offset(0), UTF8Offset(5)))

      h.view.selectedTextRange = EditorTextRange(
        TextUTF8Range(UTF8Offset(6), UTF8Offset(11)))
      XCTAssertEqual(
        h.manager.selection.selections, [TextSelection(anchor: UTF8Offset(6), head: UTF8Offset(11))]
      )
    }

    // MARK: - Position / range arithmetic (`UITextInput`)

    func testPositionFromOffsetStepsByGraphemeClusterNotScalar() throws {
      let combining = "e\u{0301}"
      let h = try harness("caf" + combining + "z")
      let start = EditorTextPosition(UTF8Offset(3))  // just before the combining "é"

      guard let next = h.view.position(from: start, offset: 1) as? EditorTextPosition else {
        return XCTFail("expected a position")
      }
      // One grapheme step lands past the whole combining sequence (3 UTF-8
      // bytes: "e" + U+0301's 2-byte encoding), not mid-scalar.
      XCTAssertEqual(next.offset, UTF8Offset(6))
    }

    func testOffsetFromToMatchesPositionFromOffset() throws {
      let h = try harness("abcdef")
      let start = EditorTextPosition(UTF8Offset(0))
      let end = EditorTextPosition(UTF8Offset(4))
      XCTAssertEqual(h.view.offset(from: start, to: end), 4)
    }

    func testCompareOrdersPositionsByOffset() throws {
      let h = try harness("abcdef")
      let a = EditorTextPosition(UTF8Offset(1))
      let b = EditorTextPosition(UTF8Offset(4))
      XCTAssertEqual(h.view.compare(a, to: b), .orderedAscending)
      XCTAssertEqual(h.view.compare(b, to: a), .orderedDescending)
      XCTAssertEqual(h.view.compare(a, to: a), .orderedSame)
    }

    func testTextRangeFromToNormalizesOrder() throws {
      let h = try harness("abcdef")
      let a = EditorTextPosition(UTF8Offset(4))
      let b = EditorTextPosition(UTF8Offset(1))
      guard let range = h.view.textRange(from: a, to: b) as? EditorTextRange else {
        return XCTFail("expected a range")
      }
      XCTAssertEqual(range.range, TextUTF8Range(UTF8Offset(1), UTF8Offset(4)))
    }

    // MARK: - Marked text / IME composition (`UITextInput`)

    func testMarkedTextNeverTouchesBufferUntilCommitted() throws {
      let h = try harness("hello")
      h.view.setMarkedText("ｎ", selectedRange: NSRange(location: 1, length: 0))

      XCTAssertNotNil(h.view.markedTextRange)
      // INV-UNDO-003: not undoable while marked, and the buffer itself is
      // untouched — only the view's overlay knows about the composition.
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "hello")
      XCTAssertFalse(h.manager.canUndo)

      h.view.unmarkText()

      XCTAssertNil(h.view.markedTextRange)
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "ｎhello")
      XCTAssertTrue(h.manager.canUndo)
      _ = try h.manager.undo()
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "hello")
    }

    func testInsertTextWhileComposingCommitsAsOneUndoUnitNotOnePerKeystroke() throws {
      let h = try harness("hello")
      h.view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0))
      h.view.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0))
      h.view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
      XCTAssertEqual(
        h.manager.buffer.snapshot.string(), "hello", "composing must not touch the buffer")

      h.view.insertText("かな")

      XCTAssertEqual(h.manager.buffer.snapshot.string(), "かなhello")
      XCTAssertNil(h.view.markedTextRange)
      _ = try h.manager.undo()
      XCTAssertEqual(
        h.manager.buffer.snapshot.string(), "hello", "one Undo removes the whole composition")
    }

    func testEmptyMarkedTextCancelsCompositionWithoutCommitting() throws {
      let h = try harness("hello")
      h.view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
      XCTAssertNotNil(h.view.markedTextRange)

      h.view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))

      XCTAssertNil(h.view.markedTextRange)
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "hello")
      XCTAssertFalse(h.manager.canUndo)
    }

    func testComposingLineRendersWithoutCrashing() throws {
      let h = try harness("first\nsecond\nthird")
      h.select(TextSelectionSet(cursor: UTF8Offset(6)))
      h.view.setMarkedText("ｓ", selectedRange: NSRange(location: 1, length: 0))
      try renderOffscreen(h.view)
    }

    // MARK: - Hardware keyboard (`doCommand`-equivalent selectors)

    func testDeleteBackwardRemovesOneGraphemeNotOneScalar() throws {
      let combining = "e\u{0301}"
      let h = try harness("caf" + combining)
      h.select(TextSelectionSet(cursor: UTF8Offset(h.manager.buffer.snapshot.utf8Count)))

      h.view.deleteBackward()

      XCTAssertEqual(h.manager.buffer.snapshot.string(), "caf")
    }

    func testMultiCursorDeleteBackwardIsOneCommitCallCoveringEveryCursor() throws {
      let h = try harness("aXbXc")
      h.select(
        try TextSelectionSet([
          TextSelection(cursor: UTF8Offset(2)), TextSelection(cursor: UTF8Offset(4)),
        ]))
      var commits = 0
      let existingHandler = h.view.onCommitEdits
      h.view.onCommitEdits = { edits in
        commits += 1
        existingHandler?(edits)
      }

      h.view.deleteBackward()

      XCTAssertEqual(commits, 1)
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "abc")
    }

    func testInsertTextCommitsOneEditPerCursorAsOneUndoUnit() throws {
      let h = try harness("ab\ncd")
      let firstCursor = TextSelection(cursor: UTF8Offset(0))
      let secondCursor = TextSelection(cursor: UTF8Offset(5))
      h.select(try TextSelectionSet([firstCursor, secondCursor]))

      h.view.insertText("X")

      XCTAssertEqual(h.manager.buffer.snapshot.string(), "Xab\ncdX")
      XCTAssertTrue(h.manager.canUndo)
      _ = try h.manager.undo()
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "ab\ncd")
    }

    // MARK: - Clipboard (`UIResponderStandardEditActions`)

    func testCopyWritesSelectionToPasteboard() throws {
      let h = try harness("hello world")
      h.select(try TextSelectionSet([TextSelection(anchor: UTF8Offset(0), head: UTF8Offset(5))]))

      h.view.copy(nil)

      XCTAssertEqual(UIPasteboard.general.string, "hello")
    }

    func testPasteInsertsPasteboardStringAtEachCursor() throws {
      let h = try harness("()")
      UIPasteboard.general.string = "mid"
      h.select(TextSelectionSet(cursor: UTF8Offset(1)))

      h.view.paste(nil)

      XCTAssertEqual(h.manager.buffer.snapshot.string(), "(mid)")
    }
  }
#endif

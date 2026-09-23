#if os(macOS)
  import AppKit
  import XCTest

  @testable import ClairEditorCore
  @testable import ClairEditorView

  final class EditorViewGeometryTests: XCTestCase {
    func testVisibleLineRangeCoversOnlyIntersectingLines() {
      let range = EditorViewGeometry.visibleLineRange(
        visibleRect: CGRect(x: 0, y: 100, width: 400, height: 50), lineHeight: 20, lineCount: 1000)
      // rows 5 (100...119) through 7 (140...159) intersect y in [100, 150).
      XCTAssertEqual(range, 5..<8)
    }

    func testVisibleLineRangeClampsToDocumentBounds() {
      // Rect spans y in [-20, 30): row 0 [0, 20) fully, row 1 [20, 40)
      // partially. Negative minY clamps to row 0 instead of underflowing.
      let range = EditorViewGeometry.visibleLineRange(
        visibleRect: CGRect(x: 0, y: -20, width: 400, height: 50), lineHeight: 20, lineCount: 3)
      XCTAssertEqual(range, 0..<2)
    }

    func testVisibleLineRangeEmptyForEmptyDocument() {
      let range = EditorViewGeometry.visibleLineRange(
        visibleRect: CGRect(x: 0, y: 0, width: 400, height: 400), lineHeight: 20, lineCount: 0)
      XCTAssertTrue(range.isEmpty)
    }

    func testLineIndexAtYClampsNegativeAndOverflow() {
      XCTAssertEqual(EditorViewGeometry.lineIndex(atY: -50, lineHeight: 20, lineCount: 10), 0)
      XCTAssertEqual(EditorViewGeometry.lineIndex(atY: 10_000, lineHeight: 20, lineCount: 10), 9)
      XCTAssertEqual(EditorViewGeometry.lineIndex(atY: 45, lineHeight: 20, lineCount: 10), 2)
    }
  }

  @MainActor
  final class ClairEditorViewTests: XCTestCase {
    private func snapshot(_ text: String) throws -> TextSnapshot {
      try TextBuffer(text).snapshot
    }

    private func makeView(_ text: String) throws -> ClairEditorView {
      let snap = try snapshot(text)
      return ClairEditorView(snapshot: snap, selection: TextSelectionSet(cursor: UTF8Offset(0)))
    }

    /// A layer-backed offscreen bitmap context, so `draw(_:)` runs through
    /// its real CoreText path (line layout, hit-test-relevant metrics,
    /// selection/caret/diagnostic overlays) without needing an on-screen
    /// window — the one runnable check that the rendering path does not
    /// crash and actually paints something for a non-trivial document.
    private func renderOffscreen(
      _ view: ClairEditorView, size: NSSize = NSSize(width: 400, height: 200)
    )
      throws
    {
      view.setFrameSize(size)
      let rep = try XCTUnwrap(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
      let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      defer { NSGraphicsContext.restoreGraphicsState() }
      view.draw(NSRect(origin: .zero, size: size))
    }

    func testDrawDoesNotCrashAndSizesFrameToLineCount() throws {
      let text = (0..<50).map { "line \($0) hello world" }.joined(separator: "\n")
      let view = try makeView(text)
      try renderOffscreen(view)
      // Height tracks line count exactly (no eager full-document layout is
      // needed to know this — it's arithmetic, not measurement).
      XCTAssertEqual(
        view.frame.height, CGFloat((try snapshot(text)).lineCount) * view.lineHeight, accuracy: 0.01
      )
    }

    func testHitTestRoundTripsToClickedCharacter() throws {
      let text = "hello world\nsecond line"
      let view = try makeView(text)
      try renderOffscreen(view)

      // Land inside the first line, well before its end.
      guard let offset = view.hitTestOffset(at: NSPoint(x: 5, y: 5)) else {
        return XCTFail("expected a hit-test offset")
      }
      let position = try snapshot(text).position(at: offset, columnUnit: UTF8Unit.self)
      XCTAssertEqual(position.line.value, 0)
    }

    func testHitTestSecondLineReturnsSecondLineOffset() throws {
      let text = "hello world\nsecond line"
      let view = try makeView(text)
      try renderOffscreen(view)

      guard let offset = view.hitTestOffset(at: NSPoint(x: 5, y: 20)) else {
        return XCTFail("expected a hit-test offset")
      }
      let position = try snapshot(text).position(at: offset, columnUnit: UTF8Unit.self)
      XCTAssertEqual(position.line.value, 1)
    }

    func testMouseDownSetsCursorSelectionAtHitOffset() throws {
      let text = "abcdef"
      let view = try makeView(text)
      try renderOffscreen(view)
      var reported: TextSelectionSet?
      view.onSelectionChange = { reported = $0 }

      let point = NSPoint(x: 0, y: 5)
      guard let expected = view.hitTestOffset(at: point) else {
        return XCTFail("expected a hit-test offset")
      }
      let event = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      view.mouseDown(with: event)

      XCTAssertEqual(view.selection.selections, [TextSelection(cursor: expected)])
      XCTAssertEqual(reported?.selections, [TextSelection(cursor: expected)])
    }

    func testApplyEditsInvalidatesOnlyTouchedLineAndTracksNewSnapshot() throws {
      let buffer = try TextBuffer("first\nsecond\nthird")
      let view = ClairEditorView(
        snapshot: buffer.snapshot, selection: TextSelectionSet(cursor: UTF8Offset(0)))
      try renderOffscreen(view)

      let old = buffer.snapshot
      let edit = TextEdit(range: TextUTF8Range(UTF8Offset(0), UTF8Offset(5)), replacement: "FIRST")
      try buffer.replace(edit.range, with: edit.replacement, basedOn: old.revision)
      let new = buffer.snapshot

      view.applyEdits(
        [edit], oldSnapshot: old, newSnapshot: new,
        selection: TextSelectionSet(cursor: UTF8Offset(0)))
      try renderOffscreen(view)

      XCTAssertEqual(view.snapshot.string(), "FIRST\nsecond\nthird")
    }

    func testHighlightAndDiagnosticSpansDoNotCrashRendering() throws {
      let text = #"{"a": 1}"#
      let view = try makeView(text)
      view.highlights = [
        EditorHighlightSpan(
          range: TextUTF8Range(UTF8Offset(1), UTF8Offset(4)), kind: .string)
      ]
      view.diagnostics = [
        EditorDiagnosticSpan(
          range: TextUTF8Range(UTF8Offset(6), UTF8Offset(7)), severity: .error)
      ]
      try renderOffscreen(view)
    }
  }

  // MARK: - E07: NSTextInputClient / IME, editing, clipboard, drag/drop, accessibility

  /// Wires a `ClairEditorView` to a real `EditorTransactionManager` the way
  /// a host is expected to (`onCommitEdits` -> `apply` -> `applyEdits`;
  /// `onSelectionChange` -> `setSelection`), so E07's tests exercise the
  /// same round trip a real app would, not the view in isolation.
  @MainActor
  private final class EditingHarness {
    let manager: EditorTransactionManager
    let view: ClairEditorView

    init(_ text: String) throws {
      let buffer = try TextBuffer(text)
      let manager = EditorTransactionManager(
        buffer: buffer, selection: TextSelectionSet(cursor: UTF8Offset(0)))
      let view = ClairEditorView(snapshot: buffer.snapshot, selection: manager.selection)
      view.pasteboard = NSPasteboard(name: NSPasteboard.Name("clair-test-\(UUID().uuidString)"))
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

    /// Test-only convenience: a real host only ever changes `view.selection`
    /// through a view gesture that also fires `onSelectionChange` (mouse,
    /// `doCommand`, `setAccessibilitySelectedTextRange`, …), which keeps
    /// `manager.selection` in sync. Tests that set up a precondition
    /// selection bypass that gesture, so they must sync both sides
    /// themselves — exactly what a real `apply` after such a change needs
    /// (`EditorTransactionManager.setSelection`'s doc comment).
    func select(_ selection: TextSelectionSet) {
      view.selection = selection
      manager.setSelection(selection)
    }
  }

  @MainActor
  final class ClairEditorViewTextInputTests: XCTestCase {
    private func harness(_ text: String) throws -> EditingHarness { try EditingHarness(text) }

    // MARK: NSTextInputClient / IME

    func testInsertTextCommitsOneEditPerCursorAsOneUndoUnit() throws {
      let h = try harness("ab\ncd")
      let firstCursor = TextSelection(cursor: UTF8Offset(0))
      let secondCursor = TextSelection(cursor: UTF8Offset(5))
      h.select(try TextSelectionSet([firstCursor, secondCursor]))

      h.view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

      XCTAssertEqual(h.manager.buffer.snapshot.string(), "Xab\ncdX")
      XCTAssertTrue(h.manager.canUndo)
      _ = try h.manager.undo()
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "ab\ncd")
    }

    func testMarkedTextNeverTouchesBufferUntilCommitted() throws {
      let h = try harness("hello")
      h.view.setMarkedText(
        "ｎ", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))

      XCTAssertTrue(h.view.hasMarkedText())
      // INV-UNDO-003: not undoable while marked, and the buffer itself is
      // untouched — only the view's overlay knows about the composition.
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "hello")
      XCTAssertFalse(h.manager.canUndo)

      h.view.unmarkText()

      XCTAssertFalse(h.view.hasMarkedText())
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "ｎhello")
      XCTAssertTrue(h.manager.canUndo)
      _ = try h.manager.undo()
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "hello")
    }

    func testInsertTextWhileComposingCommitsAsOneUndoUnitNotOnePerKeystroke() throws {
      let h = try harness("hello")
      let notFound = NSRange(location: NSNotFound, length: 0)
      h.view.setMarkedText(
        "k", selectedRange: NSRange(location: 1, length: 0), replacementRange: notFound)
      h.view.setMarkedText(
        "ka", selectedRange: NSRange(location: 2, length: 0), replacementRange: notFound)
      h.view.setMarkedText(
        "かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: notFound)
      XCTAssertEqual(
        h.manager.buffer.snapshot.string(), "hello", "composing must not touch the buffer")

      h.view.insertText("かな", replacementRange: notFound)

      XCTAssertEqual(h.manager.buffer.snapshot.string(), "かなhello")
      XCTAssertFalse(h.view.hasMarkedText())
      _ = try h.manager.undo()
      XCTAssertEqual(
        h.manager.buffer.snapshot.string(), "hello", "one Undo removes the whole composition")
    }

    func testEmptyMarkedTextCancelsCompositionWithoutCommitting() throws {
      let h = try harness("hello")
      h.view.setMarkedText(
        "n", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertTrue(h.view.hasMarkedText())

      h.view.setMarkedText(
        "", selectedRange: NSRange(location: 0, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))

      XCTAssertFalse(h.view.hasMarkedText())
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "hello")
      XCTAssertFalse(h.manager.canUndo)
    }

    func testComposingLineRendersWithoutCrashing() throws {
      let h = try harness("first\nsecond\nthird")
      h.select(TextSelectionSet(cursor: UTF8Offset(6)))
      h.view.setMarkedText(
        "ｓ", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))

      h.view.setFrameSize(NSSize(width: 400, height: 200))
      let rep = try XCTUnwrap(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0))
      let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      defer { NSGraphicsContext.restoreGraphicsState() }
      h.view.draw(NSRect(x: 0, y: 0, width: 400, height: 200))
    }

    func testSelectedRangeAndMarkedRangeAreLocalToTheComposingLineNotTheDocument() throws {
      // The composition sits on line 1 ("second"), not line 0 — proves the
      // reported ranges are line-local (INV-INPUT-001), since a document-
      // wide UTF-16 offset for this anchor would be 6 + 1, not 1.
      let h = try harness("first\nsecond\nthird")
      h.select(TextSelectionSet(cursor: UTF8Offset(6)))
      h.view.setMarkedText(
        "ｓ", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))

      XCTAssertEqual(h.view.markedRange(), NSRange(location: 0, length: 1))
      XCTAssertEqual(h.view.selectedRange(), NSRange(location: 1, length: 0))
    }

    // MARK: doCommand(by:) editing

    func testDeleteBackwardRemovesOneGraphemeNotOneScalar() throws {
      // "é" here is "e" + U+0301 COMBINING ACUTE ACCENT: two scalars, one
      // grapheme cluster (INV-COORD-004).
      let combining = "e\u{0301}"
      let h = try harness("caf" + combining)
      h.select(TextSelectionSet(cursor: UTF8Offset(h.manager.buffer.snapshot.utf8Count)))

      h.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

      XCTAssertEqual(h.manager.buffer.snapshot.string(), "caf")
    }

    func testDeleteForwardOnNonEmptySelectionDeletesWholeSelectionNotOneGrapheme() throws {
      let h = try harness("abcdef")
      h.select(
        try TextSelectionSet([
          TextSelection(anchor: UTF8Offset(1), head: UTF8Offset(4))
        ]))

      h.view.doCommand(by: #selector(NSResponder.deleteForward(_:)))

      XCTAssertEqual(h.manager.buffer.snapshot.string(), "aef")
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

      h.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

      XCTAssertEqual(commits, 1)
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "abc")
    }

    func testMoveRightOnNonEmptySelectionCollapsesToUpperBoundInstantOfMoving() throws {
      let h = try harness("abcdef")
      h.select(
        try TextSelectionSet([
          TextSelection(anchor: UTF8Offset(1), head: UTF8Offset(4))
        ]))

      h.view.doCommand(by: #selector(NSResponder.moveRight(_:)))

      XCTAssertEqual(h.view.selection.selections, [TextSelection(cursor: UTF8Offset(4))])
    }

    func testInsertNewlineAndInsertTabCommitLiteralCharacters() throws {
      let h = try harness("ab")
      h.select(TextSelectionSet(cursor: UTF8Offset(1)))
      h.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "a\nb")
      h.view.doCommand(by: #selector(NSResponder.insertTab(_:)))
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "a\n\tb")
    }

    // MARK: Clipboard

    func testCopyWritesOnlyThePlainStringPasteboardRepresentation() throws {
      let h = try harness("hello world")
      h.select(
        try TextSelectionSet([
          TextSelection(anchor: UTF8Offset(0), head: UTF8Offset(5))
        ]))

      h.view.copy(nil)

      let pasteboard = h.view.pasteboard
      XCTAssertEqual(pasteboard.string(forType: .string), "hello")
      // `NSPasteboard` itself declares the legacy `NSStringPboardType` alias
      // for any `.string` write; the invariant this proves is that *we*
      // never separately declare a second, richer representation (RTF/HTML)
      // that could drift from the plain-text one.
      XCTAssertNil(pasteboard.data(forType: .rtf))
      XCTAssertNil(pasteboard.data(forType: .html))
    }

    func testCutDeletesSelectionAfterWritingToPasteboard() throws {
      let h = try harness("hello world")
      h.select(
        try TextSelectionSet([
          TextSelection(anchor: UTF8Offset(0), head: UTF8Offset(6))
        ]))

      h.view.cut(nil)

      XCTAssertEqual(h.view.pasteboard.string(forType: .string), "hello ")
      XCTAssertEqual(h.manager.buffer.snapshot.string(), "world")
    }

    func testPasteInsertsPasteboardStringAtEachCursor() throws {
      let h = try harness("()")
      h.view.pasteboard.clearContents()
      h.view.pasteboard.setString("mid", forType: .string)
      h.select(TextSelectionSet(cursor: UTF8Offset(1)))

      h.view.paste(nil)

      XCTAssertEqual(h.manager.buffer.snapshot.string(), "(mid)")
    }

    // MARK: Drag / drop

    func testDropEditsInsertsAtOffsetWithNoSourceRangesForAnExternalDrop() {
      let edits = ClairEditorView.dropEdits(
        inserting: "hi", at: UTF8Offset(3), movingFrom: [])
      XCTAssertEqual(
        edits, [TextEdit(range: TextUTF8Range(UTF8Offset(3), UTF8Offset(3)), replacement: "hi")])
    }

    func testDropEditsForInternalMoveDeletesSourceAndInsertsAsOneBatch() {
      let sourceRange = TextUTF8Range(UTF8Offset(0), UTF8Offset(3))
      let edits = ClairEditorView.dropEdits(
        inserting: "abc", at: UTF8Offset(8), movingFrom: [sourceRange])
      XCTAssertEqual(
        edits,
        [
          TextEdit(range: TextUTF8Range(UTF8Offset(8), UTF8Offset(8)), replacement: "abc"),
          TextEdit(range: sourceRange, replacement: ""),
        ])
    }

    func testDropEditsRejectsDroppingInsideTheSourceRangeBeingMoved() {
      let sourceRange = TextUTF8Range(UTF8Offset(2), UTF8Offset(6))
      XCTAssertNil(
        ClairEditorView.dropEdits(inserting: "abc", at: UTF8Offset(4), movingFrom: [sourceRange]))
    }

    // MARK: Accessibility

    func testAccessibilityValueReturnsFullDocumentText() throws {
      let h = try harness("hello\nworld")
      XCTAssertEqual(h.view.accessibilityValue() as? String, "hello\nworld")
      XCTAssertEqual(h.view.accessibilityNumberOfCharacters(), 11)
    }

    func testAccessibilitySelectedTextRangeIsDocumentWideUTF16NotLineLocal() throws {
      // Contrast with `INV-INPUT-001`: accessibility ranges are ordinary
      // document-wide UTF-16 offsets (INV-INPUT-008), unlike
      // `NSTextInputClient`'s line-local ones.
      let h = try harness("first\nsecond")
      h.select(
        try TextSelectionSet([
          TextSelection(anchor: UTF8Offset(6), head: UTF8Offset(9))
        ]))
      XCTAssertEqual(h.view.accessibilitySelectedTextRange(), NSRange(location: 6, length: 3))
      XCTAssertEqual(h.view.accessibilitySelectedText(), "sec")
    }

    func testSetAccessibilitySelectedTextRangeUpdatesSelection() throws {
      let h = try harness("hello world")
      h.view.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 5))
      XCTAssertEqual(
        h.view.selection.selections,
        [TextSelection(anchor: UTF8Offset(6), head: UTF8Offset(11))])
    }

    func testAccessibilityVisibleCharacterRangeMatchesVisibleLines() throws {
      let h = try harness((0..<50).map { "line \($0)" }.joined(separator: "\n"))
      h.view.setFrameSize(NSSize(width: 400, height: 200))
      let range = h.view.accessibilityVisibleCharacterRange()
      XCTAssertEqual(range.location, 0)
      XCTAssertGreaterThan(range.length, 0)
      XCTAssertLessThan(range.length, h.view.accessibilityNumberOfCharacters())
    }
  }
#endif

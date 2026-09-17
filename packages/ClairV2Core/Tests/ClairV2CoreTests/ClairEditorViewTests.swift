#if os(macOS)
  import AppKit
  import XCTest

  @testable import ClairV2EditorCore
  @testable import ClairV2EditorView

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
#endif

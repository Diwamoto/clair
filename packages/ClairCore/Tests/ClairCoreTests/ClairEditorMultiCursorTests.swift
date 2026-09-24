#if os(macOS)
  import AppKit
  import XCTest
  import ClairEditorFixtures

  @testable import ClairAppKit
  @testable import ClairEditorCore
  @testable import ClairEditorView

  /// E14: multi-cursor gestures driven through the real mouse handlers.
  @MainActor final class ClairEditorMultiCursorTests: XCTestCase {
    private func makeView(_ text: String) throws -> ClairEditorView {
      let view = ClairEditorView(
        snapshot: try TextBuffer(text).snapshot, selection: TextSelectionSet(cursor: UTF8Offset(0)))
      view.setFrameSize(NSSize(width: 400, height: 200))
      return view
    }

    /// The x of the caret boundary before UTF-16 `column` on `line`, from the view's own CoreText layout.
    private func x(_ view: ClairEditorView, line: Int, column: Int) throws -> CGFloat {
      let (_, ct) = try view.renderer.line(
        at: TextLineIndex(line), in: view.snapshot, highlights: view.highlightIndex, colorOverrides: [:])
      return view.textInset + CTLineGetOffsetForStringIndex(ct, column, nil)
    }

    private func y(_ view: ClairEditorView, line: Int) -> CGFloat {
      (CGFloat(line) + 0.5) * view.lineHeight
    }

    private func mouse(
      _ view: ClairEditorView, _ type: NSEvent.EventType, _ point: NSPoint,
      clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) throws {
      let event = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks,
          pressure: 1))
      switch type {
      case .leftMouseDown: view.mouseDown(with: event)
      case .leftMouseDragged: view.mouseDragged(with: event)
      default: view.mouseUp(with: event)
      }
    }

    private func ranges(_ view: ClairEditorView) -> [ClosedRange<Int>] {
      view.selection.selections.map { $0.range.lowerBound.value...$0.range.upperBound.value }
    }

    private func arrow(_ view: ClairEditorView, up: Bool) throws {
      let event = try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [.command, .option, .function, .numericPad],
        timestamp: 0, windowNumber: 0, context: nil,
        characters: up ? "\u{F700}" : "\u{F701}",
        charactersIgnoringModifiers: up ? "\u{F700}" : "\u{F701}",
        isARepeat: false, keyCode: up ? 126 : 125))
      view.keyDown(with: event)
    }

    private func escape(_ view: ClairEditorView) throws {
      let event = try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
      view.keyDown(with: event)
    }

    func testEscapeCollapsesMultipleCursorsAfterCompletionGetsFirstChance() throws {
      let view = try makeView("one\ntwo\nthree")
      try arrow(view, up: false)
      try arrow(view, up: false)
      XCTAssertEqual(ranges(view), [0...0, 4...4, 8...8])

      var completionOpen = true
      view.keyInterceptor = { event in
        guard event.keyCode == 53, completionOpen else { return false }
        completionOpen = false
        return true
      }
      try escape(view)
      XCTAssertEqual(ranges(view), [0...0, 4...4, 8...8])
      try escape(view)
      XCTAssertEqual(ranges(view), [8...8])
    }

    func testCommandOptionArrowsGrowCursorsAcrossRaggedLines() throws {
      let view = try makeView("abcd\na\nabcd")
      view.selection = TextSelectionSet(cursor: UTF8Offset(3))
      try arrow(view, up: false)
      XCTAssertEqual(ranges(view), [3...3, 6...6])
      try arrow(view, up: false)
      XCTAssertEqual(ranges(view), [3...3, 6...6, 10...10])
      try arrow(view, up: false) // document edge: no extra caret
      XCTAssertEqual(ranges(view), [3...3, 6...6, 10...10])
      try arrow(view, up: true) // top edge: no extra caret
      XCTAssertEqual(ranges(view), [3...3, 6...6, 10...10])

      view.selection = TextSelectionSet(cursor: UTF8Offset(8))
      try arrow(view, up: true)
      try arrow(view, up: true)
      XCTAssertEqual(ranges(view), [1...1, 6...6, 8...8])
    }

    func testCommandOptionArrowKeyEquivalentReachesFocusedEditor() throws {
      let view = try makeView("one\ntwo")
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.contentView = view
      XCTAssertTrue(window.makeFirstResponder(view))
      let event = try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [.command, .option, .function, .numericPad],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
        isARepeat: false, keyCode: 125))
      XCTAssertTrue(view.performKeyEquivalent(with: event))
      XCTAssertEqual(ranges(view), [0...0, 4...4])
    }

    func testDoubleClickSelectsWordAndTripleClickSelectsLine() throws {
      let view = try makeView("foo bar_baz qux\nnext")
      let inWord = NSPoint(x: try x(view, line: 0, column: 6) + 1, y: y(view, line: 0))
      try mouse(view, .leftMouseDown, inWord, clicks: 2)
      try mouse(view, .leftMouseUp, inWord, clicks: 2)
      XCTAssertEqual(ranges(view), [4...11])  // "bar_baz", AppKit's word rule

      try mouse(view, .leftMouseDown, inWord, clicks: 3)
      XCTAssertEqual(ranges(view), [0...16])  // content plus its newline

      // ⌘ keeps what was selected, like ⌘-click.
      let inFoo = NSPoint(x: try x(view, line: 0, column: 1) + 1, y: y(view, line: 0))
      let inQux = NSPoint(x: try x(view, line: 0, column: 13) + 1, y: y(view, line: 0))
      try mouse(view, .leftMouseDown, inFoo, clicks: 2)
      try mouse(view, .leftMouseDown, inQux, clicks: 2, modifiers: .command)
      XCTAssertEqual(ranges(view), [0...3, 12...15])
    }

    func testOptionDragSelectsTheSamePixelColumnsOnEveryLine() throws {
      let view = try makeView("abcdef\nab\nabcdef")
      // From inside "b" to inside "d": the left edge snaps down, the right edge up.
      let start = NSPoint(x: try x(view, line: 0, column: 1) + 2, y: y(view, line: 0))
      let end = NSPoint(x: try x(view, line: 0, column: 3) + 2, y: y(view, line: 2))
      try mouse(view, .leftMouseDown, start, modifiers: .option)
      try mouse(view, .leftMouseDragged, end, modifiers: .option)
      try mouse(view, .leftMouseUp, end, modifiers: .option)
      // Line 1 ("ab") is shorter than the block: from column 1 to its end.
      XCTAssertEqual(ranges(view), [1...4, 8...9, 11...14])
      XCTAssertTrue(view.selection.selections.allSatisfy { $0.head.value > $0.anchor.value })
    }

    func testBlockEdgesInsideAFullWidthGlyphTakeTheWholeGlyph() throws {
      let view = try makeView("あいう\nabcdef")
      // Both edges fall inside a glyph: "あ" (3 bytes) and "い" are taken whole.
      let start = NSPoint(x: try x(view, line: 0, column: 0) + 2, y: y(view, line: 0))
      let end = NSPoint(x: try x(view, line: 0, column: 1) + 2, y: y(view, line: 0))
      try mouse(view, .leftMouseDown, start, modifiers: .option)
      try mouse(view, .leftMouseDragged, end, modifiers: .option)
      XCTAssertEqual(ranges(view), [0...6])
    }

    func testCommandDSelectsWordThenAddsNextOccurrencesAndWraps() throws {
      let view = try makeView("foo x foo y foo")
      view.selection = TextSelectionSet(cursor: UTF8Offset(7))
      view.selectNextOccurrence()
      XCTAssertEqual(ranges(view), [6...9])
      view.selectNextOccurrence()
      XCTAssertEqual(ranges(view), [6...9, 12...15])
      view.selectNextOccurrence()  // wraps to the top
      XCTAssertEqual(ranges(view), [0...3, 6...9, 12...15])
      view.selectNextOccurrence()  // every occurrence taken: no change
      XCTAssertEqual(ranges(view), [0...3, 6...9, 12...15])
    }

    /// Spec §5.9: the UI file-size limit must open the canonical `10mb` fixture.
    func testEditorLimitOpensTheCanonicalTenMegabyteFixture() throws {
      let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: dir) }
      let fixture = try XCTUnwrap(
        EditorFixtureGenerator.canonicalFixtures.first { $0.name == "10mb" })
      let url = try EditorFixtureGenerator.generate(fixture, into: dir)
      let size = try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
      XCTAssertGreaterThan(size, 10 * 1024 * 1024, "written in whole lines, it overshoots 10 MiB")
      XCTAssertLessThanOrEqual(size, EditorBuffers.maxBytes)
    }
  }
#endif

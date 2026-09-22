import ClairEditorCore

#if os(macOS)
  import AppKit
  import CoreText

  /// E12: the view-side hooks the language-server wiring needs — the
  /// diagnostic message under the pointer, and where the primary caret is so
  /// a completion list can sit under it. Everything LSP-specific stays in the
  /// host; this view only knows `EditorDiagnosticSpan`.
  extension ClairEditorView {
    public override func updateTrackingAreas() {
      super.updateTrackingAreas()
      for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
      addTrackingArea(
        NSTrackingArea(
          rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// AppKit shows `toolTip` after its own hover delay, so swapping it as the
    /// pointer moves is all a per-underline tooltip needs.
    public override func mouseMoved(with event: NSEvent) {
      super.mouseMoved(with: event)
      let message = diagnosticMessage(at: convert(event.locationInWindow, from: nil))
      if toolTip != message { toolTip = message }
    }

    /// Every diagnostic message whose range covers the point, one per line.
    public func diagnosticMessage(at point: NSPoint) -> String? {
      guard !diagnostics.isEmpty, let offset = hitTestOffset(at: point) else { return nil }
      let hits = diagnostics.filter {
        $0.range.lowerBound.value <= offset.value && offset.value <= $0.range.upperBound.value
          && !$0.message.isEmpty
      }
      return hits.isEmpty ? nil : hits.map(\.message).joined(separator: "\n")
    }

    /// The primary caret's rect in this view's (flipped) coordinates.
    public func primaryCaretRect() -> NSRect? {
      guard let head = selection.selections.last?.head,
        let position = try? snapshot.position(at: head, columnUnit: UTF16Unit.self, rounding: .down),
        let (_, ctLine) = try? renderer.line(
          at: position.line, in: snapshot, highlights: highlights, colorOverrides: tokenColors)
      else { return nil }
      let x = CTLineGetOffsetForStringIndex(ctLine, position.column.value, nil)
      return NSRect(
        x: textInset + x, y: CGFloat(position.line.value) * lineHeight, width: 1, height: lineHeight)
    }

    /// Moves the caret to `line`/`utf16Column` (0-based, clamped) and scrolls there.
    public func reveal(line: Int, utf16Column: Int) {
      reveal(line: line)
      let i = min(max(line, 0), snapshot.lineCount - 1)
      guard utf16Column > 0,
        let offset = try? snapshot.offset(
          at: TextLinePosition<UTF16Unit>(line: TextLineIndex(i), column: UTF16Offset(utf16Column)),
          rounding: .down)
      else { return }
      selection = TextSelectionSet(cursor: offset)
      onSelectionChange?(selection)
      needsDisplay = true
    }
  }
#endif

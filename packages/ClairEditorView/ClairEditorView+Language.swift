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
      let point = convert(event.locationInWindow, from: nil)
      let message = diagnosticMessage(at: point)
      if toolTip != message { toolTip = message }
      updateDefinitionHover(at: point, flags: event.modifierFlags)
    }

    public override func flagsChanged(with event: NSEvent) {
      super.flagsChanged(with: event)
      guard let window else { return }
      updateDefinitionHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), flags: event.modifierFlags)
    }

    /// E17: exactly ⌘ (or, with `command: false`, no modifier) among ⌘⌥⌃⇧.
    func isCommandOnly(_ flags: NSEvent.ModifierFlags, command: Bool = true) -> Bool {
      flags.intersection([.command, .option, .control, .shift]) == (command ? .command : [])
    }

    /// Reports the word under a ⌘-held pointer once per word; the link itself waits for the host.
    private func updateDefinitionHover(at point: NSPoint, flags: NSEvent.ModifierFlags) {
      guard onDefinitionHover != nil else { return }
      var word: TextUTF8Range?
      if isCommandOnly(flags), bounds.contains(point), let offset = hitTestOffset(at: point), let w = wordRange(at: offset),
        w.lowerBound != w.upperBound { word = w }
      guard word != definitionHover else { return }
      definitionHover = word
      definitionLink = nil
      onDefinitionHover?(word)
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
      guard let head = selection.selections.last?.head else { return nil }
      return caretRect(for: head)
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

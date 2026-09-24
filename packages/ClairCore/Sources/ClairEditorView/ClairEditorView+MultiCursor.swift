import ClairEditorCore

#if os(macOS)
  import AppKit

  /// E14: the multi-cursor gestures of spec §5.5 on top of the core
  /// `TextSelectionSet` — double/triple-click word/line selection, ⌥-drag
  /// block selection, and ⌘D add-next-occurrence. Selection changes are not
  /// edits, so none of these touch the undo history.
  extension ClairEditorView {
    // MARK: - Double / triple click

    /// Selects the word (double click) or the whole line including its
    /// terminator (triple click) around `offset`. ⌘ keeps the existing
    /// selections, same as ⌘-click adds a cursor.
    ///
    /// ponytail: dragging after a double click extends by characters, not
    /// whole words; add word-granular extension if the product asks.
    func selectUnit(at offset: UTF8Offset, wholeLine: Bool, adding: Bool) {
      guard let range = wholeLine ? lineRange(at: offset) : wordRange(at: offset),
        let updated = try? TextSelectionSet(
          (adding ? selection.selections : [])
            + [TextSelection(anchor: range.lowerBound, head: range.upperBound)])
      else { return }
      dragAnchor = nil
      applySelection(updated)
    }

    private func lineRange(at offset: UTF8Offset) -> TextUTF8Range? {
      guard let position = try? snapshot.position(at: offset, columnUnit: UTF8Unit.self),
        let line = try? snapshot.line(at: position.line)
      else { return nil }
      return TextUTF8Range(line.contentRange.lowerBound, line.terminatorRange.upperBound)
    }

    /// Word boundaries come from AppKit's own double-click rule
    /// (`NSAttributedString.doubleClick(at:)`), so Clair selects the same
    /// "word" as every other Mac text view, CJK included.
    func wordRange(at offset: UTF8Offset) -> TextUTF8Range? {
      guard let position = try? snapshot.position(at: offset, columnUnit: UTF16Unit.self),
        let line = try? snapshot.line(at: position.line),
        let text = try? snapshot.text(in: line.contentRange)
      else { return nil }
      let string = NSAttributedString(string: text)
      guard string.length > 0 else { return TextUTF8Range(offset, offset) }
      let word = string.doubleClick(at: min(position.column.value, string.length - 1))
      guard
        let lower = try? snapshot.offset(
          at: TextLinePosition(line: line.index, column: UTF16Offset(word.location)),
          rounding: .down),
        let upper = try? snapshot.offset(
          at: TextLinePosition(line: line.index, column: UTF16Offset(NSMaxRange(word))),
          rounding: .up)
      else { return nil }
      return TextUTF8Range(lower, upper)
    }

    // MARK: - ⌥-drag block selection

    /// One selection per line between the anchor and `point`, spanning the
    /// same horizontal pixel range on each line. Using x rather than a
    /// character column is what makes the block visual (`INV-MC-004`): a
    /// full-width glyph or cluster the edge falls inside is taken whole —
    /// the left edge snaps down, the right edge up. Lines shorter than the
    /// block get a cursor at their end.
    ///
    /// ponytail: lays out every spanned line on each drag event; fine for a
    /// screenful, sluggish when a drag spans tens of thousands of lines.
    func updateBlockSelection(to point: NSPoint) {
      guard let anchor = blockAnchor, snapshot.lineCount > 0 else { return }
      // ponytail: rows map to lines, but x is taken on each line's first row;
      // a block across soft-wrapped lines selects by that first row only.
      let first = rowMap.line(atRow: Int((max(anchor.y, 0) / lineHeight).rounded(.down))).line
      let last = rowMap.line(atRow: Int((max(point.y, 0) / lineHeight).rounded(.down))).line
      let left = min(anchor.x, point.x)
      let right = max(anchor.x, point.x)
      let selections = (min(first, last)...max(first, last)).filter { !rowMap.isHidden($0) }.compactMap { index -> TextSelection? in
        guard let low = offset(line: index, x: left, rounding: .down),
          let high = offset(line: index, x: right, rounding: .up)
        else { return nil }
        return point.x >= anchor.x
          ? TextSelection(anchor: low, head: high) : TextSelection(anchor: high, head: low)
      }
      guard let updated = try? TextSelectionSet(selections) else { return }
      applySelection(updated)
    }

    /// The caret boundary at pixel `x` on line `index`, rounded to the
    /// boundary at or before x (`.down`) or at or after it (`.up`).
    func offset(line index: Int, x: CGFloat, rounding: TextBoundaryRounding) -> UTF8Offset? {
      guard
        let (textLine, ctLine) = try? renderer.line(
          at: TextLineIndex(index), in: snapshot, highlights: highlightIndex,
          colorOverrides: tokenColors),
        let start = try? snapshot.convert(textLine.contentRange.lowerBound, to: UTF16Unit.self),
        let end = try? snapshot.convert(textLine.contentRange.upperBound, to: UTF16Unit.self)
      else { return nil }
      let localX = x - textInset
      var column = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localX, y: 0))
      if column == kCFNotFound {
        let range = CTLineGetStringRange(ctLine)
        let endOffset = CTLineGetOffsetForStringIndex(ctLine, range.length, nil)
        column = localX >= endOffset ? range.length : 0
      }
      let edge = CTLineGetOffsetForStringIndex(ctLine, column, nil)
      // The nearest boundary may sit on the wrong side of x; step one unit
      // and let grapheme rounding carry it out to the cluster's edge.
      if rounding == .down, edge > localX { column -= 1 }
      if rounding == .up, edge < localX { column += 1 }
      column = min(max(column, 0), end.value - start.value)
      return try? snapshot.offset(
        at: TextLinePosition(line: textLine.index, column: UTF16Offset(column)),
        rounding: rounding)
    }

    // MARK: - ⌘D

    /// Esc leaves one caret at the last vertically added cursor (or the
    /// final selection's head when cursors came from another gesture).
    @discardableResult
    func exitMultiCursor(for event: NSEvent) -> Bool {
      guard event.keyCode == 53,
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
        selection.selections.count > 1,
        let last = selection.selections.last
      else { return false }
      let head = verticalCursorGoal.flatMap { goal in
        selection.selections.first(where: { $0.head == goal.lastTarget })?.head
      } ?? last.head
      verticalCursorGoal = nil
      applySelection(TextSelectionSet(cursor: head))
      return true
    }

    /// ⌘⌥↑/↓ grows the cursor set from its top/bottom edge. The new caret
    /// keeps the source column where possible and clamps at a shorter line.
    @discardableResult
    func addVerticalCursor(for event: NSEvent) -> Bool {
      guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option]
      else { return false }
      let delta: Int
      switch event.keyCode {
      case 126: delta = -1  // Up arrow
      case 125: delta = 1   // Down arrow
      default: return false
      }
      guard let source = delta < 0 ? selection.selections.first : selection.selections.last,
        let position = try? snapshot.position(at: source.head, columnUnit: UTF16Unit.self)
      else { return true }
      let goalColumn: Int
      if let goal = verticalCursorGoal, goal.direction == delta,
        goal.lastTarget == source.head
      {
        goalColumn = goal.column
      } else {
        goalColumn = position.column.value
      }
      let targetLine = position.line.value + delta
      guard (0..<snapshot.lineCount).contains(targetLine),
        let line = try? snapshot.line(at: TextLineIndex(targetLine)),
        let start = try? snapshot.convert(line.contentRange.lowerBound, to: UTF16Unit.self),
        let end = try? snapshot.convert(line.contentRange.upperBound, to: UTF16Unit.self),
        let target = try? snapshot.offset(
          at: TextLinePosition(
            line: line.index,
            column: UTF16Offset(min(goalColumn, end.value - start.value))),
          rounding: .down),
        let updated = try? TextSelectionSet(
          selection.selections + [TextSelection(cursor: target)])
      else { return true }
      verticalCursorGoal = (delta, goalColumn, target)
      applySelection(updated)
      scrollToVisible(NSRect(x: 0, y: rowTop(targetLine), width: 1, height: lineHeight))
      return true
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
      if window?.firstResponder === self, composition == nil,
        addVerticalCursor(for: event)
      { return true }
      guard window?.firstResponder === self,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers == "d"
      else { return super.performKeyEquivalent(with: event) }
      selectNextOccurrence()
      return true
    }

    /// With only cursors, selects the word under each one. Otherwise adds the
    /// next occurrence of the selected text after the last selection,
    /// wrapping to the top, and scrolls it into view.
    ///
    /// ponytail: a literal scan from the last selection to the end (then from
    /// the top); O(document) when the next match is far away. Add chunked
    /// search if ⌘D on 10 MiB files with rare matches shows up in the budget.
    public func selectNextOccurrence() {
      if selection.selections.allSatisfy(\.isEmpty) {
        let words = selection.selections.compactMap { wordRange(at: $0.head) }
        guard
          let updated = try? TextSelectionSet(
            words.map { TextSelection(anchor: $0.lowerBound, head: $0.upperBound) })
        else { return }
        applySelection(updated)
        return
      }
      guard let needle = selection.selections.first(where: { !$0.isEmpty }),
        let text = try? snapshot.text(in: needle.range),
        let last = selection.selections.last
      else { return }
      let taken = Set(selection.selections.map(\.range))
      let after = TextUTF8Range(last.range.upperBound, UTF8Offset(snapshot.utf8Count))
      let before = TextUTF8Range(UTF8Offset(0), last.range.upperBound)
      var next: TextUTF8Range?
      for scope in [after, before] where next == nil && scope.lowerBound < scope.upperBound {
        let matches =
          (try? TextSearch.find(
            .literal(text), in: snapshot,
            scope: TextSelectionSet([
              TextSelection(anchor: scope.lowerBound, head: scope.upperBound)
            ]))) ?? []
        next = matches.map(\.range).first { !taken.contains($0) }
      }
      guard let next,
        let updated = try? TextSelectionSet(
          selection.selections + [TextSelection(anchor: next.lowerBound, head: next.upperBound)]),
        let line = try? snapshot.position(at: next.lowerBound, columnUnit: UTF8Unit.self).line
      else { return }
      applySelection(updated)
      scrollToVisible(
        NSRect(
          x: 0, y: rowTop(line.value) - 3 * lineHeight, width: 1,
          height: 7 * lineHeight))
    }

    private func applySelection(_ updated: TextSelectionSet) {
      selection = updated
      needsDisplay = true
      onSelectionChange?(selection)
    }
  }
#endif

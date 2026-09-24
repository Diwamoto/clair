import ClairEditorCore

#if os(macOS)
  import AppKit

  /// Keyboard editing (E07): `NSTextInputClient` (`ClairEditorView+TextInput.swift`)
  /// only covers marked text and committed-text insertion. AppKit's
  /// `interpretKeyEvents` routes everything else — arrow keys, Delete,
  /// Return, Tab — through `doCommand(by:)`, and clipboard through the
  /// standard `copy(_:)`/`cut(_:)`/`paste(_:)` responder actions. Movement
  /// and deletion operate on extended grapheme clusters, not UTF-16 code
  /// units or scalars (`INV-COORD-004`).
  ///
  /// ponytail: word-jump (`moveWordLeft:`), page motion, and a persistent
  /// vertical goal-column through ragged lines are UX niceties this task's
  /// acceptance criteria do not require — add if the product asks for them.
  extension ClairEditorView {
    public override func keyDown(with event: NSEvent) {
      if composition == nil, keyInterceptor?(event) == true { return }
      if composition == nil, exitMultiCursor(for: event) { return }
      if composition == nil, addVerticalCursor(for: event) { return }
      verticalCursorGoal = nil
      interpretKeyEvents([event])
    }

    public override func doCommand(by selector: Selector) {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        onCommitEdits?(selection.edits(replacingEachWith: "\n"))
      case #selector(NSResponder.insertTab(_:)):
        onCommitEdits?(selection.edits(replacingEachWith: "\t"))
      case #selector(NSResponder.deleteBackward(_:)):
        deleteAtEachCursor(direction: -1)
      case #selector(NSResponder.deleteForward(_:)):
        deleteAtEachCursor(direction: 1)
      case #selector(NSResponder.moveLeft(_:)):
        moveCaret(direction: -1, extend: false)
      case #selector(NSResponder.moveRight(_:)):
        moveCaret(direction: 1, extend: false)
      case #selector(NSResponder.moveLeftAndModifySelection(_:)):
        moveCaret(direction: -1, extend: true)
      case #selector(NSResponder.moveRightAndModifySelection(_:)):
        moveCaret(direction: 1, extend: true)
      case #selector(NSResponder.moveUp(_:)):
        moveVertical(lineDelta: -1, extend: false)
      case #selector(NSResponder.moveDown(_:)):
        moveVertical(lineDelta: 1, extend: false)
      case #selector(NSResponder.moveUpAndModifySelection(_:)):
        moveVertical(lineDelta: -1, extend: true)
      case #selector(NSResponder.moveDownAndModifySelection(_:)):
        moveVertical(lineDelta: 1, extend: true)
      case #selector(NSResponder.moveToBeginningOfLine(_:)):
        moveToLineBoundary(end: false, extend: false)
      case #selector(NSResponder.moveToEndOfLine(_:)):
        moveToLineBoundary(end: true, extend: false)
      case #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)):
        moveToLineBoundary(end: false, extend: true)
      case #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)):
        moveToLineBoundary(end: true, extend: true)
      default:
        break
      }
    }

    public override func selectAll(_ sender: Any?) {
      guard
        let updated = try? TextSelectionSet([
          TextSelection(anchor: UTF8Offset(0), head: UTF8Offset(snapshot.utf8Count))
        ])
      else { return }
      applyLocalSelection(updated)
    }

    // MARK: - Clipboard (`INV-INPUT-005`)

    // Not overrides: `NSResponder`/`NSView` do not declare these — they are
    // ordinary responder-chain action methods, the same way a menu item's
    // Cut/Copy/Paste target them by selector.
    @objc public func copy(_ sender: Any?) {
      writeSelectionToPasteboard()
    }

    @objc public func cut(_ sender: Any?) {
      guard writeSelectionToPasteboard() else { return }
      let edits = selection.selections.filter { !$0.isEmpty }.map {
        TextEdit(range: $0.range, replacement: "")
      }
      guard !edits.isEmpty else { return }
      onCommitEdits?(edits)
    }

    @objc public func paste(_ sender: Any?) {
      guard let text = pasteboard.string(forType: .string) else { return }
      onCommitEdits?(selection.edits(replacingEachWith: text))
    }

    /// Writes every non-empty selection's text, joined by newlines, as the
    /// pasteboard's only representation — never a second RTF/HTML
    /// representation that could drift from the plain-text one on paste
    /// elsewhere. Returns whether anything was written.
    @discardableResult
    private func writeSelectionToPasteboard() -> Bool {
      let texts = selection.selections.filter { !$0.isEmpty }.compactMap {
        try? snapshot.text(in: $0.range)
      }
      guard !texts.isEmpty else { return false }
      pasteboard.clearContents()
      return pasteboard.setString(texts.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Movement / deletion helpers

    private func offsetByGrapheme(_ offset: UTF8Offset, delta: Int) throws -> UTF8Offset {
      let grapheme = try snapshot.convert(offset, to: GraphemeUnit.self)
      let clamped = min(max(0, grapheme.value + delta), snapshot.graphemeCount)
      return try snapshot.convert(GraphemeOffset(clamped), to: UTF8Unit.self)
    }

    private func lineUTF16Length(_ index: TextLineIndex) throws -> Int {
      let line = try snapshot.line(at: index)
      let start = try snapshot.convert(line.contentRange.lowerBound, to: UTF16Unit.self).value
      let end = try snapshot.convert(line.contentRange.upperBound, to: UTF16Unit.self).value
      return end - start
    }

    private func mapSelections(_ transform: (TextSelection) throws -> TextSelection) throws
      -> TextSelectionSet
    {
      try TextSelectionSet(selection.selections.map(transform))
    }

    private func applyLocalSelection(_ updated: TextSelectionSet) {
      selection = updated
      needsDisplay = true
      onSelectionChange?(selection)
    }

    private func moveCaret(direction: Int, extend: Bool) {
      let transform: (TextSelection) throws -> TextSelection = { [self] cursor in
        if extend {
          let newHead = try self.offsetByGrapheme(cursor.head, delta: direction)
          return TextSelection(anchor: cursor.anchor, head: newHead)
        }
        if !cursor.isEmpty {
          let bound = direction < 0 ? cursor.range.lowerBound : cursor.range.upperBound
          return TextSelection(cursor: bound)
        }
        let newOffset = try self.offsetByGrapheme(cursor.head, delta: direction)
        return TextSelection(cursor: newOffset)
      }
      guard let updated = try? mapSelections(transform) else { return }
      applyLocalSelection(updated)
    }

    private func moveVertical(lineDelta: Int, extend: Bool) {
      // E13: with folds or soft wrap, ↑↓ move by visual row (skipping folded lines, stepping through wrapped ones).
      if !rowMap.isIdentity {
        let transform: (TextSelection) throws -> TextSelection = { [self] cursor in
          let edge = lineDelta < 0 ? UTF8Offset(0) : UTF8Offset(self.snapshot.utf8Count)
          let head = self.verticalTarget(from: cursor.head, rows: lineDelta) ?? edge
          return extend ? TextSelection(anchor: cursor.anchor, head: head) : TextSelection(cursor: head)
        }
        guard let updated = try? mapSelections(transform) else { return }
        return applyLocalSelection(updated)
      }
      let transform: (TextSelection) throws -> TextSelection = { [self] cursor in
        let position = try self.snapshot.position(at: cursor.head, columnUnit: UTF16Unit.self)
        let targetLine = TextLineIndex(
          min(max(0, position.line.value + lineDelta), self.snapshot.lineCount - 1))
        let column = min(position.column.value, try self.lineUTF16Length(targetLine))
        let newHead = try self.snapshot.offset(
          at: TextLinePosition<UTF16Unit>(line: targetLine, column: UTF16Offset(column)),
          rounding: .down)
        return extend
          ? TextSelection(anchor: cursor.anchor, head: newHead) : TextSelection(cursor: newHead)
      }
      guard let updated = try? mapSelections(transform) else { return }
      applyLocalSelection(updated)
    }

    private func moveToLineBoundary(end: Bool, extend: Bool) {
      let transform: (TextSelection) throws -> TextSelection = { [self] cursor in
        let position = try self.snapshot.position(at: cursor.head, columnUnit: UTF8Unit.self)
        let line = try self.snapshot.line(at: position.line)
        let newHead = end ? line.contentRange.upperBound : line.contentRange.lowerBound
        return extend
          ? TextSelection(anchor: cursor.anchor, head: newHead) : TextSelection(cursor: newHead)
      }
      guard let updated = try? mapSelections(transform) else { return }
      applyLocalSelection(updated)
    }

    /// One `onCommitEdits` call deleting one grapheme at every empty
    /// cursor and the full range of every non-empty selection — multi-
    /// cursor Delete is one undo unit, like typing (`INV-INPUT-004`).
    private func deleteAtEachCursor(direction: Int) {
      let edits: [TextEdit] = selection.selections.compactMap { selection in
        if !selection.isEmpty {
          return TextEdit(range: selection.range, replacement: "")
        }
        guard let bound = try? offsetByGrapheme(selection.head, delta: direction) else {
          return nil
        }
        let range =
          direction < 0
          ? TextUTF8Range(bound, selection.head) : TextUTF8Range(selection.head, bound)
        guard range.lowerBound.value != range.upperBound.value else { return nil }
        return TextEdit(range: range, replacement: "")
      }
      guard !edits.isEmpty else { return }
      onCommitEdits?(edits)
    }
  }
#endif

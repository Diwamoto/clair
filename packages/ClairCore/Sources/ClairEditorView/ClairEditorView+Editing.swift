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
  /// ponytail: page motion and a persistent vertical goal-column through
  /// ragged lines remain for a later navigation pass.
  extension ClairEditorView {
    public override func keyDown(with event: NSEvent) {
      if composition == nil, keyInterceptor?(event) == true { return }
      if composition == nil, event.keyCode == 111, isCommandOnly(event.modifierFlags, command: false), let onGoToDefinition {
        onGoToDefinition()  // E17: F12 (kVK_F12)
        return
      }
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
      case #selector(NSResponder.deleteWordBackward(_:)):
        deleteWord(direction: -1)
      case #selector(NSResponder.deleteWordForward(_:)):
        deleteWord(direction: 1)
      case #selector(NSResponder.moveLeft(_:)):
        moveCaret(direction: -1, extend: false)
      case #selector(NSResponder.moveRight(_:)):
        moveCaret(direction: 1, extend: false)
      case #selector(NSResponder.moveLeftAndModifySelection(_:)):
        moveCaret(direction: -1, extend: true)
      case #selector(NSResponder.moveRightAndModifySelection(_:)):
        moveCaret(direction: 1, extend: true)
      case #selector(NSResponder.moveWordLeft(_:)):
        moveWord(direction: -1, extend: false)
      case #selector(NSResponder.moveWordRight(_:)):
        moveWord(direction: 1, extend: false)
      case #selector(NSResponder.moveWordLeftAndModifySelection(_:)):
        moveWord(direction: -1, extend: true)
      case #selector(NSResponder.moveWordRightAndModifySelection(_:)):
        moveWord(direction: 1, extend: true)
      case #selector(NSResponder.moveUp(_:)):
        moveVertical(lineDelta: -1, extend: false)
      case #selector(NSResponder.moveDown(_:)):
        moveVertical(lineDelta: 1, extend: false)
      case #selector(NSResponder.moveUpAndModifySelection(_:)):
        moveVertical(lineDelta: -1, extend: true)
      case #selector(NSResponder.moveDownAndModifySelection(_:)):
        moveVertical(lineDelta: 1, extend: true)
      // ⌘←/⌘→ arrive as moveToLeft/RightEndOfLine, Ctrl-A/E as moveToBeginning/EndOfLine.
      case #selector(NSResponder.moveToBeginningOfLine(_:)),
        #selector(NSResponder.moveToLeftEndOfLine(_:)):
        moveToLineBoundary(end: false, extend: false)
      case #selector(NSResponder.moveToEndOfLine(_:)),
        #selector(NSResponder.moveToRightEndOfLine(_:)):
        moveToLineBoundary(end: true, extend: false)
      case #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)),
        #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)):
        moveToLineBoundary(end: false, extend: true)
      case #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)),
        #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)):
        moveToLineBoundary(end: true, extend: true)
      // ⌘↑/⌘↓.
      case #selector(NSResponder.moveToBeginningOfDocument(_:)):
        moveToDocumentBoundary(end: false, extend: false)
      case #selector(NSResponder.moveToEndOfDocument(_:)):
        moveToDocumentBoundary(end: true, extend: false)
      case #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)):
        moveToDocumentBoundary(end: false, extend: true)
      case #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)):
        moveToDocumentBoundary(end: true, extend: true)
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
      if selection.selections.allSatisfy(\.isEmpty) {
        _ = writeLinesToPasteboard()
      } else {
        writeSelectionToPasteboard()
      }
    }

    @objc public func cut(_ sender: Any?) {
      if selection.selections.allSatisfy(\.isEmpty) {
        guard writeLinesToPasteboard() else { return }
        deleteSelectedLines()
        return
      }
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

    @objc public func undo(_ sender: Any?) {
      guard composition == nil else { return }
      onUndo?()
    }

    @objc public func redo(_ sender: Any?) {
      guard composition == nil else { return }
      onRedo?()
    }

    func performEditorShortcut(_ event: NSEvent) -> Bool {
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      let key = event.charactersIgnoringModifiers?.lowercased()
      switch (modifiers, key) {
      case (.command, "l"):
        selectCurrentLines()
      case ([.command, .shift], "k"):
        deleteSelectedLines()
      case (.command, "]"):
        changeIndent(outdent: false)
      case (.command, "["):
        changeIndent(outdent: true)
      default:
        if modifiers == [.option, .shift], event.keyCode == 125 {
          duplicateSelectedLines()
        } else { return false }
      }
      return true
    }

    private func selectedLineGroups() throws -> [ClosedRange<Int>] {
      var lines = Set<Int>()
      for cursor in selection.selections {
        let first = try snapshot.position(at: cursor.range.lowerBound, columnUnit: UTF8Unit.self).line.value
        var last = try snapshot.position(at: cursor.range.upperBound, columnUnit: UTF8Unit.self).line.value
        if !cursor.isEmpty, last > first,
          cursor.range.upperBound == (try snapshot.line(at: TextLineIndex(last))).contentRange.lowerBound
        { last -= 1 }
        for line in first...last { lines.insert(line) }
      }
      var groups: [ClosedRange<Int>] = []
      for line in lines.sorted() {
        if let last = groups.last, line == last.upperBound + 1 {
          groups[groups.count - 1] = last.lowerBound...line
        } else { groups.append(line...line) }
      }
      return groups
    }

    private func lineRange(_ lines: ClosedRange<Int>, includingTerminator: Bool) throws -> TextUTF8Range {
      let first = try snapshot.line(at: TextLineIndex(lines.lowerBound))
      let last = try snapshot.line(at: TextLineIndex(lines.upperBound))
      return TextUTF8Range(
        first.contentRange.lowerBound,
        includingTerminator ? last.terminatorRange.upperBound : last.contentRange.upperBound)
    }

    private func deletionRange(_ lines: ClosedRange<Int>) throws -> TextUTF8Range {
      let range = try lineRange(lines, includingTerminator: true)
      if lines.upperBound < snapshot.lineCount - 1 || lines.lowerBound == 0 { return range }
      let preceding = try snapshot.line(at: TextLineIndex(lines.lowerBound - 1))
      return TextUTF8Range(preceding.terminatorRange.lowerBound, range.upperBound)
    }

    private func writeLinesToPasteboard() -> Bool {
      guard let groups = try? selectedLineGroups() else { return false }
      let text = groups.compactMap { group -> String? in
        guard let range = try? lineRange(group, includingTerminator: true),
          let content = try? snapshot.text(in: range) else { return nil }
        return range.upperBound.value == snapshot.utf8Count &&
          !(content.hasSuffix("\n") || content.hasSuffix("\r")) ? content + "\n" : content
      }.joined()
      guard !text.isEmpty else { return false }
      pasteboard.clearContents()
      return pasteboard.setString(text, forType: .string)
    }

    private func selectCurrentLines() {
      guard let groups = try? selectedLineGroups(),
        let updated = try? TextSelectionSet(groups.map { group in
          let range = try lineRange(group, includingTerminator: true)
          return TextSelection(anchor: range.lowerBound, head: range.upperBound)
        }) else { return }
      applyLocalSelection(updated)
    }

    private func deleteSelectedLines() {
      guard let groups = try? selectedLineGroups(),
        let edits = try? groups.map({ TextEdit(range: try deletionRange($0), replacement: "") }),
        !edits.isEmpty else { return }
      onCommitEdits?(edits)
    }

    private func duplicateSelectedLines() {
      guard let groups = try? selectedLineGroups() else { return }
      let edits = groups.compactMap { group -> TextEdit? in
        guard let range = try? lineRange(group, includingTerminator: true),
          let text = try? snapshot.text(in: range) else { return nil }
        let replacement = range.upperBound.value == snapshot.utf8Count &&
          !(text.hasSuffix("\n") || text.hasSuffix("\r")) ? "\n" + text : text
        return TextEdit(range: TextUTF8Range(range.upperBound, range.upperBound), replacement: replacement)
      }
      if !edits.isEmpty { onCommitEdits?(edits) }
    }

    private func changeIndent(outdent: Bool) {
      guard let groups = try? selectedLineGroups() else { return }
      var edits: [TextEdit] = []
      for group in groups {
        for index in group {
          guard let line = try? snapshot.line(at: TextLineIndex(index)) else { continue }
          let start = line.contentRange.lowerBound
          if outdent {
            var count = 0
            while count < 4, start.value + count < line.contentRange.upperBound.value {
              let lower = UTF8Offset(start.value + count)
              let upper = UTF8Offset(lower.value + 1)
              guard let character = try? snapshot.text(in: TextUTF8Range(lower, upper)) else { break }
              if character == "\t" { count = 1; break }
              guard character == " " else { break }
              count += 1
            }
            if count > 0 {
              edits.append(TextEdit(range: TextUTF8Range(start, UTF8Offset(start.value + count)), replacement: ""))
            }
          } else {
            edits.append(TextEdit(range: TextUTF8Range(start, start), replacement: "\t"))
          }
        }
      }
      if !edits.isEmpty { onCommitEdits?(edits) }
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
      ensureCaretVisible()
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

    private func wordKind(at offset: UTF8Offset) throws -> Int {
      let next = try offsetByGrapheme(offset, delta: 1)
      let text = try snapshot.text(in: TextUTF8Range(offset, next))
      if text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { return 0 }
      if text == "_" || text.unicodeScalars.allSatisfy({ scalar in
        CharacterSet.alphanumerics.contains(scalar) ||
          scalar.properties.generalCategory == .nonspacingMark ||
          scalar.properties.generalCategory == .spacingMark
      }) { return 1 }
      return 2
    }

    private func wordBoundary(from offset: UTF8Offset, direction: Int) throws -> UTF8Offset {
      var cursor = offset
      if direction > 0 {
        guard cursor.value < snapshot.utf8Count else { return cursor }
        let kind = try wordKind(at: cursor)
        while cursor.value < snapshot.utf8Count, try wordKind(at: cursor) == kind {
          cursor = try offsetByGrapheme(cursor, delta: 1)
        }
        while cursor.value < snapshot.utf8Count, try wordKind(at: cursor) == 0 {
          cursor = try offsetByGrapheme(cursor, delta: 1)
        }
      } else {
        guard cursor.value > 0 else { return cursor }
        cursor = try offsetByGrapheme(cursor, delta: -1)
        while cursor.value > 0, try wordKind(at: cursor) == 0 {
          cursor = try offsetByGrapheme(cursor, delta: -1)
        }
        let kind = try wordKind(at: cursor)
        while cursor.value > 0 {
          let previous = try offsetByGrapheme(cursor, delta: -1)
          guard try wordKind(at: previous) == kind else { break }
          cursor = previous
        }
      }
      return cursor
    }

    private func moveWord(direction: Int, extend: Bool) {
      guard let updated = try? mapSelections({ cursor in
        let head = try wordBoundary(from: cursor.head, direction: direction)
        return extend ? TextSelection(anchor: cursor.anchor, head: head) : TextSelection(cursor: head)
      }) else { return }
      applyLocalSelection(updated)
    }

    private func deleteWord(direction: Int) {
      let edits: [TextEdit] = selection.selections.compactMap { cursor in
        if !cursor.isEmpty { return TextEdit(range: cursor.range, replacement: "") }
        guard let boundary = try? wordBoundary(from: cursor.head, direction: direction),
          boundary != cursor.head else { return nil }
        let range = direction < 0
          ? TextUTF8Range(boundary, cursor.head) : TextUTF8Range(cursor.head, boundary)
        return TextEdit(range: range, replacement: "")
      }
      if !edits.isEmpty { onCommitEdits?(edits) }
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

    /// Collapses multi-cursor into one selection, like other editors do on ⌘↑/⌘↓.
    private func moveToDocumentBoundary(end: Bool, extend: Bool) {
      guard let cursor = end ? selection.selections.last : selection.selections.first else { return }
      let head = end ? UTF8Offset(snapshot.utf8Count) : UTF8Offset(0)
      let target = extend ? TextSelection(anchor: cursor.anchor, head: head) : TextSelection(cursor: head)
      guard let updated = try? TextSelectionSet([target]) else { return }
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

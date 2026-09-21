import ClairEditorCore

#if os(iOS)
  import UIKit

  /// Hardware-keyboard navigation and clipboard (E08): the iOS/iPadOS
  /// counterpart of macOS's `ClairEditorView+Editing.swift`. Character
  /// input and Backspace already come through `UIKeyInput.insertText`/
  /// `deleteBackward` (`ClairEditorView+iOSTextInput.swift`) — everything
  /// a hardware keyboard sends that is *not* a character (arrow keys,
  /// forward-delete, Home/End, word jump, shift-to-extend) is not part of
  /// `UIKeyInput`/`UITextInput` at all, so it is handled the idiomatic
  /// iOS way: `UIKeyCommand`s discovered through `keyCommands`, the same
  /// mechanism `UITextView` itself uses, rather than a raw HID/
  /// `pressesBegan` handler (`ponytail`: "do not hand-roll what UIKit
  /// already gives you").
  ///
  /// Movement and deletion operate on extended grapheme clusters, not
  /// UTF-16 code units or scalars (`INV-COORD-004`), mirroring macOS's
  /// `offsetByGrapheme` exactly.
  extension ClairEditorView {
    private struct Command {
      static let moveLeft = #selector(ClairEditorView.handleMoveLeft)
      static let moveRight = #selector(ClairEditorView.handleMoveRight)
      static let moveLeftExtend = #selector(ClairEditorView.handleMoveLeftExtend)
      static let moveRightExtend = #selector(ClairEditorView.handleMoveRightExtend)
      static let moveUp = #selector(ClairEditorView.handleMoveUp)
      static let moveDown = #selector(ClairEditorView.handleMoveDown)
      static let moveUpExtend = #selector(ClairEditorView.handleMoveUpExtend)
      static let moveDownExtend = #selector(ClairEditorView.handleMoveDownExtend)
      static let moveToLineStart = #selector(ClairEditorView.handleMoveToLineStart)
      static let moveToLineEnd = #selector(ClairEditorView.handleMoveToLineEnd)
      static let moveToLineStartExtend = #selector(ClairEditorView.handleMoveToLineStartExtend)
      static let moveToLineEndExtend = #selector(ClairEditorView.handleMoveToLineEndExtend)
      static let selectAllKey = #selector(ClairEditorView.handleSelectAll)
    }

    // ponytail: forward-delete (fn+Delete) has no stable, broadly-supported
    // `UIKeyCommand.input*` constant across iPadOS hardware-keyboard
    // layouts, and most external keyboards attached to iPad don't carry a
    // dedicated forward-delete key at all; Backspace
    // (`UIKeyInput.deleteBackward`) covers the acceptance criteria's
    // "standard editing shortcuts". Add a discovered-at-runtime
    // `UIKeyCommand` here if a real hardware layout needs it.
    public override var keyCommands: [UIKeyCommand]? {
      [
        UIKeyCommand(
          input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: Command.moveLeft),
        UIKeyCommand(
          input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: Command.moveRight),
        UIKeyCommand(
          input: UIKeyCommand.inputLeftArrow, modifierFlags: .shift, action: Command.moveLeftExtend),
        UIKeyCommand(
          input: UIKeyCommand.inputRightArrow, modifierFlags: .shift,
          action: Command.moveRightExtend),
        UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: Command.moveUp),
        UIKeyCommand(
          input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: Command.moveDown),
        UIKeyCommand(
          input: UIKeyCommand.inputUpArrow, modifierFlags: .shift, action: Command.moveUpExtend),
        UIKeyCommand(
          input: UIKeyCommand.inputDownArrow, modifierFlags: .shift, action: Command.moveDownExtend),
        UIKeyCommand(
          input: UIKeyCommand.inputLeftArrow, modifierFlags: .command,
          action: Command.moveToLineStart),
        UIKeyCommand(
          input: UIKeyCommand.inputRightArrow, modifierFlags: .command,
          action: Command.moveToLineEnd),
        UIKeyCommand(
          input: UIKeyCommand.inputLeftArrow, modifierFlags: [.command, .shift],
          action: Command.moveToLineStartExtend),
        UIKeyCommand(
          input: UIKeyCommand.inputRightArrow, modifierFlags: [.command, .shift],
          action: Command.moveToLineEndExtend),
        UIKeyCommand(input: "a", modifierFlags: .command, action: Command.selectAllKey),
      ]
    }

    @objc fileprivate func handleMoveLeft() { moveCaret(direction: -1, extend: false) }
    @objc fileprivate func handleMoveRight() { moveCaret(direction: 1, extend: false) }
    @objc fileprivate func handleMoveLeftExtend() { moveCaret(direction: -1, extend: true) }
    @objc fileprivate func handleMoveRightExtend() { moveCaret(direction: 1, extend: true) }
    @objc fileprivate func handleMoveUp() { moveVertical(lineDelta: -1, extend: false) }
    @objc fileprivate func handleMoveDown() { moveVertical(lineDelta: 1, extend: false) }
    @objc fileprivate func handleMoveUpExtend() { moveVertical(lineDelta: -1, extend: true) }
    @objc fileprivate func handleMoveDownExtend() { moveVertical(lineDelta: 1, extend: true) }
    @objc fileprivate func handleMoveToLineStart() { moveToLineBoundary(end: false, extend: false) }
    @objc fileprivate func handleMoveToLineEnd() { moveToLineBoundary(end: true, extend: false) }
    @objc fileprivate func handleMoveToLineStartExtend() {
      moveToLineBoundary(end: false, extend: true)
    }
    @objc fileprivate func handleMoveToLineEndExtend() {
      moveToLineBoundary(end: true, extend: true)
    }
    @objc fileprivate func handleSelectAll() { selectAllText() }

    // MARK: - Clipboard (`UIResponderStandardEditActions`)

    public override func copy(_ sender: Any?) {
      writeSelectionToPasteboard()
    }

    public override func cut(_ sender: Any?) {
      guard writeSelectionToPasteboard() else { return }
      let edits = selection.selections.filter { !$0.isEmpty }.map {
        TextEdit(range: $0.range, replacement: "")
      }
      guard !edits.isEmpty else { return }
      inputDelegate?.textWillChange(self)
      onCommitEdits?(edits)
      inputDelegate?.textDidChange(self)
    }

    public override func paste(_ sender: Any?) {
      guard let text = UIPasteboard.general.string else { return }
      inputDelegate?.textWillChange(self)
      onCommitEdits?(selection.edits(replacingEachWith: text))
      inputDelegate?.textDidChange(self)
    }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      switch action {
      case #selector(copy(_:)), #selector(cut(_:)):
        return selection.selections.contains { !$0.isEmpty }
      case #selector(paste(_:)):
        return UIPasteboard.general.hasStrings
      case #selector(UIResponderStandardEditActions.selectAll(_:)):
        return true
      default:
        return super.canPerformAction(action, withSender: sender)
      }
    }

    public override func selectAll(_ sender: Any?) {
      selectAllText()
    }

    /// Writes every non-empty selection's text, joined by newlines, as the
    /// pasteboard's only representation — same `INV-INPUT-005` scope macOS
    /// keeps: never a second RTF/HTML representation that could drift from
    /// the plain-text one on paste elsewhere. Returns whether anything was
    /// written.
    @discardableResult
    private func writeSelectionToPasteboard() -> Bool {
      let texts = selection.selections.filter { !$0.isEmpty }.compactMap {
        try? snapshot.text(in: $0.range)
      }
      guard !texts.isEmpty else { return false }
      UIPasteboard.general.string = texts.joined(separator: "\n")
      return true
    }

    private func selectAllText() {
      guard
        let updated = try? TextSelectionSet([
          TextSelection(anchor: UTF8Offset(0), head: UTF8Offset(snapshot.utf8Count))
        ])
      else { return }
      applyLocalSelection(updated)
    }

    // MARK: - Movement / deletion helpers (mirrors macOS's private helpers
    // of the same name in `ClairEditorView+Editing.swift`)

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
    { try TextSelectionSet(selection.selections.map(transform)) }

    private func applyLocalSelection(_ updated: TextSelectionSet) {
      inputDelegate?.selectionWillChange(self)
      selection = updated
      setNeedsDisplay()
      onSelectionChange?(selection)
      inputDelegate?.selectionDidChange(self)
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
    /// cursor delete is one undo unit, like typing.
    func deleteAtEachCursor(direction: Int) {
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
      inputDelegate?.textWillChange(self)
      onCommitEdits?(edits)
      inputDelegate?.textDidChange(self)
    }
  }
#endif

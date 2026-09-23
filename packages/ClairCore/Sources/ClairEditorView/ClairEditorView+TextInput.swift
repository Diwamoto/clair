import ClairEditorCore

#if os(macOS)
  import AppKit
  import CoreText

  /// `NSTextInputClient` conformance (E07): Japanese IME / marked text.
  ///
  /// **Coordinate space decision (`INV-INPUT-001`)**: every range this
  /// protocol exchanges (`selectedRange`, `markedRange`,
  /// `attributedSubstring(forProposedRange:)`, …) is in UTF-16 offsets
  /// local to the *line* containing the primary selection/composition —
  /// never a document-wide UTF-16 offset. A document-wide address would
  /// require converting an arbitrary offset against the whole rope on
  /// every IME round trip (several per keystroke), reintroducing the
  /// `O(document)` cost `E06` rejected (`INV-PERF-001`); no real input
  /// method needs more than its own line to place a candidate window or
  /// read the text it is composing. A range that would start past the
  /// reference line clamps into it (`INV-INPUT-002`) rather than crossing —
  /// accepted as a known gap, since IME composition does not span a hard
  /// newline in practice (Return commits/dismisses composition first).
  extension ClairEditorView: @preconcurrency NSTextInputClient {
    /// The line every local UTF-16 range in this extension is relative to:
    /// the composition's anchor while composing, otherwise the primary
    /// selection's line.
    private func referenceLine() -> TextLine? {
      let offset = composition?.replacedRange.lowerBound ?? selection.selections.first?.head
      guard let offset, let position = try? snapshot.position(at: offset, columnUnit: UTF8Unit.self)
      else { return nil }
      return try? snapshot.line(at: position.line)
    }

    private func localUTF16Start(of offset: UTF8Offset, in line: TextLine) -> Int? {
      guard
        let lineStart = try? snapshot.convert(line.contentRange.lowerBound, to: UTF16Unit.self)
          .value,
        let value = try? snapshot.convert(offset, to: UTF16Unit.self).value
      else { return nil }
      return value - lineStart
    }

    /// Maps a local UTF-16 range back to a buffer range, clamped to
    /// `line`'s own extent (`INV-INPUT-002`).
    private func bufferRange(fromLocalUTF16 range: NSRange, in line: TextLine) -> TextUTF8Range? {
      guard
        let lineStart = try? snapshot.convert(line.contentRange.lowerBound, to: UTF16Unit.self)
          .value,
        let lineEnd = try? snapshot.convert(line.contentRange.upperBound, to: UTF16Unit.self).value
      else { return nil }
      let lineLength = lineEnd - lineStart
      let start = min(max(range.location, 0), lineLength)
      let end = min(max(range.location + range.length, start), lineLength)
      guard
        let lower = try? snapshot.convert(
          UTF16Offset(lineStart + start), to: UTF8Unit.self, rounding: .down),
        let upper = try? snapshot.convert(
          UTF16Offset(lineStart + end), to: UTF8Unit.self, rounding: .up)
      else { return nil }
      return TextUTF8Range(lower, upper)
    }

    public func hasMarkedText() -> Bool { composition != nil }

    public func markedRange() -> NSRange {
      guard let composition, let line = referenceLine(),
        let start = localUTF16Start(of: composition.replacedRange.lowerBound, in: line)
      else { return NSRange(location: NSNotFound, length: 0) }
      return NSRange(location: start, length: (composition.text as NSString).length)
    }

    public func selectedRange() -> NSRange {
      guard let line = referenceLine() else { return NSRange(location: NSNotFound, length: 0) }
      if let composition,
        let start = localUTF16Start(of: composition.replacedRange.lowerBound, in: line)
      {
        return NSRange(
          location: start + composition.selectedRangeInText.location,
          length: composition.selectedRangeInText.length)
      }
      guard let primary = selection.selections.first,
        let start = localUTF16Start(of: primary.range.lowerBound, in: line),
        let end = localUTF16Start(of: primary.range.upperBound, in: line)
      else { return NSRange(location: 0, length: 0) }
      return NSRange(location: start, length: end - start)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
      let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
      guard let line = referenceLine() else { return }
      guard !text.isEmpty else {
        // An empty marked string is treated as a cancel, not a commit —
        // no macOS IME sends this to mean "commit nothing as something."
        composition = nil
        needsDisplay = true
        return
      }
      let replaced: TextUTF8Range
      if replacementRange.location != NSNotFound,
        let mapped = bufferRange(fromLocalUTF16: replacementRange, in: line)
      {
        replaced = mapped
      } else if let existing = composition {
        replaced = existing.replacedRange
      } else if let primary = selection.selections.first {
        replaced = primary.range
      } else {
        replaced = TextUTF8Range(UTF8Offset(0), UTF8Offset(0))
      }
      composition = EditorComposition(
        replacedRange: replaced, text: text, selectedRangeInText: selectedRange)
      needsDisplay = true
    }

    public func unmarkText() {
      guard let composition else { return }
      commitComposition(composition)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(
      forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
      guard let line = referenceLine(),
        let bufferRange = bufferRange(fromLocalUTF16: range, in: line),
        let text = try? snapshot.text(in: bufferRange)
      else { return nil }
      if let actualRange, let start = localUTF16Start(of: bufferRange.lowerBound, in: line) {
        actualRange.pointee = NSRange(location: start, length: (text as NSString).length)
      }
      return NSAttributedString(string: text, attributes: [.font: font])
    }

    /// Ends composition (if any) or applies plain typed/replaced text, in
    /// both cases as exactly one `onCommitEdits` call (`INV-INPUT-004`).
    public func insertText(_ string: Any, replacementRange: NSRange) {
      let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
      if let composition {
        commitComposition(
          EditorComposition(
            replacedRange: composition.replacedRange, text: text,
            selectedRangeInText: NSRange(location: (text as NSString).length, length: 0)))
        return
      }
      if replacementRange.location != NSNotFound, let line = referenceLine(),
        let mapped = bufferRange(fromLocalUTF16: replacementRange, in: line)
      {
        onCommitEdits?([TextEdit(range: mapped, replacement: text)])
        return
      }
      onCommitEdits?(selection.edits(replacingEachWith: text))
    }

    public func characterIndex(for point: NSPoint) -> Int {
      guard let window else { return NSNotFound }
      let local = convert(window.convertPoint(fromScreen: point), from: nil)
      guard let offset = hitTestOffset(at: local), let line = referenceLine(),
        let start = localUTF16Start(of: offset, in: line)
      else { return NSNotFound }
      return start
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect
    {
      guard let line = referenceLine(),
        let bufferRange = bufferRange(fromLocalUTF16: range, in: line)
      else { return .zero }
      let built: (line: TextLine, ctLine: CTLine)?
      if let composition {
        built = try? renderer.composedLine(at: line.index, in: snapshot, composition: composition)
      } else {
        built = try? renderer.line(
          at: line.index, in: snapshot, highlights: highlights, colorOverrides: tokenColors)
      }
      guard let (textLine, ctLine) = built,
        let lineStartUTF16 = try? snapshot.convert(
          textLine.contentRange.lowerBound, to: UTF16Unit.self
        ).value,
        let localStart = try? snapshot.convert(bufferRange.lowerBound, to: UTF16Unit.self).value,
        let localEnd = try? snapshot.convert(bufferRange.upperBound, to: UTF16Unit.self).value
      else { return .zero }
      // The wrapped row holding the start, in committed coordinates (a composing line is drawn unwrapped).
      let seg = composition == nil ? segments(textLine.index.value).last { $0.start <= localStart - lineStartUTF16 } : nil
      let shift = seg?.shift ?? 0
      let x1 = CTLineGetOffsetForStringIndex(ctLine, localStart - lineStartUTF16, nil) - shift
      let x2 = CTLineGetOffsetForStringIndex(ctLine, localEnd - lineStartUTF16, nil) - shift
      let top = seg?.top ?? rowTop(textLine.index.value)
      let localRect = NSRect(x: textInset + x1, y: top, width: max(x2 - x1, 1), height: lineHeight)
      let windowRect = convert(localRect, to: nil)
      return window?.convertToScreen(windowRect) ?? windowRect
    }

    private func commitComposition(_ composition: EditorComposition) {
      self.composition = nil
      onCommitEdits?([TextEdit(range: composition.replacedRange, replacement: composition.text)])
    }
  }
#endif

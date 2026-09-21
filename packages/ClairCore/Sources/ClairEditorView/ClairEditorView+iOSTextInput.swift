import ClairEditorCore

#if os(iOS)
  import CoreText
  import UIKit

  /// `UITextInput`/`UIKeyInput` conformance (E08): the iOS/iPadOS analog of
  /// macOS's `NSTextInputClient` (`ClairEditorView+TextInput.swift`).
  /// Marked text (Japanese IME / composition) reuses `EditorComposition`
  /// unchanged: the buffer and undo stack are never touched while a
  /// composition is live (`INV-UNDO-003`), and only `insertText`/
  /// `unmarkText` commit it, as exactly one edit through the ordinary
  /// `onCommitEdits` -> `EditorTransactionManager.apply` path.
  ///
  /// **Coordinate space decision (`INV-INPUT-010`, iOS-specific)**: unlike
  /// `NSTextInputClient` — which exchanges raw `NSRange`s in UTF-16 units
  /// local to the current line (`INV-INPUT-001`) specifically to avoid a
  /// document-wide address on every IME round trip — `UITextInput`'s
  /// `UITextPosition`/`UITextRange` are opaque reference types the adopter
  /// defines. `EditorTextPosition` wraps a **document-wide UTF-8 offset
  /// over the composed view** (the committed buffer with the live
  /// composition's text spliced into `replacedRange`, identity when there
  /// is no composition; see `composedOffset`/`bufferOffset` below). This
  /// does not reintroduce the `O(document)` cost `INV-INPUT-001` was
  /// written to avoid: `TextSnapshot`'s rope-backed coordinate conversion
  /// is `O(log n)`, and UIKit only ever asks about the specific position
  /// objects it already holds (never re-derives one from a raw document
  /// index), so there is no per-keystroke whole-document materialization
  /// either way — the reason for a *different* space here is that
  /// `UITextPosition` gives the adopter that freedom, not that UIKit
  /// forces a cost `NSTextInputClient` didn't have.
  ///
  /// **Grapheme-cluster stepping (`INV-COORD-004`)**: `position(from:offset:)`
  /// counts extended grapheme clusters, not UTF-16 code units, reusing the
  /// same `GraphemeUnit` conversion `ClairEditorView+Editing.swift`'s
  /// `offsetByGrapheme` established for macOS — so `UITextInputStringTokenizer`
  /// (the default `tokenizer` below) and hardware/software caret motion
  /// both honor grapheme boundaries without a second movement semantic.
  ///
  /// **Known gap inside an active composition**: any position/range query
  /// that resolves to a point strictly *inside* the composition's own
  /// marked text (not one of its two edges) clamps to the start of the
  /// splice — the same clamp precedent `NSTextInputClient`'s line-local
  /// addressing uses for a range that would cross the reference line
  /// (`INV-INPUT-002`). Real IME sessions query the marked range's edges
  /// (for the candidate window) or ranges wholly outside it, never an
  /// interior point — the marked text's own internal cursor is reported
  /// separately, through `selectedTextRange` reading `EditorComposition
  /// .selectedRangeInText`, not through this generic position machinery.
  final class EditorTextPosition: UITextPosition {
    let offset: UTF8Offset
    init(_ offset: UTF8Offset) { self.offset = offset }
  }

  final class EditorTextRange: UITextRange {
    let range: TextUTF8Range
    init(_ range: TextUTF8Range) { self.range = range }
    override var start: UITextPosition { EditorTextPosition(range.lowerBound) }
    override var end: UITextPosition { EditorTextPosition(range.upperBound) }
    override var isEmpty: Bool { range.lowerBound.value == range.upperBound.value }
  }

  /// A concrete `UITextSelectionRect` (also an abstract class UIKit expects
  /// the adopter to subclass) for one line segment of a possibly
  /// multi-line `selectionRects(for:)` result.
  final class EditorTextSelectionRect: UITextSelectionRect {
    private let storedRect: CGRect
    private let storedContainsStart: Bool
    private let storedContainsEnd: Bool

    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
      self.storedRect = rect
      self.storedContainsStart = containsStart
      self.storedContainsEnd = containsEnd
    }

    override var rect: CGRect { storedRect }
    override var writingDirection: NSWritingDirection { .leftToRight }
    override var containsStart: Bool { storedContainsStart }
    override var containsEnd: Bool { storedContainsEnd }
    override var isVertical: Bool { false }
  }

  extension ClairEditorView {
    // MARK: - Composed <-> buffer offset mapping

    /// The document-as-displayed offset for `bufferOffset`, accounting for
    /// the live composition's virtual splice. Identity when there is no
    /// composition (the overwhelmingly common case: fast, no allocation).
    static func composedOffset(_ bufferOffset: UTF8Offset, composition: EditorComposition?)
      -> UTF8Offset
    {
      guard let composition else { return bufferOffset }
      let lower = composition.replacedRange.lowerBound
      let upper = composition.replacedRange.upperBound
      if bufferOffset.value <= lower.value { return bufferOffset }
      if bufferOffset.value >= upper.value {
        let delta = composition.text.utf8.count - (upper.value - lower.value)
        return UTF8Offset(bufferOffset.value + delta)
      }
      // Inside the range the composition is standing in for (reconversion
      // only — ordinary typing's `replacedRange` is zero-length): clamp to
      // its start.
      return lower
    }

    /// Inverse of `composedOffset`: maps a composed-space offset back to
    /// the underlying buffer offset, clamping any offset that falls inside
    /// the composition's own marked text to the splice's start (see this
    /// file's "known gap" doc above).
    static func bufferOffset(_ composedOffset: UTF8Offset, composition: EditorComposition?)
      -> UTF8Offset
    {
      guard let composition else { return composedOffset }
      let lower = composition.replacedRange.lowerBound
      let composedUpper = lower.value + composition.text.utf8.count
      if composedOffset.value <= lower.value { return composedOffset }
      if composedOffset.value >= composedUpper {
        let delta = composedOffset.value - composedUpper
        return UTF8Offset(composition.replacedRange.upperBound.value + delta)
      }
      return lower
    }

    var composedDocumentLength: Int {
      guard let composition else { return snapshot.utf8Count }
      let originalLength =
        composition.replacedRange.upperBound.value - composition.replacedRange.lowerBound.value
      return snapshot.utf8Count + composition.text.utf8.count - originalLength
    }

    /// `text(in:)`'s composition-aware core — see this file's "known gap"
    /// doc comment for the interior-of-composition behavior.
    func composedText(in composedRange: TextUTF8Range) -> String? {
      guard let composition else { return try? snapshot.text(in: composedRange) }
      let compStart = composition.replacedRange.lowerBound
      let compUTF8Len = composition.text.utf8.count
      let compEnd = UTF8Offset(compStart.value + compUTF8Len)
      if composedRange.lowerBound.value >= compStart.value,
        composedRange.upperBound.value <= compEnd.value
      {
        let utf8 = Array(composition.text.utf8)
        let lo = composedRange.lowerBound.value - compStart.value
        let hi = composedRange.upperBound.value - compStart.value
        guard lo >= 0, hi <= utf8.count, lo <= hi else { return nil }
        return String(decoding: utf8[lo..<hi], as: UTF8.self)
      }
      let lower = Self.bufferOffset(composedRange.lowerBound, composition: composition)
      let upper = Self.bufferOffset(composedRange.upperBound, composition: composition)
      return try? snapshot.text(in: TextUTF8Range(lower, upper))
    }

    /// The `(line, localUTF16)` `CTLine`-relative coordinates `draw(_:)`
    /// actually renders for a composed-space offset, accounting for the
    /// composing line's splice (mirrors `EditorLineRenderer.composedLine`'s
    /// own arithmetic without re-deriving it from scratch).
    func renderedCoordinate(for composedOffset: UTF8Offset) -> (
      line: TextLineIndex, localUTF16: Int
    )? {
      let bufferOffsetValue = Self.bufferOffset(composedOffset, composition: composition)
      guard
        let position = try? snapshot.position(at: bufferOffsetValue, columnUnit: UTF16Unit.self)
      else { return nil }
      guard let composition, composingLine?.value == position.line.value,
        let textLine = try? snapshot.line(at: position.line),
        let lineStartUTF16 = try? snapshot.convert(
          textLine.contentRange.lowerBound, to: UTF16Unit.self
        ).value,
        let compStartUTF16 = try? snapshot.convert(
          composition.replacedRange.lowerBound, to: UTF16Unit.self
        ).value,
        let compEndUTF16 = try? snapshot.convert(
          composition.replacedRange.upperBound, to: UTF16Unit.self
        ).value
      else { return (position.line, position.column.value) }
      if bufferOffsetValue.value <= composition.replacedRange.lowerBound.value {
        return (position.line, position.column.value)
      }
      let localCompStart = compStartUTF16 - lineStartUTF16
      let localCompEnd = compEndUTF16 - lineStartUTF16
      let spliceLenUTF16 = (composition.text as NSString).length
      let shifted = position.column.value - localCompEnd + localCompStart + spliceLenUTF16
      return (position.line, shifted)
    }

    /// Inverse of `renderedCoordinate`'s composing-line branch: given a
    /// UTF-16 index local to whatever `CTLine` was actually hit-tested
    /// (the composed splice when `textLine` is the composing line,
    /// otherwise the plain committed line — see `hitTestOffset`), returns
    /// the corresponding *buffer* line-local UTF-16 column. A touch
    /// landing inside the composition's own marked text (no corresponding
    /// buffer position) clamps to the splice's start, the same
    /// interior-of-composition clamp `composedOffset`/`bufferOffset` use
    /// everywhere else in this file.
    func bufferLocalColumn(forRenderedLocalUTF16 renderedLocal: Int, on textLine: TextLine) -> Int {
      guard let composition, composingLine?.value == textLine.index.value,
        let lineStartUTF16 = try? snapshot.convert(
          textLine.contentRange.lowerBound, to: UTF16Unit.self
        ).value,
        let compStartUTF16 = try? snapshot.convert(
          composition.replacedRange.lowerBound, to: UTF16Unit.self
        ).value,
        let compEndUTF16 = try? snapshot.convert(
          composition.replacedRange.upperBound, to: UTF16Unit.self
        ).value
      else { return renderedLocal }
      let localCompStart = compStartUTF16 - lineStartUTF16
      let localCompEnd = compEndUTF16 - lineStartUTF16
      let spliceLenUTF16 = (composition.text as NSString).length
      if renderedLocal <= localCompStart { return renderedLocal }
      if renderedLocal >= localCompStart + spliceLenUTF16 {
        return renderedLocal - spliceLenUTF16 + (localCompEnd - localCompStart)
      }
      return localCompStart
    }

    /// Whichever `CTLine` `draw(_:)` would render for `index` right now —
    /// the composed splice when it is the composing line, otherwise the
    /// plain committed line. Shared by `draw(_:)` and every geometry query
    /// below so they never disagree about what is actually on screen.
    func renderedLine(at index: TextLineIndex) -> (line: TextLine, ctLine: CTLine)? {
      if let composition, composingLine?.value == index.value {
        return try? renderer.composedLine(at: index, in: snapshot, composition: composition)
      }
      return try? renderer.line(
        at: index, in: snapshot, highlights: highlights, colorOverrides: tokenColors)
    }

    private func rect(forComposedRange range: TextUTF8Range) -> CGRect {
      guard let (startLine, startLocal) = renderedCoordinate(for: range.lowerBound),
        let (_, endLocal) = renderedCoordinate(for: range.upperBound),
        let (_, ctLine) = renderedLine(at: startLine)
      else { return .zero }
      let x1 = CTLineGetOffsetForStringIndex(ctLine, startLocal, nil)
      let x2 = CTLineGetOffsetForStringIndex(ctLine, endLocal, nil)
      let top = EditorViewGeometry.lineOrigin(startLine.value, lineHeight: lineHeight)
      return CGRect(
        x: textInset + min(x1, x2), y: top, width: max(abs(x2 - x1), 1), height: lineHeight)
    }

    private func utf8Offset(intoCompositionText utf16Offset: Int, of text: String) -> Int {
      let ns = text as NSString
      let clamped = min(max(utf16Offset, 0), ns.length)
      return ns.substring(to: clamped).utf8.count
    }

    // MARK: - Touch interaction setup

    /// Attaches the system's editable-text touch interaction bundle — tap
    /// to place the caret, drag/long-press to select, handles, magnifier —
    /// instead of hand-rolling gesture recognizers. Everything it drives
    /// (`closestPosition(to:)`, `selectionRects(for:)`, `caretRect(for:)`,
    /// the `selectedTextRange` setter, first-responder-on-tap, …) is this
    /// file's `UITextInput` conformance.
    func setUpTouchInteraction() {
      let interaction = UITextInteraction(for: .editable)
      interaction.textInput = self
      addInteraction(interaction)
    }
  }

  extension ClairEditorView: UITextInput {
    // MARK: - Text / replace

    public func text(in range: UITextRange) -> String? {
      guard let r = range as? EditorTextRange else { return nil }
      return composedText(in: r.range)
    }

    /// ponytail: per Apple's own documented contract, UIKit never calls
    /// `replace(_:withText:)` while there is marked text, so this does not
    /// special-case an active composition the way `insertText`/
    /// `deleteBackward` do.
    public func replace(_ range: UITextRange, withText text: String) {
      guard let r = range as? EditorTextRange else { return }
      let lower = Self.bufferOffset(r.range.lowerBound, composition: composition)
      let upper = Self.bufferOffset(r.range.upperBound, composition: composition)
      inputDelegate?.textWillChange(self)
      onCommitEdits?([TextEdit(range: TextUTF8Range(lower, upper), replacement: text)])
      inputDelegate?.textDidChange(self)
    }

    // MARK: - Selection

    public var selectedTextRange: UITextRange? {
      get {
        if let composition {
          let lower = composition.replacedRange.lowerBound
          let selStart = utf8Offset(
            intoCompositionText: composition.selectedRangeInText.location, of: composition.text)
          let selEnd = utf8Offset(
            intoCompositionText: composition.selectedRangeInText.location
              + composition.selectedRangeInText.length, of: composition.text)
          return EditorTextRange(
            TextUTF8Range(
              UTF8Offset(lower.value + selStart), UTF8Offset(lower.value + selEnd)))
        }
        guard let primary = selection.selections.first else { return nil }
        return EditorTextRange(primary.range)
      }
      set {
        guard let r = newValue as? EditorTextRange else { return }
        let lower = Self.bufferOffset(r.range.lowerBound, composition: composition)
        let upper = Self.bufferOffset(r.range.upperBound, composition: composition)
        guard let updated = try? TextSelectionSet([TextSelection(anchor: lower, head: upper)])
        else { return }
        inputDelegate?.selectionWillChange(self)
        selection = updated
        setNeedsDisplay()
        onSelectionChange?(selection)
        inputDelegate?.selectionDidChange(self)
      }
    }

    // MARK: - Marked text (IME composition)

    public var markedTextRange: UITextRange? {
      guard let composition else { return nil }
      let lower = composition.replacedRange.lowerBound
      let upper = UTF8Offset(lower.value + composition.text.utf8.count)
      return EditorTextRange(TextUTF8Range(lower, upper))
    }

    public var markedTextStyle: [NSAttributedString.Key: Any]? {
      get { nil }
      set {}
    }

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
      let text = markedText ?? ""
      inputDelegate?.textWillChange(self)
      guard !text.isEmpty else {
        // An empty marked string is a cancel, not a commit — no real IME
        // sends this to mean "commit nothing as something" (same
        // precedent as `NSTextInputClient.setMarkedText` on macOS).
        composition = nil
        setNeedsDisplay()
        inputDelegate?.textDidChange(self)
        return
      }
      let replaced =
        composition?.replacedRange ?? selection.selections.first?.range
        ?? TextUTF8Range(UTF8Offset(0), UTF8Offset(0))
      composition = EditorComposition(
        replacedRange: replaced, text: text, selectedRangeInText: selectedRange)
      setNeedsDisplay()
      inputDelegate?.textDidChange(self)
    }

    public func unmarkText() {
      guard let composition else { return }
      commitComposition(composition)
    }

    func commitComposition(_ composition: EditorComposition) {
      self.composition = nil
      inputDelegate?.textWillChange(self)
      onCommitEdits?([TextEdit(range: composition.replacedRange, replacement: composition.text)])
      inputDelegate?.textDidChange(self)
    }

    // MARK: - Document extent

    public var beginningOfDocument: UITextPosition { EditorTextPosition(UTF8Offset(0)) }
    public var endOfDocument: UITextPosition {
      EditorTextPosition(UTF8Offset(composedDocumentLength))
    }

    // MARK: - Position / range arithmetic

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition)
      -> UITextRange?
    {
      guard let a = fromPosition as? EditorTextPosition, let b = toPosition as? EditorTextPosition
      else { return nil }
      let lower = min(a.offset.value, b.offset.value)
      let upper = max(a.offset.value, b.offset.value)
      return EditorTextRange(TextUTF8Range(UTF8Offset(lower), UTF8Offset(upper)))
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
      guard let pos = position as? EditorTextPosition else { return nil }
      let buffer = Self.bufferOffset(pos.offset, composition: composition)
      guard let grapheme = try? snapshot.convert(buffer, to: GraphemeUnit.self) else { return nil }
      let target = grapheme.value + offset
      guard target >= 0, target <= snapshot.graphemeCount else { return nil }
      guard let newBuffer = try? snapshot.convert(GraphemeOffset(target), to: UTF8Unit.self)
      else { return nil }
      return EditorTextPosition(Self.composedOffset(newBuffer, composition: composition))
    }

    public func position(
      from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int
    ) -> UITextPosition? {
      guard let pos = position as? EditorTextPosition else { return nil }
      switch direction {
      case .left: return self.position(from: pos, offset: -offset)
      case .right: return self.position(from: pos, offset: offset)
      case .up: return verticalPosition(from: pos, lineDelta: -offset)
      case .down: return verticalPosition(from: pos, lineDelta: offset)
      @unknown default: return nil
      }
    }

    /// Vertical motion at the same UTF-16 column, clamped to the target
    /// line's length — the same algorithm `ClairEditorView+iOSEditing.swift`
    /// (and macOS's `ClairEditorView+Editing.swift.moveVertical`) uses for
    /// arrow-key navigation, reused here for `UITextLayoutDirection`
    /// `.up`/`.down` callers (long-press paragraph handles, mainly).
    private func verticalPosition(from pos: EditorTextPosition, lineDelta: Int) -> UITextPosition? {
      let buffer = Self.bufferOffset(pos.offset, composition: composition)
      guard let linePosition = try? snapshot.position(at: buffer, columnUnit: UTF16Unit.self)
      else { return nil }
      let targetLineValue = linePosition.line.value + lineDelta
      guard targetLineValue >= 0, targetLineValue < snapshot.lineCount else { return nil }
      let targetLine = TextLineIndex(targetLineValue)
      guard let line = try? snapshot.line(at: targetLine),
        let lineStart = try? snapshot.convert(line.contentRange.lowerBound, to: UTF16Unit.self)
          .value,
        let lineEnd = try? snapshot.convert(line.contentRange.upperBound, to: UTF16Unit.self)
          .value
      else { return nil }
      let column = min(linePosition.column.value, lineEnd - lineStart)
      guard
        let newBuffer = try? snapshot.offset(
          at: TextLinePosition<UTF16Unit>(line: targetLine, column: UTF16Offset(column)),
          rounding: .down)
      else { return nil }
      return EditorTextPosition(Self.composedOffset(newBuffer, composition: composition))
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
      guard let a = position as? EditorTextPosition, let b = other as? EditorTextPosition
      else { return .orderedSame }
      if a.offset.value < b.offset.value { return .orderedAscending }
      if a.offset.value > b.offset.value { return .orderedDescending }
      return .orderedSame
    }

    public func offset(from: UITextPosition, to: UITextPosition) -> Int {
      guard let a = from as? EditorTextPosition, let b = to as? EditorTextPosition,
        let ga = try? snapshot.convert(
          Self.bufferOffset(a.offset, composition: composition), to: GraphemeUnit.self),
        let gb = try? snapshot.convert(
          Self.bufferOffset(b.offset, composition: composition), to: GraphemeUnit.self)
      else { return 0 }
      return gb.value - ga.value
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection)
      -> UITextPosition?
    {
      guard let r = range as? EditorTextRange else { return nil }
      switch direction {
      case .left, .up: return EditorTextPosition(r.range.lowerBound)
      case .right, .down: return EditorTextPosition(r.range.upperBound)
      @unknown default: return nil
      }
    }

    public func characterRange(
      byExtending position: UITextPosition, in direction: UITextLayoutDirection
    )
      -> UITextRange?
    {
      guard let pos = position as? EditorTextPosition,
        let extended = self.position(from: pos, in: direction, offset: 1) as? EditorTextPosition
      else { return nil }
      let lower = min(pos.offset.value, extended.offset.value)
      let upper = max(pos.offset.value, extended.offset.value)
      return EditorTextRange(TextUTF8Range(UTF8Offset(lower), UTF8Offset(upper)))
    }

    // MARK: - Writing direction (source code is always LTR)

    public func baseWritingDirection(
      for position: UITextPosition, in direction: UITextStorageDirection
    )
      -> NSWritingDirection
    { .leftToRight }

    public func setBaseWritingDirection(
      _ writingDirection: NSWritingDirection, for range: UITextRange
    ) {}

    // MARK: - Geometry

    public func firstRect(for range: UITextRange) -> CGRect {
      guard let r = range as? EditorTextRange else { return .zero }
      return rect(forComposedRange: r.range)
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
      guard let pos = position as? EditorTextPosition else { return .zero }
      return rect(forComposedRange: TextUTF8Range(pos.offset, pos.offset))
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
      guard let r = range as? EditorTextRange else { return [] }
      let lowerBuffer = Self.bufferOffset(r.range.lowerBound, composition: composition)
      let upperBuffer = Self.bufferOffset(r.range.upperBound, composition: composition)
      guard let startLinePos = try? snapshot.position(at: lowerBuffer, columnUnit: UTF8Unit.self),
        let endLinePos = try? snapshot.position(at: upperBuffer, columnUnit: UTF8Unit.self)
      else { return [] }
      var rects: [UITextSelectionRect] = []
      for lineValue in startLinePos.line.value...endLinePos.line.value {
        let lineIndex = TextLineIndex(lineValue)
        guard let textLine = try? snapshot.line(at: lineIndex),
          let (_, ctLine) = renderedLine(at: lineIndex)
        else { continue }
        let lineComposedStart = Self.composedOffset(
          textLine.contentRange.lowerBound, composition: composition)
        let lineComposedEnd = Self.composedOffset(
          textLine.contentRange.upperBound, composition: composition)
        let segStart = max(r.range.lowerBound.value, lineComposedStart.value)
        let segEnd = min(r.range.upperBound.value, lineComposedEnd.value)
        guard segStart <= segEnd,
          let (_, startLocal) = renderedCoordinate(for: UTF8Offset(segStart)),
          let (_, endLocal) = renderedCoordinate(for: UTF8Offset(segEnd))
        else { continue }
        let x1 = CTLineGetOffsetForStringIndex(ctLine, startLocal, nil)
        let x2 = CTLineGetOffsetForStringIndex(ctLine, endLocal, nil)
        let top = EditorViewGeometry.lineOrigin(lineValue, lineHeight: lineHeight)
        let rect = CGRect(
          x: textInset + min(x1, x2), y: top, width: max(abs(x2 - x1), 0), height: lineHeight)
        rects.append(
          EditorTextSelectionRect(
            rect: rect, containsStart: lineValue == startLinePos.line.value,
            containsEnd: lineValue == endLinePos.line.value))
      }
      return rects
    }

    public func closestPosition(to point: CGPoint) -> UITextPosition? {
      guard let buffer = hitTestOffset(at: point) else { return nil }
      return EditorTextPosition(Self.composedOffset(buffer, composition: composition))
    }

    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
      guard let closest = closestPosition(to: point) as? EditorTextPosition,
        let r = range as? EditorTextRange
      else { return nil }
      let clamped = min(
        max(closest.offset.value, r.range.lowerBound.value), r.range.upperBound.value)
      return EditorTextPosition(UTF8Offset(clamped))
    }

    public func characterRange(at point: CGPoint) -> UITextRange? {
      guard let buffer = hitTestOffset(at: point) else { return nil }
      let composedStart = Self.composedOffset(buffer, composition: composition)
      guard let grapheme = try? snapshot.convert(buffer, to: GraphemeUnit.self) else {
        return EditorTextRange(TextUTF8Range(composedStart, composedStart))
      }
      let nextValue = min(grapheme.value + 1, snapshot.graphemeCount)
      guard let nextBuffer = try? snapshot.convert(GraphemeOffset(nextValue), to: UTF8Unit.self)
      else { return EditorTextRange(TextUTF8Range(composedStart, composedStart)) }
      let composedEnd = Self.composedOffset(nextBuffer, composition: composition)
      return EditorTextRange(TextUTF8Range(composedStart, composedEnd))
    }

    // MARK: - UIKeyInput

    public var hasText: Bool { snapshot.utf8Count > 0 }

    public func insertText(_ text: String) {
      if let composition {
        commitComposition(
          EditorComposition(
            replacedRange: composition.replacedRange, text: text,
            selectedRangeInText: NSRange(location: (text as NSString).length, length: 0)))
        return
      }
      inputDelegate?.textWillChange(self)
      onCommitEdits?(selection.edits(replacingEachWith: text))
      inputDelegate?.textDidChange(self)
    }

    public func deleteBackward() {
      if composition != nil {
        // Real IME sessions intercept Backspace inside an active
        // composition themselves (editing the candidate, not reaching
        // here); if one doesn't, cancel without touching the buffer —
        // same as an empty `setMarkedText` — rather than guessing at a
        // buffer edit mid-composition (`INV-UNDO-003`).
        composition = nil
        setNeedsDisplay()
        return
      }
      deleteAtEachCursor(direction: -1)
    }
  }
#endif

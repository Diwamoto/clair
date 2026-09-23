import ClairEditorCore

#if os(macOS)
  import AppKit
  import CoreText

  /// One visual row of a document line: the whole line when it is not
  /// wrapped, else one wrapped piece. `start`/`end` are UTF-16 offsets local to
  /// the line; `shift` is `start`'s x in the line's full `CTLine`, so a piece
  /// draws as the full line moved left by `shift` and clipped to its width.
  struct EditorRowSegment {
    let textLine: TextLine
    let ctLine: CTLine
    let top: CGFloat
    let start: Int
    let end: Int
    let shift: CGFloat
    let isFirst: Bool
    let isLast: Bool

    func x(_ utf16: Int) -> CGFloat { CTLineGetOffsetForStringIndex(ctLine, utf16, nil) - shift }
    var width: CGFloat { CTLineGetOffsetForStringIndex(ctLine, end, nil) - shift }
    /// Whether a caret at local `utf16` is drawn on this row (a break belongs to the next row).
    func owns(_ utf16: Int) -> Bool { utf16 >= start && (utf16 < end || (isLast && utf16 == end)) }
  }

  /// E13: code folding and soft wrap. Folds are byte ranges of syntax nodes
  /// (`foldRanges`, from the host's tree-sitter pass) mapped through every
  /// edit (`INV-TXN-003`); a fold hides its header's following lines up to
  /// the node's end (keeping a closing-bracket line visible, like ccedit's
  /// CodeMirror). A fold is dropped when an edit touches what it hides, and
  /// opened when a selection lands inside it — so caret moves, search hits,
  /// review anchors and definition jumps all reveal their target.
  extension ClairEditorView {
    // MARK: - Rows

    func rowTop(_ line: Int) -> CGFloat { CGFloat(rowMap.row(of: line)) * lineHeight }

    /// Where the rows of `textLine` start (local UTF-16), `[0]` when unwrapped.
    ///
    /// ponytail: a wrapped line is still measured whole (like its `CTLine`), once
    /// per revision; a multi-MB single line pays that on each edit to it.
    private func rowStarts(_ textLine: TextLine) -> [Int] {
      let line = textLine.index.value
      guard softWrap, rowMap.rows(of: line) > 1 else { return [0] }
      if wrapCache.revision != snapshot.revision || wrapCache.columns != wrapColumns {
        wrapCache = (snapshot.revision, wrapColumns, [:])
      }
      if let cached = wrapCache.starts[line] { return cached }
      guard let text = try? snapshot.text(in: textLine.contentRange) else { return [0] }
      let starts = [0] + EditorWrap.breaks(Substring(text), columns: wrapColumns)
      wrapCache.starts[line] = starts
      return starts
    }

    func segments(_ line: Int) -> [EditorRowSegment] {
      guard
        let (textLine, ctLine) = try? renderer.line(
          at: TextLineIndex(line), in: snapshot, highlights: highlights, colorOverrides: tokenColors)
      else { return [] }
      let starts = rowStarts(textLine)
      let length = CTLineGetStringRange(ctLine).length
      let top = rowTop(line)
      return starts.enumerated().map { i, start in
        let end = i + 1 < starts.count ? starts[i + 1] : length
        return EditorRowSegment(
          textLine: textLine, ctLine: ctLine, top: top + CGFloat(i) * lineHeight, start: start, end: end,
          shift: CTLineGetOffsetForStringIndex(ctLine, start, nil), isFirst: i == 0, isLast: i == starts.count - 1)
      }
    }

    /// The document offset under `point` (rows, folds and wraps included).
    func rowHitTest(_ point: NSPoint) -> UTF8Offset? {
      guard snapshot.lineCount > 0 else { return nil }
      let (line, sub) = rowMap.line(atRow: Int((max(point.y, 0) / lineHeight).rounded(.down)))
      let segs = segments(line)
      guard let seg = segs.isEmpty ? nil : segs[min(sub, segs.count - 1)] else { return nil }
      var index = CTLineGetStringIndexForPosition(seg.ctLine, CGPoint(x: point.x - textInset + seg.shift, y: 0))
      guard index != kCFNotFound else { return nil }
      index = min(max(index, seg.start), seg.end)
      return try? snapshot.offset(
        at: TextLinePosition<UTF16Unit>(line: seg.textLine.index, column: UTF16Offset(index)), rounding: .down)
    }

    /// The caret rect for `offset`, in this view's coordinates.
    func caretRect(for offset: UTF8Offset) -> NSRect? {
      guard let position = try? snapshot.position(at: offset, columnUnit: UTF16Unit.self, rounding: .down)
      else { return nil }
      let col = position.column.value
      guard let seg = segments(position.line.value).first(where: { $0.owns(col) }) else { return nil }
      return NSRect(x: textInset + seg.x(col), y: seg.top, width: 1, height: lineHeight)
    }

    /// One visual row up/down from `offset`, keeping x. nil at the document edge.
    func verticalTarget(from offset: UTF8Offset, rows delta: Int) -> UTF8Offset? {
      guard let rect = caretRect(for: offset) else { return nil }
      let row = Int((rect.midY / lineHeight).rounded(.down)) + delta
      guard row >= 0, row < rowMap.rowCount else { return nil }
      return rowHitTest(NSPoint(x: rect.minX, y: (CGFloat(row) + 0.5) * lineHeight))
    }

    // MARK: - Soft wrap

    /// Columns a row holds at the current width (monospace grid).
    func currentWrapColumns() -> Int {
      let clip = enclosingScrollView?.contentView.bounds.width ?? bounds.width
      return max(Int(((clip - textInset - 8) / charAdvance).rounded(.down)), 8)
    }

    private func wrapExtra(_ line: Int) -> Int {
      guard let l = try? snapshot.line(at: TextLineIndex(line)), let text = try? snapshot.text(in: l.contentRange)
      else { return 0 }
      return EditorWrap.breaks(Substring(text), columns: wrapColumns).count
    }

    /// Re-measures every line that can wrap. One byte scan finds them (a line
    /// can only exceed N columns if it has more than N bytes); only those are
    /// walked by grapheme. Runs when wrap is switched on, the width changes,
    /// or the whole content is replaced — never per keystroke.
    func recomputeWraps() {
      guard softWrap else {
        rowMap.setWraps([], lineCount: snapshot.lineCount)
        return
      }
      wrapColumns = currentWrapColumns()
      let columns = wrapColumns
      var long: [Int] = []
      var line = 0
      var length = 0
      snapshot.forEachTextChunk { chunk in
        for byte in chunk.utf8 {
          if byte == 0x0A {
            if length > columns { long.append(line) }
            line += 1
            length = 0
          } else {
            length += 1
          }
        }
      }
      if length > columns { long.append(line) }
      rowMap.setWraps(long.map { ($0, wrapExtra($0)) }, lineCount: snapshot.lineCount)
    }

    /// Re-measures only the lines an edit touched (`INV-PERF-001`).
    func updateWraps(_ sorted: [TextEdit], old: TextSnapshot) {
      guard softWrap, let first = sorted.first, let last = sorted.last,
        let firstLine = try? old.position(at: first.range.lowerBound, columnUnit: UTF8Unit.self).line.value,
        let oldLast = try? old.position(at: last.range.upperBound, columnUnit: UTF8Unit.self).line.value
      else {
        rowMap.setWraps(rowMap.wraps, lineCount: snapshot.lineCount)
        return
      }
      let newLast = oldLast + snapshot.lineCount - old.lineCount
      rowMap.replaceWraps(
        first: firstLine, oldLast: oldLast, newLast: newLast,
        recomputed: (firstLine...max(firstLine, newLast)).map { ($0, wrapExtra($0)) }, lineCount: snapshot.lineCount)
    }

    // MARK: - Folding

    /// The lines `range` hides: after its header line, through its last line
    /// unless that line opens with a closing bracket (which stays visible).
    func hiddenLines(for range: TextUTF8Range) -> ClosedRange<Int>? {
      guard let head = try? snapshot.position(at: range.lowerBound, columnUnit: UTF8Unit.self).line.value,
        let end = try? snapshot.position(at: range.upperBound, columnUnit: UTF8Unit.self, rounding: .down).line.value,
        let endLine = try? snapshot.line(at: TextLineIndex(end)),
        let endText = try? snapshot.text(in: endLine.contentRange)
      else { return nil }
      let closes = endText.drop { $0 == " " || $0 == "\t" }.first.map { "})]".contains($0) } ?? false
      let last = closes ? end - 1 : end
      return last > head ? (head + 1)...last : nil
    }

    func recomputeHidden() {
      rowMap.setHidden(folds.compactMap(hiddenLines))
    }

    /// The candidate whose header is `line`, if any (binary search by start offset).
    func foldCandidate(onLine line: Int) -> TextUTF8Range? {
      guard let l = try? snapshot.line(at: TextLineIndex(line)) else { return nil }
      var lo = 0
      var hi = foldRanges.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if foldRanges[mid].lowerBound.value < l.contentRange.lowerBound.value { lo = mid + 1 } else { hi = mid }
      }
      guard lo < foldRanges.count, foldRanges[lo].lowerBound.value <= l.contentRange.upperBound.value,
        hiddenLines(for: foldRanges[lo]) != nil
      else { return nil }
      return foldRanges[lo]
    }

    func fold(onLine line: Int) -> TextUTF8Range? {
      folds.first { hiddenLines(for: $0)?.lowerBound == line + 1 }
    }

    /// Gutter click / ⌥⌘[ ⌥⌘] on a header line.
    public func toggleFold(line: Int) {
      if let open = fold(onLine: line) {
        folds.removeAll { $0 == open }
      } else if let candidate = foldCandidate(onLine: line) {
        folds.append(candidate)
      }
    }

    /// ⌥⌘[: folds the innermost foldable range around the primary caret, and
    /// parks the caret on its header so the fold does not reopen at once.
    public func foldAtCaret() {
      guard let head = selection.selections.last?.head else { return }
      let around = foldRanges.filter {
        $0.lowerBound.value <= head.value && head.value <= $0.upperBound.value && !folds.contains($0)
          && hiddenLines(for: $0) != nil
      }
      guard let inner = around.max(by: { $0.lowerBound.value < $1.lowerBound.value }),
        let header = try? snapshot.position(at: inner.lowerBound, columnUnit: UTF8Unit.self).line,
        let headerLine = try? snapshot.line(at: header)
      else { return }
      if let hidden = hiddenLines(for: inner),
        let caretLine = try? snapshot.position(at: head, columnUnit: UTF8Unit.self).line.value,
        hidden.contains(caretLine)
      {
        selection = TextSelectionSet(cursor: headerLine.contentRange.upperBound)
        onSelectionChange?(selection)
      }
      folds.append(inner)
    }

    /// ⌥⌘]: opens the fold on, or around, the primary caret's line.
    public func unfoldAtCaret() {
      guard let head = selection.selections.last?.head,
        let line = try? snapshot.position(at: head, columnUnit: UTF8Unit.self).line.value
      else { return }
      folds.removeAll { f in
        guard let hidden = hiddenLines(for: f) else { return true }
        return hidden.lowerBound == line + 1 || hidden.contains(line)
      }
    }

    public func foldAll() { folds = foldRanges.filter { hiddenLines(for: $0) != nil } }
    public func unfoldAll() { folds = [] }

    /// Carries candidates and folds across an edit; a fold whose hidden part the edit touches is dropped.
    func mapFolds(through sorted: [TextEdit], old: TextSnapshot) {
      func mapped(_ r: TextUTF8Range) -> TextUTF8Range {
        let lower = TextEdit.map(r.lowerBound.value, through: sorted)
        return TextUTF8Range(UTF8Offset(lower), UTF8Offset(max(lower, TextEdit.map(r.upperBound.value, through: sorted))))
      }
      if !foldRanges.isEmpty { foldRanges = foldRanges.map(mapped) }
      guard !folds.isEmpty else { return }
      folds = folds.compactMap { f in
        guard let header = try? old.position(at: f.lowerBound, columnUnit: UTF8Unit.self).line,
          let headerEnd = try? old.line(at: header).contentRange.upperBound.value
        else { return nil }
        let touched = sorted.contains { $0.range.lowerBound.value < f.upperBound.value && $0.range.upperBound.value > headerEnd }
        return touched ? nil : mapped(f)
      }
    }

    /// `INV-REV-004`-style reveal: a selection that lands in hidden lines opens their fold.
    func openFoldsAroundSelection() {
      guard !folds.isEmpty else { return }
      let lines = selection.selections.compactMap {
        try? snapshot.position(at: $0.head, columnUnit: UTF8Unit.self).line.value
      }
      let open = folds.filter { f in hiddenLines(for: f).map { h in lines.contains { h.contains($0) } } ?? false }
      if !open.isEmpty { folds.removeAll { open.contains($0) } }
    }

    // MARK: - Gutter / placeholder

    static let placeholder = " ⋯ "

    /// A click in the fold column, or on a folded line's ⋯, toggles that fold. Returns whether it was one.
    func handleFoldClick(at point: NSPoint) -> Bool {
      let (line, sub) = rowMap.line(atRow: Int((max(point.y, 0) / lineHeight).rounded(.down)))
      guard sub == 0 || point.x >= textInset else { return false }
      if gutterWidth > 0, point.x < gutterWidth, point.x >= gutterWidth - 14 {
        guard fold(onLine: line) != nil || foldCandidate(onLine: line) != nil else { return false }
        toggleFold(line: line)
        return true
      }
      if fold(onLine: line) != nil, let last = segments(line).last,
        point.y >= last.top, point.y < last.top + lineHeight, point.x >= textInset + last.width
      {
        toggleFold(line: line)
        return true
      }
      return false
    }

    /// Filled triangles with space on either side, centered on the line-number row.
    func drawFoldMarker(_ line: Int, top: CGFloat, context: CGContext) {
      let folded = fold(onLine: line) != nil
      guard gutterWidth > 0, folded || foldCandidate(onLine: line) != nil else { return }
      let left = gutterWidth - 11
      let mid = top + lineHeight / 2
      context.saveGState()
      let color = folded ? currentLineNumberColor : lineNumberColor
      context.setFillColor((color.blended(withFraction: 0.4, of: textColor) ?? color).cgColor)
      if folded {
        context.move(to: CGPoint(x: left, y: mid - 5))
        context.addLine(to: CGPoint(x: left + 9, y: mid))
        context.addLine(to: CGPoint(x: left, y: mid + 5))
      } else {
        context.move(to: CGPoint(x: left, y: mid - 4))
        context.addLine(to: CGPoint(x: left + 10, y: mid - 4))
        context.addLine(to: CGPoint(x: left + 5, y: mid + 4))
      }
      context.closePath()
      context.fillPath()
      context.restoreGState()
    }

    /// The folded body, as a small rounded ⋯ after the header's text.
    func drawPlaceholder(after seg: EditorRowSegment, context: CGContext) {
      let x = textInset + seg.width + 4
      let s = NSAttributedString(string: Self.placeholder, attributes: [.font: font, .foregroundColor: lineNumberColor])
      let ct = CTLineCreateWithAttributedString(s)
      let w = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
      let pill = CGRect(x: x, y: seg.top + 3, width: w, height: lineHeight - 6)
      context.setFillColor(lineNumberColor.withAlphaComponent(0.18).cgColor)
      context.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil))
      context.fillPath()
      context.saveGState()
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      context.textPosition = CGPoint(x: x, y: seg.top + (lineHeight + font.ascender + font.descender) / 2)
      CTLineDraw(ct, context)
      context.restoreGState()
    }
  }
#endif

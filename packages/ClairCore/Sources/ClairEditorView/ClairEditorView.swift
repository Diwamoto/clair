import ClairEditorCore

#if os(macOS)
  import AppKit
  import CoreText

  /// The macOS native editor viewport (E06 rendering/hit-test/selection,
  /// E07 text input): a custom `NSView` that lays out, via CoreText, only
  /// the document lines currently intersecting its visible rect — never
  /// the whole document, never one subview per line. Meant as an
  /// `NSScrollView` document view; scrolling itself is standard AppKit
  /// clipping, not reimplemented here.
  ///
  /// This view never touches `TextBuffer`/`EditorTransactionManager`
  /// directly (same split E06 established for `onSelectionChange`):
  /// `onCommitEdits` (`ClairEditorView+Editing.swift`) is how typing, IME
  /// commits, clipboard, and drag/drop ask the owner to apply an edit and
  /// reflect the result back via `applyEdits`.
  public final class ClairEditorView: NSView {
    public private(set) var snapshot: TextSnapshot
    // `internal(set)`, not `private(set)`: E07's editing/IME/drag extensions
    // (separate files, same module) update selection locally the same way
    // this file's mouse handling always has.
    public internal(set) var selection: TextSelectionSet {
      didSet { openFoldsAroundSelection(); smearCaret(from: oldValue) }
    }
    public var highlights: [EditorHighlightSpan] = [] {
      didSet {
        renderer.invalidateAll()
        needsDisplay = true
      }
    }
    public var diagnostics: [EditorDiagnosticSpan] = [] {
      didSet { needsDisplay = true }
    }
    public var tokenColors: [EditorTokenKind: NSColor] = [:] {
      didSet {
        renderer.invalidateAll()
        needsDisplay = true
      }
    }
    /// Appearance (the host maps its design tokens here; defaults are the system colours).
    public var background: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
    public var textColor: NSColor = .textColor {
      didSet { renderer.baseColor = textColor; renderer.invalidateAll(); needsDisplay = true }
    }
    public var selectionColor: NSColor = .selectedTextBackgroundColor { didSet { needsDisplay = true } }
    public var caretColor: NSColor = .textColor { didSet { needsDisplay = true } }
    /// Width of the line-number column; 0 hides it. Text starts after it.
    public var gutterWidth: CGFloat = 0 { didSet { renderer.invalidateAll(); needsDisplay = true } }
    public var lineNumberColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    /// Line number of the caret's line is drawn in this colour instead.
    public var currentLineNumberColor: NSColor = .labelColor { didSet { needsDisplay = true } }
    /// An attribute-only annotation for the selected line; never changes the document revision.
    public var blameAnnotation: (line: Int, text: String)? {
      didSet {
        if blameAnnotation?.line != oldValue?.line || blameAnnotation?.text != oldValue?.text { needsDisplay = true }
      }
    }
    public var blameColor: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
    /// V13: debugger decoration is a viewport overlay, never a document edit.
    public var debugStoppedLine: Int? { didSet { needsDisplay = true } }  // 1-based
    public var debugBreakpoints: Set<Int> = [] { didSet { needsDisplay = true } }  // 1-based
    public var debugLineColor: NSColor = .systemBlue.withAlphaComponent(0.14) { didSet { needsDisplay = true } }
    public var debugBreakpointColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    public var onToggleBreakpoint: ((Int) -> Void)?
    /// Called after a mouse-driven selection change. The owner is
    /// responsible for reconciling this back into its
    /// `EditorTransactionManager`; this view does not own that state.
    public var onSelectionChange: ((TextSelectionSet) -> Void)?
    /// Called with one transaction's worth of edits — typing, an IME
    /// commit, cut, paste, or a text drop — for the owner to apply through
    /// its `EditorTransactionManager` (one call is one undo unit) and
    /// reflect back via `applyEdits`. See `ClairEditorView+Editing.swift`.
    public var onCommitEdits: (([TextEdit]) -> Void)?
    /// E12: sees every key before text input does (not while an IME
    /// composition is live); returning true swallows it. The completion list
    /// uses this for ↑↓/Return/Tab/Esc.
    public var keyInterceptor: ((NSEvent) -> Bool)?
    /// Copy/cut/paste target. Tests pass a private one so parallel runs never race on (or clobber) the user's clipboard.
    public var pasteboard: NSPasteboard = .general

    // E13 (`ClairEditorView+Rows.swift`).
    /// Wrap long lines to the view width instead of scrolling sideways.
    public var softWrap = false {
      didSet {
        guard softWrap != oldValue else { return }
        recomputeWraps()
        knownContentWidth = 0
        syncFrameSize()
        needsDisplay = true
      }
    }
    /// Foldable syntax ranges from the host's parse (one per header line, sorted); mapped through edits.
    public var foldRanges: [TextUTF8Range] = [] { didSet { needsDisplay = true } }
    /// Currently folded ranges (each one of `foldRanges` at the time it was folded).
    public var folds: [TextUTF8Range] = [] {
      didSet {
        guard folds != oldValue else { return }
        recomputeHidden()
        syncFrameSize()
        needsDisplay = true
        onFoldsChange?(folds)
      }
    }
    /// Called whenever `folds` changes, so a host can restore them on a rebuilt view.
    public var onFoldsChange: (([TextUTF8Range]) -> Void)?
    var rowMap: EditorRowMap
    /// Row starts of wrapped lines drawn at this revision and width, so scrolling never re-walks a long line.
    var wrapCache: (revision: TextRevision?, columns: Int, starts: [Int: [Int]]) = (nil, 0, [:])
    var wrapColumns = 80
    let charAdvance: CGFloat

    let renderer: EditorLineRenderer
    let font: NSFont
    private let blameFont: NSFont
    private let ascent: CGFloat
    /// The fixed per-row height every line occupies (no soft-wrap, one row
    /// per document line). Exposed so a host can scroll a given line into
    /// view.
    public let lineHeight: CGFloat
    var textInset: CGFloat { gutterWidth + 4 }
    /// Vertical centring of a glyph row inside a taller `lineHeight`.
    private let baselineShift: CGFloat
    private var knownContentWidth: CGFloat = 0
    /// The fading "liquid" trail the primary caret leaves when it moves.
    private let caretTrail = CALayer()
    var dragAnchor: UTF8Offset?
    var dragFixedSelections: [TextSelection] = []
    /// Where a ⌥-drag block selection started (`ClairEditorView+MultiCursor.swift`).
    var blockAnchor: NSPoint?
    var verticalCursorGoal: (direction: Int, column: Int, lastTarget: UTF8Offset)?
    /// The live IME composition, if any (`ClairEditorView+TextInput.swift`).
    /// A view-local overlay only — see `EditorComposition`'s doc comment.
    var composition: EditorComposition?

    public init(
      snapshot: TextSnapshot, selection: TextSelectionSet,
      font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular), lineHeight: CGFloat? = nil
    ) {
      self.snapshot = snapshot
      self.selection = selection
      self.font = font
      self.blameFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      self.renderer = EditorLineRenderer(font: font)
      self.ascent = font.ascender
      let natural = (font.ascender - font.descender + font.leading).rounded(.up)
      self.lineHeight = max(lineHeight ?? natural, natural)
      self.baselineShift = ((self.lineHeight - natural) / 2).rounded(.down)
      self.rowMap = EditorRowMap(lineCount: snapshot.lineCount)
      let digit = CTLineCreateWithAttributedString(NSAttributedString(string: "0", attributes: [.font: font]))
      self.charAdvance = max(CGFloat(CTLineGetTypographicBounds(digit, nil, nil, nil)), 1)
      super.init(frame: .zero)
      wantsLayer = true
      registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
      fatalError("ClairEditorView does not support coder-based restoration")
    }

    isolated deinit {
      NotificationCenter.default.removeObserver(self)
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func resetCursorRects() {
      addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: - Content

    /// Replaces the view's entire content (e.g. opening a document, or
    /// undo/redo/external reload). Discards the whole layout cache; use
    /// `applyEdits` for an incremental edit instead.
    public func configure(
      snapshot: TextSnapshot, selection: TextSelectionSet,
      highlights: [EditorHighlightSpan] = [], diagnostics: [EditorDiagnosticSpan] = []
    ) {
      self.snapshot = snapshot
      self.selection = selection
      self.highlights = highlights
      self.diagnostics = diagnostics
      renderer.invalidateAll()
      folds = []
      recomputeWraps()
      knownContentWidth = 0
      syncFrameSize()
      needsDisplay = true
    }

    /// Applies one already-committed `EditorTransactionManager` edit,
    /// relaying out only the lines it touched.
    public func applyEdits(
      _ edits: [TextEdit], oldSnapshot: TextSnapshot, newSnapshot: TextSnapshot,
      selection: TextSelectionSet
    ) {
      renderer.invalidate(edits: edits, in: oldSnapshot)
      let sorted = edits.sorted { $0.range.lowerBound.value < $1.range.lowerBound.value }
      if !diagnostics.isEmpty {
        diagnostics = diagnostics.map { $0.mapped(through: sorted) }
      }
      self.snapshot = newSnapshot
      updateWraps(sorted, old: oldSnapshot)
      mapFolds(through: sorted, old: oldSnapshot)
      if !folds.isEmpty { recomputeHidden() }
      self.selection = selection
      syncFrameSize()
      needsDisplay = true
    }

    // MARK: - Layout / scrolling

    /// Moves the caret to the start of `line` (0-based, clamped), scrolls it into view and takes focus.
    public func reveal(line: Int) {
      let i = min(max(line, 0), snapshot.lineCount - 1)
      guard let l = try? snapshot.line(at: TextLineIndex(i)) else { return }
      selection = TextSelectionSet(cursor: l.contentRange.lowerBound)  // opens a fold around it first
      onSelectionChange?(selection)
      syncFrameSize()
      scrollToVisible(NSRect(x: 0, y: rowTop(i) - 3 * lineHeight, width: 1, height: 7 * lineHeight))
      window?.makeFirstResponder(self)
      needsDisplay = true
    }

    public override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      guard let clipView = enclosingScrollView?.contentView else { return }
      clipView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(handleClipViewBoundsChange),
        name: NSView.boundsDidChangeNotification, object: clipView)
      syncFrameSize()
    }

    @objc private func handleClipViewBoundsChange() {
      syncFrameSize()
    }

    private func syncFrameSize() {
      let clipWidth = enclosingScrollView?.contentView.bounds.width ?? bounds.width
      if softWrap, currentWrapColumns() != wrapColumns { recomputeWraps() }
      let width = softWrap ? clipWidth : max(knownContentWidth, clipWidth)
      let height = CGFloat(rowMap.rowCount) * lineHeight
      let newSize = NSSize(width: width, height: height)
      guard newSize != frame.size else { return }
      setFrameSize(newSize)
    }

    // MARK: - Hit testing

    /// Converts a point in this view's own (flipped) coordinate space to a
    /// document offset, snapping to the nearest character boundary CoreText
    /// reports for that line.
    public func hitTestOffset(at point: NSPoint) -> UTF8Offset? {
      rowHitTest(point)
    }

    // MARK: - Mouse / selection

    /// A mouse-down inside the existing selection defers to a possible text
    /// drag-out instead of immediately collapsing the selection — see
    /// `mouseDragged`/`ClairEditorView+DragDrop.swift`. `nil` once that
    /// gesture is resolved either way.
    private var pendingSelectionDrag: (downPoint: NSPoint, offset: UTF8Offset)?

    public override func mouseDown(with event: NSEvent) {
      verticalCursorGoal = nil
      window?.makeFirstResponder(self)
      // A click anywhere unmarks an in-progress IME composition, matching
      // system text views: the click is the user abandoning the candidate
      // in favor of pointing elsewhere.
      if composition != nil { inputContext?.discardMarkedText() }
      let point = convert(event.locationInWindow, from: nil)
      if point.x >= 0, point.x < 16, let onToggleBreakpoint {
        let (line, subrow) = rowMap.line(atRow: Int(max(point.y, 0) / lineHeight))
        if subrow == 0 { onToggleBreakpoint(line + 1); return }
      }
      if handleFoldClick(at: point) { return }
      if event.modifierFlags.contains(.option) {
        blockAnchor = point
        updateBlockSelection(to: point)
        return
      }
      guard let offset = hitTestOffset(at: point) else { return }
      if event.clickCount > 1 {
        pendingSelectionDrag = nil
        selectUnit(
          at: offset, wholeLine: event.clickCount > 2,
          adding: event.modifierFlags.contains(.command))
        return
      }

      if !event.modifierFlags.contains(.command),
        selection.selections.contains(where: {
          !$0.isEmpty && $0.range.lowerBound.value <= offset.value
            && offset.value <= $0.range.upperBound.value
        })
      {
        pendingSelectionDrag = (point, offset)
        return
      }
      dragAnchor = offset
      dragFixedSelections = event.modifierFlags.contains(.command) ? selection.selections : []
      updateDragSelection(head: offset)
    }

    public override func mouseDragged(with event: NSEvent) {
      if blockAnchor != nil {
        updateBlockSelection(to: convert(event.locationInWindow, from: nil))
        return
      }
      if let pending = pendingSelectionDrag {
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pending.downPoint.x, point.y - pending.downPoint.y) > 4 else {
          return
        }
        pendingSelectionDrag = nil
        beginDraggingSelection(with: event)
        return
      }
      guard let offset = hitTestOffset(at: convert(event.locationInWindow, from: nil)) else {
        return
      }
      updateDragSelection(head: offset)
    }

    public override func mouseUp(with event: NSEvent) {
      if let pending = pendingSelectionDrag {
        // Resolved as a plain click (never exceeded the drag threshold):
        // collapse to a caret at the click point, same as a click outside
        // the selection would.
        dragAnchor = pending.offset
        dragFixedSelections = []
        updateDragSelection(head: pending.offset)
        pendingSelectionDrag = nil
      }
      dragAnchor = nil
      blockAnchor = nil
    }

    private func updateDragSelection(head: UTF8Offset) {
      guard let anchor = dragAnchor else { return }
      let active = TextSelection(anchor: anchor, head: head)
      guard let updated = try? TextSelectionSet(dragFixedSelections + [active]) else { return }
      selection = updated
      needsDisplay = true
      onSelectionChange?(selection)
    }

    public override func becomeFirstResponder() -> Bool {
      needsDisplay = true
      return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
      needsDisplay = true
      return super.resignFirstResponder()
    }

    /// Stretches a ghost over the old and new caret rects, then collapses it
    /// into the new one while fading — the caret itself (drawn in `draw`) is
    /// already at its destination, so this is decoration only.
    private func smearCaret(from old: TextSelectionSet) {
      guard window?.firstResponder === self, let layer,
        let from = old.selections.last.flatMap({ $0.isEmpty ? caretRect(for: $0.head) : nil }),
        let to = selection.selections.last.flatMap({ $0.isEmpty ? caretRect(for: $0.head) : nil }),
        from.origin != to.origin
      else { return }
      if caretTrail.superlayer == nil { layer.addSublayer(caretTrail) }
      let end = to.insetBy(dx: -0.25, dy: 0)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      caretTrail.backgroundColor = caretColor.cgColor
      caretTrail.cornerRadius = 1
      caretTrail.frame = end
      caretTrail.opacity = 0
      CATransaction.commit()
      // A caret-sized ghost slides old → new and fades; no union box, so a
      // jump never flashes a selection-like rectangle.
      let group = CAAnimationGroup()
      let position = CABasicAnimation(keyPath: "position")
      position.fromValue = CGPoint(x: from.midX, y: from.midY)
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0.5
      group.animations = [position, fade]
      group.duration = 0.09
      group.timingFunction = CAMediaTimingFunction(name: .easeOut)
      caretTrail.add(group, forKey: "smear")
    }

    // MARK: - Drawing

    /// The line an active composition sits on, or `nil` when there is none
    /// or it can no longer be located (e.g. a concurrent external edit —
    /// falls back to plain rendering rather than crashing).
    private var composingLine: TextLineIndex? {
      guard let composition else { return nil }
      return try? snapshot.position(
        at: composition.replacedRange.lowerBound, columnUnit: UTF8Unit.self
      )
      .line
    }

    public override func draw(_ dirtyRect: NSRect) {
      guard let context = NSGraphicsContext.current?.cgContext else { return }
      context.setFillColor(background.cgColor)
      context.fill(dirtyRect)

      let firstRow = Int((max(dirtyRect.minY, 0) / lineHeight).rounded(.down))
      let lastRow = Int((max(dirtyRect.maxY - 0.001, 0) / lineHeight).rounded(.down))
      let visible = rowMap.lines(inRows: firstRow..<(lastRow + 1))
      guard !visible.isEmpty else { return }

      let composingLine = self.composingLine
      let selectedLine = selection.selections.first.flatMap {
        try? snapshot.position(at: $0.head, columnUnit: UTF8Unit.self, rounding: .down).line.value
      }
      var measuredWidth: CGFloat = 0
      for (index, _) in visible {
        // A composing line's local UTF-16 offsets no longer line up with the
        // committed buffer (the composition text is spliced in over it), so
        // selection/caret overlays — which are computed from committed
        // coordinates — are skipped for exactly that one line while it is
        // composing (`INV-INPUT-009`: the OS candidate window is the only
        // composition cursor shown).
        // ponytail: a composing line is drawn on one row even when soft
        // wrap would break it; it rewraps as soon as the text is committed.
        let segs: [EditorRowSegment]
        if let composition, composingLine?.value == index {
          guard let (textLine, ctLine) = try? renderer.composedLine(at: TextLineIndex(index), in: snapshot, composition: composition)
          else { continue }
          segs = [
            EditorRowSegment(
              textLine: textLine, ctLine: ctLine, top: rowTop(index), start: 0, end: CTLineGetStringRange(ctLine).length,
              shift: 0, isFirst: true, isLast: true)
          ]
        } else {
          segs = segments(index)
        }
        let isComposingLine = composingLine?.value == index
        for seg in segs where seg.top + lineHeight > dirtyRect.minY && seg.top < dirtyRect.maxY {
          if index + 1 == debugStoppedLine {
            context.setFillColor(debugLineColor.cgColor)
            context.fill(CGRect(x: 0, y: seg.top, width: bounds.width, height: lineHeight))
          }
          if !isComposingLine { drawSelections(seg, context: context) }
          drawText(seg, context: context)
          if seg.isFirst, gutterWidth > 0 {
            drawLineNumber(index, top: seg.top, context: context)
            if debugBreakpoints.contains(index + 1) {
              context.setFillColor(debugBreakpointColor.cgColor)
              context.fillEllipse(in: CGRect(x: 5, y: seg.top + (lineHeight - 8) / 2, width: 8, height: 8))
            }
            drawFoldMarker(index, top: seg.top, context: context)
          }
          if !isComposingLine {
            drawDiagnostics(seg, context: context)
            drawCarets(seg, context: context)
          }
          if seg.isLast, selectedLine == index, blameAnnotation?.line == index,
            let annotation = blameAnnotation {
            let endX = textInset + seg.x(seg.end)
            let x = endX + 120
            let label = CTLineCreateWithAttributedString(NSAttributedString(
              string: annotation.text, attributes: [.font: blameFont, .foregroundColor: blameColor]))
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: x, y: seg.top + baselineShift + ascent)
            CTLineDraw(label, context)
            context.restoreGState()
            if !softWrap {
              measuredWidth = max(measuredWidth, x + CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil)) + textInset)
            }
          }
          if seg.isLast, fold(onLine: index) != nil { drawPlaceholder(after: seg, context: context) }
        }
        if !softWrap, let seg = segs.first {
          let width = CGFloat(CTLineGetTypographicBounds(seg.ctLine, nil, nil, nil))
          measuredWidth = max(measuredWidth, width + textInset * 2)
        }
      }
      if measuredWidth > knownContentWidth {
        knownContentWidth = measuredWidth
        syncFrameSize()
      }
    }

    /// `CTLineDraw` assumes a bottom-up text matrix; a flipped `NSView`'s
    /// context already has AppKit's top-down flip baked into its CTM, which
    /// mirrors glyphs unless the text matrix cancels it out locally. Fills
    /// elsewhere in this method need no such adjustment — only text drawing
    /// does.
    private func drawText(_ seg: EditorRowSegment, context: CGContext) {
      context.saveGState()
      // A wrapped piece is the whole line moved left and clipped to its own width.
      if !(seg.isFirst && seg.isLast) { context.clip(to: CGRect(x: textInset, y: seg.top, width: seg.width, height: lineHeight)) }
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      context.textPosition = CGPoint(x: textInset - seg.shift, y: seg.top + baselineShift + ascent)
      CTLineDraw(seg.ctLine, context)
      context.restoreGState()
    }

    /// Right-aligned 1-based number with room for the fold marker beside it.
    private func drawLineNumber(_ index: Int, top: CGFloat, context: CGContext) {
      let current = selection.selections.first.flatMap { try? snapshot.position(at: $0.head, columnUnit: UTF8Unit.self, rounding: .down).line.value } == index
      let s = NSAttributedString(
        string: String(index + 1), attributes: [.font: font, .foregroundColor: current ? currentLineNumberColor : lineNumberColor])
      let line = CTLineCreateWithAttributedString(s)
      let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      context.saveGState()
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      context.textPosition = CGPoint(x: gutterWidth - 20 - width, y: top + baselineShift + ascent)
      CTLineDraw(line, context)
      context.restoreGState()
    }

    /// `local` clipped to the piece `seg` shows, or nil when they do not overlap.
    private func clip(_ range: TextUTF8Range, to seg: EditorRowSegment) -> Range<Int>? {
      guard let local = try? localUTF16Range(of: range, clippedTo: seg.textLine, in: snapshot) else { return nil }
      let lower = max(local.lowerBound, seg.start)
      let upper = min(local.upperBound, seg.end)
      return lower < upper ? lower..<upper : nil
    }

    private func drawSelections(_ seg: EditorRowSegment, context: CGContext) {
      guard selection.selections.contains(where: { !$0.isEmpty }) else { return }
      context.setFillColor(selectionColor.cgColor)
      for range in selection.selections.map(\.range) {
        guard let local = clip(range, to: seg) else { continue }
        let x1 = seg.x(local.lowerBound)
        let x2 = seg.x(local.upperBound)
        context.fill(CGRect(x: textInset + x1, y: seg.top, width: x2 - x1, height: lineHeight))
      }
    }

    private func drawCarets(_ seg: EditorRowSegment, context: CGContext) {
      guard window?.firstResponder === self else { return }
      for cursor in selection.selections where cursor.isEmpty {
        guard
          let position = try? snapshot.position(
            at: cursor.head, columnUnit: UTF16Unit.self, rounding: .down),
          position.line == seg.textLine.index, seg.owns(position.column.value)
        else { continue }
        context.setFillColor(caretColor.cgColor)
        context.fill(CGRect(x: textInset + seg.x(position.column.value), y: seg.top, width: 1.5, height: lineHeight))
      }
    }

    private func drawDiagnostics(_ seg: EditorRowSegment, context: CGContext) {
      for diagnostic in diagnostics {
        guard let local = clip(diagnostic.range, to: seg) else { continue }
        drawSquiggle(
          from: textInset + seg.x(local.lowerBound), to: textInset + seg.x(local.upperBound),
          baseline: seg.top + lineHeight - 2, color: diagnostic.severity.color, context: context)
      }
    }

    private func drawSquiggle(
      from x1: CGFloat, to x2: CGFloat, baseline: CGFloat, color: NSColor, context: CGContext
    ) {
      guard x2 > x1 else { return }
      let amplitude: CGFloat = 1.5
      let period: CGFloat = 4
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(1)
      context.beginPath()
      context.move(to: CGPoint(x: x1, y: baseline))
      var x = x1
      var up = true
      while x < x2 {
        let next = min(x + period, x2)
        context.addLine(to: CGPoint(x: next, y: baseline + (up ? -amplitude : amplitude)))
        up.toggle()
        x = next
      }
      context.strokePath()
    }
  }
#endif

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
    public internal(set) var selection: TextSelectionSet
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

    let renderer: EditorLineRenderer
    let font: NSFont
    private let ascent: CGFloat
    /// The fixed per-row height every line occupies (no soft-wrap, one row
    /// per document line). Exposed so a host can scroll a given line into
    /// view.
    public let lineHeight: CGFloat
    var textInset: CGFloat { gutterWidth + 4 }
    /// Vertical centring of a glyph row inside a taller `lineHeight`.
    private let baselineShift: CGFloat
    private var knownContentWidth: CGFloat = 0
    private var caretVisible = true
    private var caretTimer: Timer?
    var dragAnchor: UTF8Offset?
    var dragFixedSelections: [TextSelection] = []
    /// Where a ⌥-drag block selection started (`ClairEditorView+MultiCursor.swift`).
    var blockAnchor: NSPoint?
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
      self.renderer = EditorLineRenderer(font: font)
      self.ascent = font.ascender
      let natural = (font.ascender - font.descender + font.leading).rounded(.up)
      self.lineHeight = max(lineHeight ?? natural, natural)
      self.baselineShift = ((self.lineHeight - natural) / 2).rounded(.down)
      super.init(frame: .zero)
      wantsLayer = true
      registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
      fatalError("ClairEditorView does not support coder-based restoration")
    }

    // `NSView` subclasses are implicitly `@MainActor`, and a plain `deinit`
    // runs `nonisolated` regardless, so it cannot touch `caretTimer` (same
    // reasoning as `ClairGhosttySurfaceView`'s `isolated deinit`).
    isolated deinit {
      caretTimer?.invalidate()
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
      if !diagnostics.isEmpty {
        let sorted = edits.sorted { $0.range.lowerBound.value < $1.range.lowerBound.value }
        diagnostics = diagnostics.map { $0.mapped(through: sorted) }
      }
      self.snapshot = newSnapshot
      self.selection = selection
      syncFrameSize()
      needsDisplay = true
    }

    // MARK: - Layout / scrolling

    /// Moves the caret to the start of `line` (0-based, clamped), scrolls it into view and takes focus.
    public func reveal(line: Int) {
      let i = min(max(line, 0), snapshot.lineCount - 1)
      guard let l = try? snapshot.line(at: TextLineIndex(i)) else { return }
      selection = TextSelectionSet(cursor: l.contentRange.lowerBound)
      onSelectionChange?(selection)
      scrollToVisible(NSRect(x: 0, y: CGFloat(i) * lineHeight - 3 * lineHeight, width: 1, height: 7 * lineHeight))
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
      let width = max(knownContentWidth, clipWidth)
      let height = CGFloat(snapshot.lineCount) * lineHeight
      let newSize = NSSize(width: width, height: height)
      guard newSize != frame.size else { return }
      setFrameSize(newSize)
    }

    // MARK: - Hit testing

    /// Converts a point in this view's own (flipped) coordinate space to a
    /// document offset, snapping to the nearest character boundary CoreText
    /// reports for that line.
    public func hitTestOffset(at point: NSPoint) -> UTF8Offset? {
      guard snapshot.lineCount > 0 else { return nil }
      let index = EditorViewGeometry.lineIndex(
        atY: point.y, lineHeight: lineHeight, lineCount: snapshot.lineCount)
      guard
        let (textLine, ctLine) = try? renderer.line(
          at: TextLineIndex(index), in: snapshot, highlights: highlights,
          colorOverrides: tokenColors)
      else { return nil }
      let localX = point.x - textInset
      let charIndex = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localX, y: 0))
      guard charIndex != kCFNotFound else { return nil }
      let position = TextLinePosition<UTF16Unit>(
        line: textLine.index, column: UTF16Offset(charIndex))
      return try? snapshot.offset(at: position, rounding: .down)
    }

    // MARK: - Mouse / selection

    /// A mouse-down inside the existing selection defers to a possible text
    /// drag-out instead of immediately collapsing the selection — see
    /// `mouseDragged`/`ClairEditorView+DragDrop.swift`. `nil` once that
    /// gesture is resolved either way.
    private var pendingSelectionDrag: (downPoint: NSPoint, offset: UTF8Offset)?

    public override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      // A click anywhere unmarks an in-progress IME composition, matching
      // system text views: the click is the user abandoning the candidate
      // in favor of pointing elsewhere.
      if composition != nil { inputContext?.discardMarkedText() }
      let point = convert(event.locationInWindow, from: nil)
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
      caretVisible = true
      needsDisplay = true
      onSelectionChange?(selection)
    }

    public override func becomeFirstResponder() -> Bool {
      caretVisible = true
      startCaretBlink()
      needsDisplay = true
      return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
      caretTimer?.invalidate()
      caretTimer = nil
      needsDisplay = true
      return super.resignFirstResponder()
    }

    private func startCaretBlink() {
      caretTimer?.invalidate()
      caretTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.caretVisible.toggle()
          self.needsDisplay = true
        }
      }
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

      let visible = EditorViewGeometry.visibleLineRange(
        visibleRect: dirtyRect, lineHeight: lineHeight, lineCount: snapshot.lineCount)
      guard !visible.isEmpty else { return }

      let composingLine = self.composingLine
      var measuredWidth: CGFloat = 0
      for index in visible {
        let built: (line: TextLine, ctLine: CTLine)?
        if let composition, composingLine?.value == index {
          built = try? renderer.composedLine(
            at: TextLineIndex(index), in: snapshot, composition: composition)
        } else {
          built = try? renderer.line(
            at: TextLineIndex(index), in: snapshot, highlights: highlights,
            colorOverrides: tokenColors)
        }
        guard let (textLine, ctLine) = built else { continue }
        let top = EditorViewGeometry.lineOrigin(index, lineHeight: lineHeight)
        // A composing line's local UTF-16 offsets no longer line up with the
        // committed buffer (the composition text is spliced in over it), so
        // selection/caret overlays — which are computed from committed
        // coordinates — are skipped for exactly that one line while it is
        // composing (`INV-INPUT-009`: the OS candidate window is the only
        // composition cursor shown).
        let isComposingLine = composingLine?.value == index

        if !isComposingLine {
          drawSelections(for: textLine, ctLine: ctLine, top: top, context: context)
        }
        drawText(ctLine, top: top, context: context)
        if gutterWidth > 0 { drawLineNumber(index, top: top, context: context) }
        if !isComposingLine {
          drawDiagnostics(for: textLine, ctLine: ctLine, top: top, context: context)
          drawCarets(for: textLine, ctLine: ctLine, top: top, context: context)
        }

        let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        measuredWidth = max(measuredWidth, width + textInset * 2)
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
    private func drawText(_ ctLine: CTLine, top: CGFloat, context: CGContext) {
      context.saveGState()
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      context.textPosition = CGPoint(x: textInset, y: top + baselineShift + ascent)
      CTLineDraw(ctLine, context)
      context.restoreGState()
    }

    /// Right-aligned 1-based number in the gutter, 12pt from the text column edge.
    private func drawLineNumber(_ index: Int, top: CGFloat, context: CGContext) {
      let current = selection.selections.first.flatMap { try? snapshot.position(at: $0.head, columnUnit: UTF8Unit.self, rounding: .down).line.value } == index
      let s = NSAttributedString(
        string: String(index + 1), attributes: [.font: font, .foregroundColor: current ? currentLineNumberColor : lineNumberColor])
      let line = CTLineCreateWithAttributedString(s)
      let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      context.saveGState()
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      context.textPosition = CGPoint(x: gutterWidth - 12 - width, y: top + baselineShift + ascent)
      CTLineDraw(line, context)
      context.restoreGState()
    }

    private func drawSelections(
      for textLine: TextLine, ctLine: CTLine, top: CGFloat, context: CGContext
    ) {
      guard selection.selections.contains(where: { !$0.isEmpty }) else { return }
      context.setFillColor(selectionColor.cgColor)
      for range in selection.selections.map(\.range) {
        guard let local = try? localUTF16Range(of: range, clippedTo: textLine, in: snapshot) else {
          continue
        }
        let x1 = CTLineGetOffsetForStringIndex(ctLine, local.lowerBound, nil)
        let x2 = CTLineGetOffsetForStringIndex(ctLine, local.upperBound, nil)
        context.fill(CGRect(x: textInset + x1, y: top, width: x2 - x1, height: lineHeight))
      }
    }

    private func drawCarets(
      for textLine: TextLine, ctLine: CTLine, top: CGFloat, context: CGContext
    ) {
      guard caretVisible, window?.firstResponder === self else { return }
      for cursor in selection.selections where cursor.isEmpty {
        guard
          let position = try? snapshot.position(
            at: cursor.head, columnUnit: UTF16Unit.self, rounding: .down),
          position.line == textLine.index
        else { continue }
        let x = CTLineGetOffsetForStringIndex(ctLine, position.column.value, nil)
        context.setFillColor(caretColor.cgColor)
        context.fill(CGRect(x: textInset + x, y: top, width: 1.5, height: lineHeight))
      }
    }

    private func drawDiagnostics(
      for textLine: TextLine, ctLine: CTLine, top: CGFloat, context: CGContext
    ) {
      for diagnostic in diagnostics {
        guard
          let local = try? localUTF16Range(of: diagnostic.range, clippedTo: textLine, in: snapshot)
        else { continue }
        let x1 = textInset + CTLineGetOffsetForStringIndex(ctLine, local.lowerBound, nil)
        let x2 = textInset + CTLineGetOffsetForStringIndex(ctLine, local.upperBound, nil)
        drawSquiggle(
          from: x1, to: x2, baseline: top + lineHeight - 2, color: diagnostic.severity.color,
          context: context)
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

import ClairV2EditorCore

#if os(macOS)
  import AppKit
  import CoreText

  /// The macOS native editor viewport (E06): a custom `NSView` that lays
  /// out, via CoreText, only the document lines currently intersecting its
  /// visible rect — never the whole document, never one subview per line.
  /// Meant as an `NSScrollView` document view; scrolling itself is standard
  /// AppKit clipping, not reimplemented here.
  ///
  /// `NSTextInputClient`/IME, clipboard, drag/drop, and accessibility are
  /// E07's scope, not this view's: `ClairEditorView` only renders a given
  /// snapshot/selection and turns mouse hits into selection changes.
  public final class ClairEditorView: NSView {
    public private(set) var snapshot: TextSnapshot
    public private(set) var selection: TextSelectionSet
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
    /// Called after a mouse-driven selection change. The owner is
    /// responsible for reconciling this back into its
    /// `EditorTransactionManager`; this view does not own that state.
    public var onSelectionChange: ((TextSelectionSet) -> Void)?

    private let renderer: EditorLineRenderer
    private let font: NSFont
    private let ascent: CGFloat
    /// The fixed per-row height every line occupies (no soft-wrap, one row
    /// per document line). Exposed so a host can scroll a given line into
    /// view.
    public let lineHeight: CGFloat
    private let textInset: CGFloat = 4
    private var knownContentWidth: CGFloat = 0
    private var caretVisible = true
    private var caretTimer: Timer?
    private var dragAnchor: UTF8Offset?
    private var dragFixedSelections: [TextSelection] = []

    public init(
      snapshot: TextSnapshot, selection: TextSelectionSet,
      font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    ) {
      self.snapshot = snapshot
      self.selection = selection
      self.font = font
      self.renderer = EditorLineRenderer(font: font)
      self.ascent = font.ascender
      self.lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
      super.init(frame: .zero)
      wantsLayer = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
      fatalError("ClairEditorView does not support coder-based restoration")
    }

    // `NSView` subclasses are implicitly `@MainActor`, and a plain `deinit`
    // runs `nonisolated` regardless, so it cannot touch `caretTimer` (same
    // reasoning as `ClairV2GhosttySurfaceView`'s `isolated deinit`).
    isolated deinit {
      caretTimer?.invalidate()
      NotificationCenter.default.removeObserver(self)
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

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
      self.snapshot = newSnapshot
      self.selection = selection
      syncFrameSize()
      needsDisplay = true
    }

    // MARK: - Layout / scrolling

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

    // ponytail: single click/drag and cmd-click add-cursor cover the
    // acceptance criteria (hit test -> caret/selection). Double/triple-click
    // word/line selection is a UX nicety, not required here — add when E07
    // wires up the rest of the input surface.
    public override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      guard let offset = hitTestOffset(at: convert(event.locationInWindow, from: nil)) else {
        return
      }
      dragAnchor = offset
      dragFixedSelections = event.modifierFlags.contains(.command) ? selection.selections : []
      updateDragSelection(head: offset)
    }

    public override func mouseDragged(with event: NSEvent) {
      guard let offset = hitTestOffset(at: convert(event.locationInWindow, from: nil)) else {
        return
      }
      updateDragSelection(head: offset)
    }

    public override func mouseUp(with event: NSEvent) {
      dragAnchor = nil
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

    public override func draw(_ dirtyRect: NSRect) {
      guard let context = NSGraphicsContext.current?.cgContext else { return }
      context.setFillColor(NSColor.textBackgroundColor.cgColor)
      context.fill(dirtyRect)

      let visible = EditorViewGeometry.visibleLineRange(
        visibleRect: dirtyRect, lineHeight: lineHeight, lineCount: snapshot.lineCount)
      guard !visible.isEmpty else { return }

      var measuredWidth: CGFloat = 0
      for index in visible {
        guard
          let (textLine, ctLine) = try? renderer.line(
            at: TextLineIndex(index), in: snapshot, highlights: highlights,
            colorOverrides: tokenColors)
        else { continue }
        let top = EditorViewGeometry.lineOrigin(index, lineHeight: lineHeight)

        drawSelections(for: textLine, ctLine: ctLine, top: top, context: context)
        drawText(ctLine, top: top, context: context)
        drawDiagnostics(for: textLine, ctLine: ctLine, top: top, context: context)
        drawCarets(for: textLine, ctLine: ctLine, top: top, context: context)

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
      context.textPosition = CGPoint(x: textInset, y: top + ascent)
      CTLineDraw(ctLine, context)
      context.restoreGState()
    }

    private func drawSelections(
      for textLine: TextLine, ctLine: CTLine, top: CGFloat, context: CGContext
    ) {
      guard selection.selections.contains(where: { !$0.isEmpty }) else { return }
      context.setFillColor(NSColor.selectedTextBackgroundColor.cgColor)
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
        context.setFillColor(NSColor.textColor.cgColor)
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

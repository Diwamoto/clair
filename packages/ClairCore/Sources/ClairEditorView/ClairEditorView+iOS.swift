import ClairEditorCore

#if os(iOS)
  import CoreText
  import UIKit

  /// The iOS/iPadOS native editor viewport (E08): a `UIView` counterpart to
  /// `ClairEditorView.swift`'s AppKit `NSView`, built on the same
  /// viewport-virtualized CoreText line cache (`EditorLineRenderer`,
  /// `EditorViewGeometry`) and the same `ClairEditorCore` transaction/
  /// selection model — only lines intersecting the drawn rect are laid
  /// out, never the whole document, never one subview per line.
  ///
  /// Meant as a `UIScrollView`'s single content subview: this view sizes
  /// its own `frame` to `lineCount * lineHeight` (`syncFrameSize`, called
  /// from `layoutSubviews` so a host resizing the enclosing scroll view —
  /// rotation, split view, keyboard avoidance — is picked up automatically
  /// the same way AppKit's clip-view bounds notification drives
  /// `ClairEditorView.swift`'s `syncFrameSize`); the host owns the actual
  /// `UIScrollView` and its `contentSize`/`contentOffset`, same division of
  /// responsibility as the macOS `NSScrollView` document-view precedent.
  ///
  /// This view never touches `TextBuffer`/`EditorTransactionManager`
  /// directly, same split E06/E07 established for macOS:
  /// `onCommitEdits` (`ClairEditorView+iOSEditing.swift`,
  /// `ClairEditorView+iOSTextInput.swift`) is how typing, IME commits, and
  /// clipboard ask the owner to apply an edit and reflect the result back
  /// via `applyEdits`.
  public final class ClairEditorView: UIView {
    public private(set) var snapshot: TextSnapshot
    // `internal(set)`, not `private(set)`: the touch/keyboard/IME
    // extensions (separate files, same module) update selection locally
    // the same way this file's touch handling always has.
    public internal(set) var selection: TextSelectionSet
    public var highlights: [EditorHighlightSpan] = [] {
      didSet {
        highlightIndex = EditorSpanIndex(highlights, range: \.range)
        renderer.invalidateAll()
        setNeedsDisplay()
      }
    }
    public var diagnostics: [EditorDiagnosticSpan] = [] {
      didSet {
        diagnosticIndex = EditorSpanIndex(diagnostics, range: \.range)
        setNeedsDisplay()
      }
    }
    var highlightIndex = EditorSpanIndex<EditorHighlightSpan>([], range: \.range)
    var diagnosticIndex = EditorSpanIndex<EditorDiagnosticSpan>([], range: \.range)
    public var tokenColors: [EditorTokenKind: PlatformColor] = [:] {
      didSet {
        renderer.invalidateAll()
        setNeedsDisplay()
      }
    }
    /// Called after a touch- or keyboard-driven selection change. The
    /// owner is responsible for reconciling this back into its
    /// `EditorTransactionManager`; this view does not own that state.
    public var onSelectionChange: ((TextSelectionSet) -> Void)?
    /// Called with one transaction's worth of edits — typing, an IME
    /// commit, cut, or paste — for the owner to apply through its
    /// `EditorTransactionManager` (one call is one undo unit) and reflect
    /// back via `applyEdits`. See `ClairEditorView+iOSTextInput.swift`,
    /// `ClairEditorView+iOSEditing.swift`.
    public var onCommitEdits: (([TextEdit]) -> Void)?

    let renderer: EditorLineRenderer
    let font: PlatformFont
    let ascent: CGFloat
    /// The fixed per-row height every line occupies (no soft-wrap, one row
    /// per document line).
    public let lineHeight: CGFloat
    let textInset: CGFloat = 4
    var knownContentWidth: CGFloat = 0
    /// The live IME composition, if any
    /// (`ClairEditorView+iOSTextInput.swift`). A view-local overlay only —
    /// see `EditorComposition`'s doc comment.
    var composition: EditorComposition?

    // `UITextInput` requirements that need real storage, not just a
    // computed property (`ClairEditorView+iOSTextInput.swift` implements
    // the rest of the protocol): the system's text-interaction machinery
    // (`UITextInteraction`, added in `init` below) sets `inputDelegate` to
    // itself so it hears about text/selection changes, and `tokenizer`
    // backs word/line granularity for double-tap and drag-handle
    // extension. No caret/selection overlay is drawn by this view itself
    // (unlike the macOS `NSTextInputClient` path, which has no system
    // equivalent) — `caretRect(for:)`/`selectionRects(for:)` below feed
    // UIKit's own `UITextSelectionView`, the same "do not hand-roll what
    // UITextInteraction already provides" reuse this task calls for.
    public weak var inputDelegate: UITextInputDelegate?
    public lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    public init(
      snapshot: TextSnapshot, selection: TextSelectionSet,
      font: PlatformFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    ) {
      self.snapshot = snapshot
      self.selection = selection
      self.font = font
      self.renderer = EditorLineRenderer(font: font)
      self.ascent = font.ascender
      self.lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
      super.init(frame: .zero)
      backgroundColor = .systemBackground
      isOpaque = true
      contentMode = .redraw
      setUpTouchInteraction()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
      fatalError("ClairEditorView does not support coder-based restoration")
    }

    public override var canBecomeFirstResponder: Bool { true }

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
      setNeedsDisplay()
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
      setNeedsDisplay()
    }

    // MARK: - Layout / scrolling

    public override func layoutSubviews() {
      super.layoutSubviews()
      syncFrameSize()
    }

    func syncFrameSize() {
      let availableWidth = superview?.bounds.width ?? bounds.width
      let width = max(knownContentWidth, availableWidth)
      let height = CGFloat(snapshot.lineCount) * lineHeight
      let newSize = CGSize(width: width, height: height)
      guard newSize != frame.size else { return }
      frame.size = newSize
      if let scrollView = superview as? UIScrollView {
        scrollView.contentSize = newSize
      }
    }

    // MARK: - Hit testing

    /// Converts a point in this view's own coordinate space (UIKit's
    /// default top-down space already matches the top-down space
    /// `EditorViewGeometry` assumes — unlike AppKit, no `isFlipped`
    /// override is needed) to a document offset, snapping to the nearest
    /// character boundary CoreText reports for that line.
    ///
    /// Goes through `renderedLine(at:)`, not `renderer.line(at:...)`
    /// directly, so a tap/drag on a line with a live IME composition
    /// hit-tests against the actually-drawn composed splice (different
    /// glyph layout/width than the committed buffer) rather than glyph
    /// positions that are no longer on screen; `bufferLocalColumn(
    /// forRenderedLocalUTF16:on:)` then maps the resulting index back to
    /// the buffer's own column before this returns a buffer offset — this
    /// is the one geometry entry point `UITextInput.closestPosition(to:)`
    /// and `characterRange(at:)` are both built on, so getting it wrong
    /// here breaks touch selection during composition specifically.
    public func hitTestOffset(at point: CGPoint) -> UTF8Offset? {
      guard snapshot.lineCount > 0 else { return nil }
      let index = EditorViewGeometry.lineIndex(
        atY: point.y, lineHeight: lineHeight, lineCount: snapshot.lineCount)
      guard let (textLine, ctLine) = renderedLine(at: TextLineIndex(index)) else { return nil }
      let localX = point.x - textInset
      let charIndex = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localX, y: 0))
      guard charIndex != kCFNotFound else { return nil }
      let column = bufferLocalColumn(forRenderedLocalUTF16: charIndex, on: textLine)
      let position = TextLinePosition<UTF16Unit>(line: textLine.index, column: UTF16Offset(column))
      return try? snapshot.offset(at: position, rounding: .down)
    }

    // MARK: - Drawing

    /// The line an active composition sits on, or `nil` when there is none
    /// or it can no longer be located (e.g. a concurrent external edit —
    /// falls back to plain rendering rather than crashing).
    var composingLine: TextLineIndex? {
      guard let composition else { return nil }
      return try? snapshot.position(
        at: composition.replacedRange.lowerBound, columnUnit: UTF8Unit.self
      )
      .line
    }

    /// Unlike `ClairEditorView.swift` (macOS), this `draw(_:)` paints only
    /// glyphs and diagnostics — caret and selection highlight are *not*
    /// drawn here. `UITextInteraction` (`setUpTouchInteraction`) owns a
    /// system `UITextSelectionView` overlay that draws both itself, fed by
    /// this file's `caretRect(for:)`/`selectionRects(for:)`; drawing them
    /// a second time here would double them up (`INV-INPUT-011`, the iOS
    /// counterpart of `INV-INPUT-009`'s "the OS is the only thing that
    /// draws the composition/selection cursor" rule).
    public override func draw(_ rect: CGRect) {
      guard let context = UIGraphicsGetCurrentContext() else { return }
      context.setFillColor(PlatformColor.systemBackground.cgColor)
      context.fill(rect)

      let visible = EditorViewGeometry.visibleLineRange(
        visibleRect: rect, lineHeight: lineHeight, lineCount: snapshot.lineCount)
      guard !visible.isEmpty else { return }

      var measuredWidth: CGFloat = 0
      for index in visible {
        guard let (textLine, ctLine) = renderedLine(at: TextLineIndex(index)) else { continue }
        let top = EditorViewGeometry.lineOrigin(index, lineHeight: lineHeight)
        drawText(ctLine, top: top, context: context)
        drawDiagnostics(for: textLine, ctLine: ctLine, top: top, context: context)

        let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        measuredWidth = max(measuredWidth, width + textInset * 2)
      }
      if measuredWidth > knownContentWidth {
        knownContentWidth = measuredWidth
        syncFrameSize()
      }
    }

    /// `CTLineDraw` assumes a bottom-up text matrix; a `UIView`'s `draw(_:)`
    /// context already has UIKit's top-down flip baked into its CTM (the
    /// same reason AppKit's flipped `NSView` needs this), which mirrors
    /// glyphs unless the text matrix cancels it out locally. Fills
    /// elsewhere in this method need no such adjustment — only text
    /// drawing does.
    private func drawText(_ ctLine: CTLine, top: CGFloat, context: CGContext) {
      context.saveGState()
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      context.textPosition = CGPoint(x: textInset, y: top + ascent)
      CTLineDraw(ctLine, context)
      context.restoreGState()
    }

    private func drawDiagnostics(
      for textLine: TextLine, ctLine: CTLine, top: CGFloat, context: CGContext
    ) {
      for diagnostic in diagnosticIndex.overlapping(textLine.contentRange) {
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
      from x1: CGFloat, to x2: CGFloat, baseline: CGFloat, color: PlatformColor, context: CGContext
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

    public override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became { setNeedsDisplay() }
      return became
    }

    public override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned { setNeedsDisplay() }
      return resigned
    }
  }
#endif

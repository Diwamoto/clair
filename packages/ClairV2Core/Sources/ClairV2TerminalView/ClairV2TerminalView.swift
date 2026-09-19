#if os(iOS)
  import ClairV2EditorView
  import ClairV2GhosttyVT
  import ClairV2MobileKit
  import ClairV2Shared
  import ClairV2Terminal
  import ClairV2Transport
  import CoreText
  import UIKit

  /// The iOS/iPadOS terminal viewport (T05): a minimal, functional `UIView`
  /// over `ClairV2MobileTerminalSession`. Draws whatever
  /// `GhosttyVTScreenSnapshot` the session's VT parser last produced, using
  /// the same "one `CTLine` per visible row" CoreText pattern E06/E08
  /// established for `ClairEditorView` (`EditorLineRenderer`,
  /// `PlatformColor`/`PlatformFont` from `ClairV2EditorView`), but far
  /// simpler: a terminal has no document to virtualize/cache lines across
  /// (`snapshot.lines` is already exactly the rows visible right now,
  /// scrollback included via `ClairV2MobileTerminalSession.scroll`), so
  /// this view lays out fresh `CTLine`s every `draw(_:)` instead of keeping
  /// `EditorLineRenderer`'s per-line cache.
  ///
  /// Deliberately minimal UI, per this task's scope: a fixed-size
  /// monospaced font, no syntax/attribute coloring (`GhosttyVTScreenSnapshot`
  /// is plain text -- see `ClairV2GhosttyVTABI`'s header comment for why),
  /// no scrollbar chrome. The Design canvas/Workbench define no terminal
  /// visual language for iOS yet (`U06` covers Mac; iOS terminal UI polish
  /// is explicitly deferred past this task in the parent plan's Phase 5
  /// sequencing notes) -- this view exists to make the feature work, not to
  /// invent a visual design nothing has approved.
  ///
  /// Row/column count (the underlying `GhosttyVTTerminal`'s grid size) is
  /// never derived from this view's bounds: it always matches the remote
  /// PTY's actual size, synced by `ClairV2MobileTerminalSession.foreground`
  /// from the daemon's attach response. Rotation/safe-area changes only
  /// affect how many of those fixed rows are visible at once (`layoutSubviews`
  /// recomputes `visibleRowCount` from the safe-area-inset bounds height);
  /// they never resize the remote terminal, matching the existing "mobile
  /// viewport never implicitly changes desktop rows/columns" invariant
  /// already recorded for `T06`.
  public final class ClairV2TerminalView: UIView, UIKeyInput {
    private let session: ClairV2MobileTerminalSession
    private let font: PlatformFont
    private let lineHeight: CGFloat
    private let charWidth: CGFloat
    private let ascent: CGFloat
    private let textInset: CGFloat = 4

    private var latestSnapshot: GhosttyVTScreenSnapshot?
    private var selectionAnchor: (column: Int, row: Int)?
    private var selectionCurrent: (column: Int, row: Int)?

    /// Cached attach context for the lifecycle-notification-driven
    /// background/foreground handling below. Set by `attach(scope:
    /// generation:connection:)`.
    private var attachContext: (scope: ResourceScope, generation: UInt64, connection: ClairAuthenticatedConnection)?

    /// Called after a touch-selection drag ends with non-empty selected
    /// text, already written to `UIPasteboard.general`. The host decides
    /// whether/how to show a "Copied" affordance -- this view does not
    /// invent one (see the type's doc comment on visual-design scope).
    public var onSelectionCopied: ((String) -> Void)?

    public init(
      session: ClairV2MobileTerminalSession,
      font: PlatformFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    ) {
      self.session = session
      self.font = font
      self.ascent = font.ascender
      self.lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
      self.charWidth = font.advance(forCharacter: "M")
      super.init(frame: .zero)
      backgroundColor = .black
      isOpaque = true
      contentMode = .redraw
      clipsToBounds = true
      isUserInteractionEnabled = true
      setUpGestures()
      session.onScreenUpdate = { [weak self] snapshot in
        self?.apply(snapshot)
      }
      NotificationCenter.default.addObserver(
        self, selector: #selector(handleDidEnterBackground),
        name: UIApplication.didEnterBackgroundNotification, object: nil)
      NotificationCenter.default.addObserver(
        self, selector: #selector(handleWillEnterForeground),
        name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
      fatalError("ClairV2TerminalView does not support coder-based restoration")
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    public override var canBecomeFirstResponder: Bool { true }

    // MARK: - Attach lifecycle

    /// Starts (or resumes) the remote session attach and remembers `scope`/
    /// `generation`/`connection` so the background/foreground
    /// `UIApplication` notifications below can detach/reattach without the
    /// host having to re-supply them on every transition.
    public func attach(
      scope: ResourceScope, generation: UInt64, connection: ClairAuthenticatedConnection
    ) {
      attachContext = (scope, generation, connection)
      Task { [session] in
        await session.foreground(scope: scope, generation: generation, on: connection)
      }
    }

    @objc private func handleDidEnterBackground() {
      Task { [session] in await session.background() }
    }

    @objc private func handleWillEnterForeground() {
      guard let attachContext else { return }
      Task { [session] in
        await session.foreground(
          scope: attachContext.scope, generation: attachContext.generation,
          on: attachContext.connection)
      }
    }

    // MARK: - Rendering

    private func apply(_ snapshot: GhosttyVTScreenSnapshot) {
      latestSnapshot = snapshot
      setNeedsDisplay()
    }

    var visibleRowCount: Int {
      max(1, Int((bounds.height - safeAreaInsets.top - safeAreaInsets.bottom) / lineHeight))
    }

    public override func layoutSubviews() {
      super.layoutSubviews()
      setNeedsDisplay()
    }

    public override func safeAreaInsetsDidChange() {
      super.safeAreaInsetsDidChange()
      setNeedsDisplay()
    }

    public override func draw(_ rect: CGRect) {
      guard let context = UIGraphicsGetCurrentContext() else { return }
      context.setFillColor(UIColor.black.cgColor)
      context.fill(rect)
      guard let snapshot = latestSnapshot else { return }

      let top = safeAreaInsets.top
      let rowsToDraw = min(snapshot.lines.count, visibleRowCount)
      for index in 0..<rowsToDraw {
        let line = snapshot.lines[index]
        let attributed = NSAttributedString(
          string: line, attributes: [.font: font, .foregroundColor: UIColor.white])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let lineTop = top + CGFloat(index) * lineHeight
        drawSelectionHighlight(forRow: index, top: lineTop, context: context)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: textInset, y: lineTop + ascent)
        CTLineDraw(ctLine, context)
        context.restoreGState()
      }

      if snapshot.cursor.visible, snapshot.cursor.row < rowsToDraw {
        let cursorRect = CGRect(
          x: textInset + CGFloat(snapshot.cursor.column) * charWidth,
          y: top + CGFloat(snapshot.cursor.row) * lineHeight,
          width: charWidth, height: lineHeight)
        context.setFillColor(UIColor.white.withAlphaComponent(0.5).cgColor)
        context.fill(cursorRect)
      }
    }

    private func drawSelectionHighlight(forRow row: Int, top: CGFloat, context: CGContext) {
      guard let range = selectionColumnRange(forRow: row) else { return }
      let rect = CGRect(
        x: textInset + CGFloat(range.lowerBound) * charWidth, y: top,
        width: CGFloat(range.upperBound - range.lowerBound + 1) * charWidth, height: lineHeight)
      context.setFillColor(UIColor.white.withAlphaComponent(0.3).cgColor)
      context.fill(rect)
    }

    /// The selected column range on `row`, or `nil` if `row` is outside the
    /// (row-ordered, possibly multi-row) active selection. Linear selection
    /// only (no rectangle/block mode, matching `GhosttyVTTerminal.
    /// selectedText`'s `rectangle: false`): a fully selected middle row
    /// spans the whole line width.
    private func selectionColumnRange(forRow row: Int) -> ClosedRange<Int>? {
      guard let anchor = selectionAnchor, let current = selectionCurrent else { return nil }
      let (start, end) =
        (anchor.row, anchor.column) <= (current.row, current.column) ? (anchor, current) : (current, anchor)
      guard row >= start.row, row <= end.row else { return nil }
      let maxColumn = max(1, Int(bounds.width / charWidth))
      let lowerBound = row == start.row ? start.column : 0
      let upperBound = row == end.row ? end.column : maxColumn
      guard lowerBound <= upperBound else { return nil }
      return lowerBound...upperBound
    }

    private func cell(at point: CGPoint) -> (column: Int, row: Int) {
      let column = max(0, Int((point.x - textInset) / charWidth))
      let row = max(0, Int((point.y - safeAreaInsets.top) / lineHeight))
      return (column, row)
    }

    // MARK: - Touch scroll + selection

    private func setUpGestures() {
      let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
      addGestureRecognizer(pan)
      let longPress = UILongPressGestureRecognizer(
        target: self, action: #selector(handleLongPress(_:)))
      addGestureRecognizer(longPress)
    }

    private var panLastTranslationY: CGFloat = 0

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
      // While an active selection drag is in progress (started by the long
      // press below), pan extends the selection instead of scrolling.
      guard selectionAnchor == nil else {
        selectionCurrent = cell(at: gesture.location(in: self))
        setNeedsDisplay()
        return
      }
      switch gesture.state {
      case .began:
        panLastTranslationY = 0
      case .changed:
        let translation = gesture.translation(in: self).y
        let deltaRows = Int((translation - panLastTranslationY) / lineHeight)
        if deltaRows != 0 {
          // Dragging content downward (positive translation) reveals rows
          // above -- scroll the viewport up (negative rows).
          session.scroll(byRows: -deltaRows)
          panLastTranslationY += CGFloat(deltaRows) * lineHeight
        }
      default:
        break
      }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
      switch gesture.state {
      case .began:
        becomeFirstResponder()
        let start = cell(at: gesture.location(in: self))
        selectionAnchor = start
        selectionCurrent = start
        setNeedsDisplay()
      case .changed:
        selectionCurrent = cell(at: gesture.location(in: self))
        setNeedsDisplay()
      case .ended, .cancelled:
        finishSelection()
      default:
        break
      }
    }

    private func finishSelection() {
      defer {
        selectionAnchor = nil
        selectionCurrent = nil
        setNeedsDisplay()
      }
      guard let anchor = selectionAnchor, let current = selectionCurrent else { return }
      let start = GhosttyVTViewportPoint(column: anchor.column, row: anchor.row)
      let end = GhosttyVTViewportPoint(column: current.column, row: current.row)
      guard let text = session.selectedText(from: start, to: end) else { return }
      UIPasteboard.general.string = text
      onSelectionCopied?(text)
    }

    // MARK: - Hardware keyboard

    public override var keyCommands: [UIKeyCommand]? {
      [
        UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(sendUp)),
        UIKeyCommand(
          input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(sendDown)),
        UIKeyCommand(
          input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(sendLeft)),
        UIKeyCommand(
          input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(sendRight)),
        UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(sendEscape)),
        UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(sendTab)),
        UIKeyCommand(input: "c", modifierFlags: .control, action: #selector(sendControlC)),
        UIKeyCommand(input: "d", modifierFlags: .control, action: #selector(sendControlD)),
        UIKeyCommand(input: "z", modifierFlags: .control, action: #selector(sendControlZ)),
      ]
    }

    @objc private func sendUp() { send(.up) }
    @objc private func sendDown() { send(.down) }
    @objc private func sendLeft() { send(.left) }
    @objc private func sendRight() { send(.right) }
    @objc private func sendEscape() { send(.escape) }
    @objc private func sendTab() { send(.tab) }
    @objc private func sendControlC() { send(.control("c")) }
    @objc private func sendControlD() { send(.control("d")) }
    @objc private func sendControlZ() { send(.control("z")) }

    private func send(_ key: ClairV2TerminalKey) {
      Task { [session] in await session.sendKey(key) }
    }

    // MARK: - UIKeyInput (software keyboard + most physical-keyboard text)

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
      guard !text.isEmpty else { return }
      if text == "\n" {
        send(.return)
      } else {
        send(.text(text))
      }
    }

    public func deleteBackward() {
      send(.backspace)
    }
  }

  extension UIFont {
    /// The advance width of one character in this font, used as the fixed
    /// per-cell width for the monospaced grid (mirrors `ClairEditorView`'s
    /// `ascent`/`lineHeight` metrics derivation, one line lower since a
    /// monospaced terminal only needs a single representative glyph, not a
    /// per-line `CTLineGetTypographicBounds`).
    fileprivate func advance(forCharacter character: Character) -> CGFloat {
      let attributed = NSAttributedString(string: String(character), attributes: [.font: self])
      let line = CTLineCreateWithAttributedString(attributed)
      return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
  }
#endif

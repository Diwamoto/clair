import AppKit
import SwiftUI

@MainActor
final class TerminalGrid {
  nonisolated(unsafe) private let handle: OpaquePointer

  init?(rows: UInt16, columns: UInt16) {
    guard let handle = clair_vterm_create(Int32(rows), Int32(columns)) else {
      return nil
    }
    self.handle = handle
  }

  deinit {
    clair_vterm_destroy(handle)
  }

  var rows: Int {
    Int(clair_vterm_rows(handle))
  }

  var columns: Int {
    Int(clair_vterm_columns(handle))
  }

  var scrollbackRows: Int {
    Int(clair_vterm_scrollback_rows(handle))
  }

  var displayedRows: Int {
    scrollbackRows + rows
  }

  func feed(_ data: Data) {
    guard !data.isEmpty else {
      return
    }
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        return
      }
      clair_vterm_feed(handle, baseAddress, bytes.count)
    }
  }

  func resize(rows: UInt16, columns: UInt16) {
    clair_vterm_resize(handle, Int32(rows), Int32(columns))
  }

  func reset() {
    clair_vterm_reset(handle)
  }

  func cell(row: Int, column: Int) -> ClairVTermCell? {
    var cell = ClairVTermCell()
    guard clair_vterm_cell_at(handle, Int32(row), Int32(column), &cell) else {
      return nil
    }
    return cell
  }

  func displayedCell(row: Int, column: Int) -> ClairVTermCell? {
    guard row >= 0, column >= 0 else {
      return nil
    }
    if row < scrollbackRows {
      var cell = ClairVTermCell()
      guard clair_vterm_scrollback_cell_at(handle, Int32(row), Int32(column), &cell) else {
        return nil
      }
      return cell
    }
    return cell(row: row - scrollbackRows, column: column)
  }

  var cursor: (row: Int, column: Int, visible: Bool) {
    var row: Int32 = 0
    var column: Int32 = 0
    var visible = false
    clair_vterm_cursor(handle, &row, &column, &visible)
    return (Int(row), Int(column), visible)
  }
}

@MainActor
struct TerminalSurfaceView: NSViewRepresentable {
  let session: TerminalSession

  func makeNSView(context: Context) -> NativeTerminalView {
    NativeTerminalView(session: session)
  }

  func updateNSView(_ nsView: NativeTerminalView, context: Context) {
    nsView.refreshLayout()
  }

  static func dismantleNSView(_ nsView: NativeTerminalView, coordinator: ()) {
    nsView.detach()
  }
}
@MainActor
final class NativeTerminalView: NSView {
  private let scrollView: NSScrollView
  private let textView: TerminalTextView
  private let session: TerminalSession
  private let grid: TerminalGrid
  private var eventObserverID: UUID?

  init(session: TerminalSession) {
    self.session = session
    scrollView = NSScrollView(frame: .zero)
    textView = TerminalTextView(frame: .zero)
    guard
      let terminalGrid = TerminalGrid(
        rows: session.dimensions.rows,
        columns: session.dimensions.columns
      )
    else {
      fatalError("Could not create the libvterm terminal grid.")
    }
    grid = terminalGrid
    super.init(frame: .zero)

    wantsLayer = true
    layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

    textView.inputHandler = { [weak self] data in
      self?.session.sendInput(data)
    }
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.documentView = textView
    addSubview(scrollView)

    textView.grid = grid
    eventObserverID = session.addEventObserver { [weak self] event in
      switch event {
      case .output(let output):
        self?.render(output)
      case .screenReset(let marker):
        self?.reset(with: marker)
      case .attached, .bell, .exited, .failed:
        return
      }
    }
    textView.render(grid)
  }

  required init?(coder: NSCoder) {
    fatalError("NativeTerminalView does not support NSCoder initialization.")
  }

  override func layout() {
    super.layout()
    scrollView.frame = bounds
    refreshLayout()
  }

  func refreshLayout() {
    let contentSize = scrollView.contentView.bounds.size
    let cell = textView.cellSize
    guard cell.width > 0, cell.height > 0 else {
      return
    }
    let columns = UInt16(max(2, min(1_000, Int(contentSize.width / cell.width))))
    let rows = UInt16(max(2, min(1_000, Int(contentSize.height / cell.height))))
    grid.resize(rows: rows, columns: columns)
    textView.render(grid)
    session.resize(rows: rows, columns: columns)
  }

  func detach() {
    if let eventObserverID {
      session.removeEventObserver(eventObserverID)
      self.eventObserverID = nil
    }
    textView.inputHandler = nil
  }

  private func render(_ output: Data) {
    let documentMaxY = scrollView.documentView?.bounds.maxY ?? 0
    let visibleMaxY = scrollView.contentView.bounds.maxY
    let wasAtBottom =
      visibleMaxY >= documentMaxY - scrollView.contentView.bounds.height - 24
    grid.feed(output)
    textView.render(grid)
    if wasAtBottom {
      textView.scroll(NSPoint(x: 0, y: textView.bounds.maxY))
    }
  }

  private func reset(with marker: Data) {
    grid.reset()
    grid.feed(marker)
    textView.render(grid)
    textView.scroll(NSPoint(x: 0, y: textView.bounds.maxY))
  }
}

@MainActor
final class TerminalTextView: NSTextView {
  var inputHandler: ((Data) -> Void)?
  var grid: TerminalGrid?

  private let terminalTextStorage: NSTextStorage
  private let terminalLayoutManager: NSLayoutManager
  private let terminalTextContainer: NSTextContainer
  private var markedTextValue = ""
  private var selectionAnchor: GridPosition?
  private var selectionEnd: GridPosition?

  let cellSize: CGSize = {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let width = ("W" as NSString).size(withAttributes: [.font: font]).width
    let height = ceil(font.ascender - font.descender + font.leading)
    return CGSize(width: max(1, width), height: max(1, height))
  }()

  override var acceptsFirstResponder: Bool {
    true
  }

  override var isFlipped: Bool {
    true
  }

  override init(frame frameRect: NSRect) {
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(
      containerSize: NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
    )
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    terminalTextStorage = textStorage
    terminalLayoutManager = layoutManager
    terminalTextContainer = textContainer
    super.init(frame: frameRect, textContainer: textContainer)
    isEditable = false
    isSelectable = true
    isRichText = false
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    allowsUndo = false
    drawsBackground = true
    backgroundColor = .textBackgroundColor
    textColor = .textColor
    insertionPointColor = .textColor
    font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textContainerInset = NSSize(width: 12, height: 12)
    minSize = NSSize(width: 0, height: 0)
    maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    isVerticallyResizable = true
    isHorizontallyResizable = true
    self.textContainer?.widthTracksTextView = false
    self.textContainer?.heightTracksTextView = false
  }

  required init?(coder: NSCoder) {
    fatalError("TerminalTextView does not support NSCoder initialization.")
  }

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers == .command,
      event.charactersIgnoringModifiers?.lowercased() == "c"
    {
      copy(nil)
      return
    }
    if modifiers.contains(.command) {
      super.keyDown(with: event)
      return
    }
    if let keyData = TerminalKeySequence.data(for: event) {
      inputHandler?(keyData)
      return
    }
    interpretKeyEvents([event])
  }

  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    let text: String?
    if let string = insertString as? String {
      text = string
    } else if let attributedString = insertString as? NSAttributedString {
      text = attributedString.string
    } else {
      text = nil
    }
    guard let text, !text.isEmpty else {
      return
    }
    markedTextValue = ""
    inputHandler?(Data(text.utf8))
    needsDisplay = true
  }

  override func setMarkedText(
    _ aString: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    if let string = aString as? String {
      markedTextValue = string
    } else if let attributedString = aString as? NSAttributedString {
      markedTextValue = attributedString.string
    } else {
      markedTextValue = ""
    }
    needsDisplay = true
  }

  override func unmarkText() {
    markedTextValue = ""
    needsDisplay = true
  }

  override func hasMarkedText() -> Bool {
    !markedTextValue.isEmpty
  }

  override func markedRange() -> NSRange {
    guard !markedTextValue.isEmpty else {
      return NSRange(location: NSNotFound, length: 0)
    }
    return NSRange(
      location: string.utf16.count,
      length: markedTextValue.utf16.count
    )
  }

  override func doCommand(by selector: Selector) {
    switch NSStringFromSelector(selector) {
    case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
      inputHandler?(Data([0x0d]))
    case "deleteBackward:":
      inputHandler?(Data([0x7f]))
    case "deleteForward:":
      inputHandler?(Data([0x1b, 0x5b, 0x33, 0x7e]))
    default:
      super.doCommand(by: selector)
    }
  }

  override func copy(_ sender: Any?) {
    guard let selectedText = selectedText(), !selectedText.isEmpty else {
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(selectedText, forType: .string)
  }

  override func mouseDown(with event: NSEvent) {
    guard let position = gridPosition(for: event) else {
      super.mouseDown(with: event)
      return
    }
    selectionAnchor = position
    selectionEnd = position
    window?.makeFirstResponder(self)
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard selectionAnchor != nil, let position = gridPosition(for: event) else {
      super.mouseDragged(with: event)
      return
    }
    selectionEnd = position
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    if let position = gridPosition(for: event), selectionAnchor != nil {
      selectionEnd = position
      needsDisplay = true
      return
    }
    super.mouseUp(with: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.textBackgroundColor.setFill()
    dirtyRect.fill()
    if let grid {
      draw(grid: grid)
    }
    guard !markedTextValue.isEmpty else {
      return
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      .foregroundColor: NSColor.controlAccentColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    let cursor = grid?.cursor ?? (row: 0, column: 0, visible: false)
    let x = textContainerInset.width + CGFloat(cursor.column) * cellSize.width
    let y =
      textContainerInset.height
      + CGFloat((grid?.scrollbackRows ?? 0) + cursor.row) * cellSize.height
    (markedTextValue as NSString).draw(
      at: NSPoint(x: x, y: y),
      withAttributes: attributes
    )
  }

  func render(_ grid: TerminalGrid) {
    let size = NSSize(
      width: textContainerInset.width * 2 + CGFloat(grid.columns) * cellSize.width,
      height: textContainerInset.height * 2 + CGFloat(grid.displayedRows) * cellSize.height
    )
    frame.size = size
    needsDisplay = true
  }

  private func draw(grid: TerminalGrid) {
    let normalFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    let cursor = grid.cursor
    let liveGridStart = grid.scrollbackRows
    for row in 0..<grid.displayedRows {
      for column in 0..<grid.columns {
        guard let cell = grid.displayedCell(row: row, column: column), cell.width > 0 else {
          continue
        }
        let width = CGFloat(cell.width) * cellSize.width
        let rect = NSRect(
          x: textContainerInset.width + CGFloat(column) * cellSize.width,
          y: textContainerInset.height + CGFloat(row) * cellSize.height,
          width: width,
          height: cellSize.height
        )
        let isCursor =
          cursor.visible && liveGridStart + cursor.row == row && cursor.column == column
        var foreground = color(
          red: cell.foreground_red,
          green: cell.foreground_green,
          blue: cell.foreground_blue,
          isDefault: cell.uses_default_foreground,
          fallback: .textColor
        )
        var background = color(
          red: cell.background_red,
          green: cell.background_green,
          blue: cell.background_blue,
          isDefault: cell.uses_default_background,
          fallback: .textBackgroundColor
        )
        if cell.attributes & (1 << 3) != 0 {
          swap(&foreground, &background)
        }
        if isSelected(row: row, column: column) || isCursor {
          background = .selectedTextBackgroundColor
          foreground = .selectedTextColor
        }
        background.setFill()
        rect.fill()

        guard cell.codepoint != 0, cell.attributes & (1 << 5) == 0,
          let scalar = UnicodeScalar(cell.codepoint)
        else {
          continue
        }
        var attributes: [NSAttributedString.Key: Any] = [
          .font: cell.attributes & 1 != 0 ? boldFont : normalFont,
          .foregroundColor: foreground,
        ]
        if cell.attributes & (1 << 1) != 0 {
          attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if cell.attributes & (1 << 4) != 0 {
          attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        let baseline =
          rect.minY + (cellSize.height - normalFont.ascender + normalFont.descender) / 2
        String(scalar).draw(at: NSPoint(x: rect.minX, y: baseline), withAttributes: attributes)
      }
    }
  }

  private func color(
    red: UInt8,
    green: UInt8,
    blue: UInt8,
    isDefault: Bool,
    fallback: NSColor
  ) -> NSColor {
    guard !isDefault else {
      return fallback
    }
    return NSColor(
      srgbRed: CGFloat(red) / 255,
      green: CGFloat(green) / 255,
      blue: CGFloat(blue) / 255,
      alpha: 1
    )
  }

  private func gridPosition(for event: NSEvent) -> GridPosition? {
    guard let grid else {
      return nil
    }
    let point = convert(event.locationInWindow, from: nil)
    let column = Int((point.x - textContainerInset.width) / cellSize.width)
    let row = Int((point.y - textContainerInset.height) / cellSize.height)
    guard row >= 0, row < grid.displayedRows, column >= 0, column < grid.columns else {
      return nil
    }
    return GridPosition(row: row, column: column)
  }

  private func isSelected(row: Int, column: Int) -> Bool {
    guard let range = selectionRange else {
      return false
    }
    return range.contains(GridPosition(row: row, column: column))
  }

  private var selectionRange: GridSelection? {
    guard let selectionAnchor, let selectionEnd, selectionAnchor != selectionEnd else {
      return nil
    }
    return GridSelection(
      start: min(selectionAnchor, selectionEnd), end: max(selectionAnchor, selectionEnd))
  }

  private func selectedText() -> String? {
    guard let grid, let range = selectionRange else {
      return nil
    }
    var lines: [String] = []
    for row in range.start.row...range.end.row {
      let startColumn = row == range.start.row ? range.start.column : 0
      let endColumn = row == range.end.row ? range.end.column : grid.columns - 1
      var line = ""
      for column in startColumn...endColumn {
        guard let cell = grid.displayedCell(row: row, column: column), cell.width > 0,
          cell.codepoint != 0, let scalar = UnicodeScalar(cell.codepoint)
        else {
          line.append(" ")
          continue
        }
        line.unicodeScalars.append(scalar)
      }
      lines.append(line.trimmingCharacters(in: .whitespaces))
    }
    return lines.joined(separator: "\n")
  }
}

private struct GridPosition: Comparable, Equatable {
  let row: Int
  let column: Int

  static func < (lhs: GridPosition, rhs: GridPosition) -> Bool {
    lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
  }
}

private struct GridSelection {
  let start: GridPosition
  let end: GridPosition

  func contains(_ position: GridPosition) -> Bool {
    position >= start && position <= end
  }
}

enum TerminalKeySequence {
  private static let controlKeyCodes: [UInt16: UInt8] = [
    0: 0x01, 11: 0x02, 8: 0x03, 2: 0x04, 14: 0x05, 3: 0x06,
    5: 0x07, 4: 0x08, 34: 0x09, 38: 0x0A, 40: 0x0B, 37: 0x0C,
    46: 0x0D, 45: 0x0E, 31: 0x0F, 35: 0x10, 12: 0x11, 15: 0x12,
    1: 0x13, 17: 0x14, 32: 0x15, 9: 0x16, 13: 0x17, 7: 0x18,
    16: 0x19, 6: 0x1A, 33: 0x1B, 42: 0x1C, 30: 0x1D,
  ]

  static func data(for event: NSEvent) -> Data? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.control), let controlByte = controlByte(for: event) {
      return Data([controlByte])
    }

    switch event.keyCode {
    case 36, 76:
      return Data([0x0d])
    case 48 where modifiers.contains(.shift):
      return Data([0x1b, 0x5b, 0x5a])
    case 48:
      return Data([0x09])
    case 51:
      return Data([0x7f])
    case 53:
      return Data([0x1b])
    case 123:
      return Data([0x1b, 0x5b, 0x44])
    case 124:
      return Data([0x1b, 0x5b, 0x43])
    case 125:
      return Data([0x1b, 0x5b, 0x42])
    case 126:
      return Data([0x1b, 0x5b, 0x41])
    case 115:
      return Data([0x1b, 0x5b, 0x48])
    case 119:
      return Data([0x1b, 0x5b, 0x46])
    case 116:
      return Data([0x1b, 0x5b, 0x35, 0x7e])
    case 121:
      return Data([0x1b, 0x5b, 0x36, 0x7e])
    case 117:
      return Data([0x1b, 0x5b, 0x33, 0x7e])
    default:
      return nil
    }
  }

  static func controlByte(forKeyCode keyCode: UInt16) -> UInt8? {
    controlKeyCodes[keyCode]
  }

  private static func controlByte(for event: NSEvent) -> UInt8? {
    if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
      let value = scalar.value
      switch value {
      case 0...0x1f:
        return UInt8(value)
      case 0x20, 0x2f:
        return 0x00
      case 0x40...0x5f, 0x60...0x7f:
        return UInt8(truncatingIfNeeded: value & 0x1f)
      default:
        break
      }
    }

    return controlByte(forKeyCode: event.keyCode)
  }
}

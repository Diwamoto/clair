import AppKit
import SwiftUI

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
  private var transcriptObserverID: UUID?

  init(session: TerminalSession) {
    self.session = session
    scrollView = NSScrollView(frame: .zero)
    textView = TerminalTextView(frame: .zero)
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

    transcriptObserverID = session.addTranscriptObserver { [weak self] transcript in
      self?.render(transcript)
    }
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
    session.resize(rows: rows, columns: columns)
  }

  func detach() {
    if let transcriptObserverID {
      session.removeTranscriptObserver(transcriptObserverID)
      self.transcriptObserverID = nil
    }
    textView.inputHandler = nil
  }

  private func render(_ transcript: String) {
    let documentMaxY = scrollView.documentView?.bounds.maxY ?? 0
    let visibleMaxY = scrollView.contentView.bounds.maxY
    let wasAtBottom =
      visibleMaxY >= documentMaxY - scrollView.contentView.bounds.height - 24
    let selection = textView.selectedRange()
    textView.string = transcript
    textView.sizeToFit()
    textView.frame.size.width = max(
      textView.frame.width,
      scrollView.contentView.bounds.width
    )
    textView.frame.size.height = max(
      textView.frame.height,
      scrollView.contentView.bounds.height
    )

    if selection.location != NSNotFound,
      selection.location <= transcript.utf16.count
    {
      textView.setSelectedRange(
        NSRange(
          location: selection.location,
          length: min(selection.length, transcript.utf16.count - selection.location)
        )
      )
    }
    if wasAtBottom {
      textView.scrollRangeToVisible(
        NSRange(location: transcript.utf16.count, length: 0)
      )
    }
  }
}

@MainActor
final class TerminalTextView: NSTextView {
  var inputHandler: ((Data) -> Void)?

  private var markedTextValue = ""

  let cellSize: CGSize = {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let width = ("W" as NSString).size(withAttributes: [.font: font]).width
    let height = ceil(font.ascender - font.descender + font.leading)
    return CGSize(width: max(1, width), height: max(1, height))
  }()

  override var acceptsFirstResponder: Bool {
    true
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
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
    textContainer?.widthTracksTextView = false
    textContainer?.heightTracksTextView = false
  }

  required init?(coder: NSCoder) {
    fatalError("TerminalTextView does not support NSCoder initialization.")
  }

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !markedTextValue.isEmpty else {
      return
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      .foregroundColor: NSColor.controlAccentColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    let x = textContainerInset.width
    let y = max(
      textContainerInset.height,
      bounds.height - textContainerInset.height - cellSize.height
    )
    (markedTextValue as NSString).draw(
      at: NSPoint(x: x, y: y),
      withAttributes: attributes
    )
  }
}

private enum TerminalKeySequence {
  static func data(for event: NSEvent) -> Data? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.control),
      let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
    {
      let value = scalar.value
      if value == 0x20 || value == 0x2f {
        return Data([0x00])
      }
      if (0x40...0x5f).contains(value) {
        return Data([UInt8(truncatingIfNeeded: value & 0x1f)])
      }
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
}

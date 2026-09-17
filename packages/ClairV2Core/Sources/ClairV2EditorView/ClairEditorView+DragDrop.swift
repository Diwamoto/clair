import ClairV2EditorCore

#if os(macOS)
  import AppKit

  /// Text drag/drop (E07): dragging the current selection out, and
  /// accepting a plain-text drop back in.
  ///
  /// **Scope (`INV-INPUT-006`)**: a drag only ever carries the exact bytes
  /// of the dragged selection, and a drop only ever inserts pasteboard
  /// `.string` content — never a file/URL payload. Opening a dropped file
  /// is a host/window-chrome concern, not this view's. An internal move
  /// (drag and drop within the same view) deletes the source and inserts
  /// at the destination as two simultaneous edits in one `onCommitEdits`
  /// call, so it is one undo unit, not two (`INV-INPUT-007`).
  extension ClairEditorView {
    /// Starts an `NSDraggingSession` for the current (non-empty) selection.
    /// Called from `mouseDragged` once a mouse-down inside the selection
    /// has moved past the click/drag threshold.
    func beginDraggingSelection(with event: NSEvent) {
      let texts = selection.selections.filter { !$0.isEmpty }.compactMap {
        try? snapshot.text(in: $0.range)
      }
      guard !texts.isEmpty else { return }
      let combined = texts.joined(separator: "\n")

      let pasteboardItem = NSPasteboardItem()
      pasteboardItem.setString(combined, forType: .string)

      let preview = combined.count > 40 ? String(combined.prefix(40)) + "…" : combined
      let attributed = NSAttributedString(
        string: preview, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
      let size = NSSize(
        width: max(attributed.size().width, 1), height: max(attributed.size().height, 1))
      let image = NSImage(size: size, flipped: false) { rect in
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6).setFill()
        rect.fill()
        attributed.draw(in: rect)
        return true
      }

      let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
      let location = convert(event.locationInWindow, from: nil)
      draggingItem.setDraggingFrame(
        NSRect(
          x: location.x, y: location.y - size.height / 2, width: size.width, height: size.height),
        contents: image)

      beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
  }

  @MainActor
  extension ClairEditorView: NSDraggingSource {
    public func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
      [.copy, .move]
    }

  }

  // `NSDraggingDestination` conformance is inherited from `NSView` itself
  // (declaring it again is a redundant-conformance error); these three are
  // ordinary overrides of `NSView`'s default (no-op) implementations.
  extension ClairEditorView {
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
      draggingUpdated(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
      guard sender.draggingPasteboard.string(forType: .string) != nil else { return [] }
      if (sender.draggingSource as? ClairEditorView) === self {
        return sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
      }
      return .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
      guard let text = sender.draggingPasteboard.string(forType: .string) else { return false }
      let point = convert(sender.draggingLocation, from: nil)
      guard let dropOffset = hitTestOffset(at: point) else { return false }

      let isInternalMove =
        (sender.draggingSource as? ClairEditorView) === self
        && sender.draggingSourceOperationMask.contains(.move)
      let sourceRanges =
        isInternalMove ? selection.selections.filter { !$0.isEmpty }.map(\.range) : []
      guard let edits = Self.dropEdits(inserting: text, at: dropOffset, movingFrom: sourceRanges)
      else { return false }
      onCommitEdits?(edits)
      return true
    }

    /// The pure edit-planning half of a drop: insert `text` at `offset`,
    /// and — for an internal move only — also delete every `sourceRanges`
    /// entry, all as one batch (`INV-INPUT-007`: one commit, one undo
    /// unit). `nil` when the drop point falls inside the text being moved
    /// (a no-op, not a self-deleting drop).
    static func dropEdits(
      inserting text: String, at offset: UTF8Offset, movingFrom sourceRanges: [TextUTF8Range]
    ) -> [TextEdit]? {
      guard
        !sourceRanges.contains(where: {
          offset.value >= $0.lowerBound.value && offset.value <= $0.upperBound.value
        })
      else { return nil }
      return [TextEdit(range: TextUTF8Range(offset, offset), replacement: text)]
        + sourceRanges.map { TextEdit(range: $0, replacement: "") }
    }
  }
#endif

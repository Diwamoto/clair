import ClairV2EditorCore

#if os(macOS)
  import AppKit
  import CoreText

  /// Intersects an absolute-document `range` with `line`'s content, and
  /// converts the overlap to a UTF-16 range local to that line's own text
  /// (the same string `EditorLineRenderer` hands to `NSAttributedString`,
  /// starting at 0 for the line's first character) — or `nil` when they do
  /// not overlap.
  func localUTF16Range(
    of range: TextUTF8Range, clippedTo line: TextLine, in snapshot: TextSnapshot
  ) throws -> Range<Int>? {
    let lower = max(range.lowerBound.value, line.contentRange.lowerBound.value)
    let upper = min(range.upperBound.value, line.contentRange.upperBound.value)
    guard lower < upper else { return nil }
    let lineStart = try snapshot.convert(line.contentRange.lowerBound, to: UTF16Unit.self).value
    let start = try snapshot.convert(UTF8Offset(lower), to: UTF16Unit.self).value
    let end = try snapshot.convert(UTF8Offset(upper), to: UTF16Unit.self).value
    return (start - lineStart)..<(end - lineStart)
  }

  /// Builds and caches one `CTLine` per document line, populated lazily —
  /// only for lines `ClairEditorView` actually asks to draw or hit-test,
  /// never the whole document. A cached line survives edits and scrolling
  /// elsewhere in the document; `invalidate(edits:in:)` evicts exactly the
  /// lines an edit's range touches, so relayout after typing stays confined
  /// to the changed lines (E06's "変更された行とその周辺だけを再レイアウトする").
  final class EditorLineRenderer {
    private var cache: [TextLineID: CTLine] = [:]
    let font: NSFont

    init(font: NSFont) {
      self.font = font
    }

    func invalidateAll() {
      cache.removeAll(keepingCapacity: true)
    }

    /// Evicts exactly the lines `edits` (given in `oldSnapshot`'s coordinate
    /// space) overlap. Lines created by the edit are simply absent from the
    /// cache already, so no explicit handling is needed for them.
    func invalidate(edits: [TextEdit], in oldSnapshot: TextSnapshot) {
      for edit in edits {
        guard
          let startLine = try? oldSnapshot.position(
            at: edit.range.lowerBound, columnUnit: UTF8Unit.self
          ).line,
          let endLine = try? oldSnapshot.position(
            at: edit.range.upperBound, columnUnit: UTF8Unit.self
          ).line
        else { continue }
        for index in startLine.value...endLine.value {
          guard let line = try? oldSnapshot.line(at: TextLineIndex(index)) else { continue }
          cache.removeValue(forKey: line.id)
        }
      }
    }

    func line(
      at index: TextLineIndex, in snapshot: TextSnapshot,
      highlights: [EditorHighlightSpan], colorOverrides: [EditorTokenKind: NSColor]
    ) throws -> (line: TextLine, ctLine: CTLine) {
      let textLine = try snapshot.line(at: index)
      if let cached = cache[textLine.id] {
        return (textLine, cached)
      }
      let built = try build(
        textLine, in: snapshot, highlights: highlights, colorOverrides: colorOverrides)
      cache[textLine.id] = built
      return (textLine, built)
    }

    private func build(
      _ textLine: TextLine, in snapshot: TextSnapshot,
      highlights: [EditorHighlightSpan], colorOverrides: [EditorTokenKind: NSColor]
    ) throws -> CTLine {
      let text = try snapshot.text(in: textLine.contentRange)
      let attributed = NSMutableAttributedString(
        string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
      for span in highlights {
        guard let local = try localUTF16Range(of: span.range, clippedTo: textLine, in: snapshot)
        else { continue }
        let color = colorOverrides[span.kind] ?? span.kind.defaultColor
        attributed.addAttribute(.foregroundColor, value: color, range: NSRange(local))
      }
      return CTLineCreateWithAttributedString(attributed)
    }
  }
#endif

import CoreGraphics
import CoreText
import Foundation

/// Draws rows of a `TextSurfaceSource` into a flipped graphics context, limited
/// to the damage it is given.
///
/// The renderer has no "redraw everything" entry point. `plan(damage:in:...)`
/// intersects the damaged rows with the exposed rectangle, so the work per frame
/// is bounded by the viewport even when a source invalidates a large range.
@MainActor
final class TextSurfaceRenderer {
  /// A run of one row that shares a style and takes a single drawing path.
  struct Segment: Equatable {
    let column: Int
    let columnWidth: Int
    let text: String
    let style: TextCellStyle
    let path: TextRunPath
  }

  struct RowPlan: Equatable {
    let row: Int
    let rect: CGRect
    let path: TextRunPath
  }

  struct Plan: Equatable {
    let rows: [RowPlan]

    static let empty = Plan(rows: [])

    var isEmpty: Bool {
      rows.isEmpty
    }

    var rowIndexes: [Int] {
      rows.map(\.row)
    }

    var rects: [CGRect] {
      rows.map(\.rect)
    }
  }

  let metrics: TextFontMetrics
  var theme: TextSurfaceTheme
  var contentInset: CGSize

  init(
    metrics: TextFontMetrics,
    theme: TextSurfaceTheme = .oneDark,
    contentInset: CGSize = CGSize(width: 6, height: 4)
  ) {
    self.metrics = metrics
    self.theme = theme
    self.contentInset = contentInset
  }

  // MARK: - Geometry

  func rowRect(_ row: Int, width: CGFloat) -> CGRect {
    CGRect(
      x: 0,
      y: contentInset.height + metrics.rowTop(row),
      width: width,
      height: metrics.cellSize.height
    )
  }

  func contentSize(rowCount: Int, columnCount: Int) -> CGSize {
    CGSize(
      width: contentInset.width * 2 + CGFloat(columnCount) * metrics.cellSize.width,
      height: contentInset.height * 2 + CGFloat(rowCount) * metrics.cellSize.height
    )
  }

  /// Rows a rectangle exposes, clamped to the source.
  func rowRange(intersecting rect: CGRect, rowCount: Int) -> Range<Int> {
    let cellHeight = metrics.cellSize.height
    guard rowCount > 0, cellHeight > 0, rect.height > 0 else {
      return 0..<0
    }
    let top = rect.minY - contentInset.height
    let bottom = rect.maxY - contentInset.height
    let first = min(max(Int((top / cellHeight).rounded(.down)), 0), rowCount)
    let last = min(max(Int((bottom / cellHeight).rounded(.up)), 0), rowCount)
    return first < last ? first..<last : 0..<0
  }

  /// Dirty rectangles for damaged rows, used to invalidate only those bands.
  func rects(for damage: TextSurfaceDamage, width: CGFloat) -> [CGRect] {
    damage.rowRanges.map { range in
      CGRect(
        x: 0,
        y: contentInset.height + metrics.rowTop(range.lowerBound),
        width: width,
        height: CGFloat(range.count) * metrics.cellSize.height
      )
    }
  }

  // MARK: - Planning

  func plan(
    damage: TextSurfaceDamage,
    in dirtyRect: CGRect,
    viewportWidth: CGFloat,
    source: any TextSurfaceSource
  ) -> Plan {
    let exposed = rowRange(intersecting: dirtyRect, rowCount: source.rowCount)
    let limited = damage.intersection(with: exposed)
    guard !limited.isEmpty else {
      return .empty
    }
    let rows = limited.rows.compactMap { index -> RowPlan? in
      guard let row = source.row(at: index) else {
        return nil
      }
      return RowPlan(
        row: index,
        rect: rowRect(index, width: viewportWidth),
        path: TextRunClassifier.path(
          for: row.text,
          ligaturesEnabled: metrics.configuration.ligaturesEnabled
        )
      )
    }
    return Plan(rows: rows)
  }

  /// Splits a row into drawable runs.
  ///
  /// Adjacent single-width clusters that share a style are shaped together, so a
  /// programming ligature still forms; a full-width or zero-width cluster gets
  /// its own run so it stays on the cell grid.
  func segments(for row: TextSurfaceRow) -> [Segment] {
    var segments: [Segment] = []
    var column = 0
    var buffer = ""
    var bufferColumn = 0
    var bufferStyle: TextCellStyle?

    func flush() {
      defer {
        buffer = ""
        bufferStyle = nil
      }
      guard let style = bufferStyle, !buffer.isEmpty else {
        return
      }
      segments.append(
        Segment(
          column: bufferColumn,
          columnWidth: column - bufferColumn,
          text: buffer,
          style: style,
          path: TextRunClassifier.path(
            for: buffer,
            ligaturesEnabled: metrics.configuration.ligaturesEnabled
          )
        )
      )
    }

    for span in row.spans {
      for character in span.text {
        let width = TextDisplayWidth.columns(for: character)
        if width != 1 || bufferStyle != span.style {
          flush()
        }
        if width == 1 {
          if buffer.isEmpty {
            bufferColumn = column
            bufferStyle = span.style
          }
          buffer.append(character)
          column += 1
        } else {
          segments.append(
            Segment(
              column: column,
              columnWidth: width,
              text: String(character),
              style: span.style,
              path: .coreText
            )
          )
          column += width
        }
      }
      flush()
    }
    flush()
    return segments
  }

  // MARK: - Drawing

  func draw(_ plan: Plan, source: any TextSurfaceSource, in context: CGContext) {
    guard !plan.isEmpty else {
      return
    }
    context.saveGState()
    context.setShouldAntialias(true)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    for rowPlan in plan.rows {
      context.setFillColor(theme.background.cgColor)
      context.fill(rowPlan.rect)
      guard let row = source.row(at: rowPlan.row) else {
        continue
      }
      draw(row: row, rowRect: rowPlan.rect, context: context)
    }
    context.restoreGState()
  }

  private func draw(row: TextSurfaceRow, rowRect: CGRect, context: CGContext) {
    let baseline = rowRect.minY + metrics.baselineOffset
    for segment in segments(for: row) {
      let colors = resolvedColors(for: segment.style)
      let originX = contentInset.width + metrics.columnX(segment.column)
      let segmentRect = CGRect(
        x: originX,
        y: rowRect.minY,
        width: CGFloat(max(segment.columnWidth, 0)) * metrics.cellSize.width,
        height: rowRect.height
      )
      if let background = colors.background {
        context.setFillColor(background.cgColor)
        context.fill(segmentRect)
      }
      switch segment.path {
      case .fastASCII:
        drawFastPath(segment, foreground: colors.foreground, baseline: baseline, context: context)
      case .coreText:
        drawShapedPath(segment, foreground: colors.foreground, baseline: baseline, context: context)
      }
      drawDecorations(segment, rect: segmentRect, color: colors.foreground, context: context)
    }
  }

  private func resolvedColors(
    for style: TextCellStyle
  ) -> (foreground: TextSurfaceColor, background: TextSurfaceColor?) {
    let foreground = style.foreground
    let background = style.background
    guard style.isInverse else {
      return (foreground, background)
    }
    return (background ?? theme.background, foreground)
  }

  /// Single-width ASCII: precomputed glyphs placed by arithmetic.
  private func drawFastPath(
    _ segment: Segment,
    foreground: TextSurfaceColor,
    baseline: CGFloat,
    context: CGContext
  ) {
    var glyphs: [CGGlyph] = []
    var positions: [CGPoint] = []
    var column = segment.column
    for scalar in segment.text.unicodeScalars {
      guard let glyph = metrics.asciiGlyph(for: scalar, bold: segment.style.isBold) else {
        // A font without this glyph is not a reason to draw nothing.
        drawShapedPath(segment, foreground: foreground, baseline: baseline, context: context)
        return
      }
      glyphs.append(glyph)
      positions.append(
        CGPoint(x: contentInset.width + metrics.columnX(column), y: baseline)
      )
      column += 1
    }
    guard !glyphs.isEmpty else {
      return
    }
    context.setFillColor(foreground.cgColor)
    CTFontDrawGlyphs(
      metrics.font(bold: segment.style.isBold),
      glyphs,
      positions,
      glyphs.count,
      context
    )
  }

  /// Everything CoreText has to shape, including fallback fonts for CJK, emoji,
  /// and combining marks.
  private func drawShapedPath(
    _ segment: Segment,
    foreground: TextSurfaceColor,
    baseline: CGFloat,
    context: CGContext
  ) {
    guard !segment.text.isEmpty else {
      return
    }
    let key = TextRunCache.Key(text: segment.text, style: segment.style)
    let line = metrics.runCache.line(for: key) {
      makeLine(for: segment, foreground: foreground)
    }
    context.textPosition = CGPoint(
      x: contentInset.width + metrics.columnX(segment.column),
      y: baseline
    )
    CTLineDraw(line, context)
  }

  private func makeLine(for segment: Segment, foreground: TextSurfaceColor) -> CTLine {
    let font = metrics.font(for: segment.text, bold: segment.style.isBold)
    var attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground.cgColor,
      NSAttributedString.Key(kCTLigatureAttributeName as String):
        metrics.configuration.ligaturesEnabled ? 1 : 0,
    ]
    if segment.style.isUnderlined {
      attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] =
        CTUnderlineStyle.single.rawValue
    }
    let attributed = NSAttributedString(string: segment.text, attributes: attributes)
    return CTLineCreateWithAttributedString(attributed as CFAttributedString)
  }

  private func drawDecorations(
    _ segment: Segment,
    rect: CGRect,
    color: TextSurfaceColor,
    context: CGContext
  ) {
    guard segment.style.isStruckThrough else {
      return
    }
    let thickness = max(1, (metrics.cellSize.height / 14).rounded())
    context.setFillColor(color.cgColor)
    context.fill(
      CGRect(
        x: rect.minX,
        y: rect.midY - thickness / 2,
        width: rect.width,
        height: thickness
      )
    )
  }
}

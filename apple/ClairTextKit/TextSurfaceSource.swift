import CoreGraphics
import Foundation

// ClairTextKit is the text surface shared by the editor and the terminal. It
// owns font metrics, damage-limited drawing, and the row contract below. The
// dependency direction is one-way: ClairTextKit must not reference Clair's
// Project, workspace, or theme types, so every palette and every row of text is
// injected by the caller.

/// sRGB color used by the shared surface. The engine keeps its own color type so
/// the module stays independent from the app's theme definitions.
struct TextSurfaceColor: Equatable, Hashable, Sendable {
  let red: Double
  let green: Double
  let blue: Double
  let alpha: Double

  init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// 8-bit component convenience that matches how the workspace palette is
  /// written elsewhere in the app.
  static func rgb(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Double = 1) -> TextSurfaceColor {
    TextSurfaceColor(
      red: Double(red) / 255,
      green: Double(green) / 255,
      blue: Double(blue) / 255,
      alpha: alpha
    )
  }

  var cgColor: CGColor {
    CGColor(
      srgbRed: CGFloat(red),
      green: CGFloat(green),
      blue: CGFloat(blue),
      alpha: CGFloat(alpha)
    )
  }
}

/// Colors the renderer needs. Callers map their own theme onto this palette.
struct TextSurfaceTheme: Equatable, Hashable, Sendable {
  let background: TextSurfaceColor
  let foreground: TextSurfaceColor
  let selectionBackground: TextSurfaceColor
  let selectionForeground: TextSurfaceColor
  let caret: TextSurfaceColor

  init(
    background: TextSurfaceColor,
    foreground: TextSurfaceColor,
    selectionBackground: TextSurfaceColor,
    selectionForeground: TextSurfaceColor,
    caret: TextSurfaceColor
  ) {
    self.background = background
    self.foreground = foreground
    self.selectionBackground = selectionBackground
    self.selectionForeground = selectionForeground
    self.caret = caret
  }

  /// One Dark, the appearance the workspace already uses. The app passes its own
  /// palette in production; this keeps the Dev harness self-contained.
  static let oneDark = TextSurfaceTheme(
    background: .rgb(40, 44, 52),
    foreground: .rgb(171, 178, 191),
    selectionBackground: .rgb(91, 136, 247, 0.34),
    selectionForeground: .rgb(241, 243, 239),
    caret: .rgb(91, 136, 247)
  )
}

/// Visual attributes of one run of cells.
struct TextCellStyle: Equatable, Hashable, Sendable {
  var foreground: TextSurfaceColor
  var background: TextSurfaceColor?
  var isBold: Bool
  var isItalic: Bool
  var isUnderlined: Bool
  var isStruckThrough: Bool
  var isInverse: Bool

  init(
    foreground: TextSurfaceColor,
    background: TextSurfaceColor? = nil,
    isBold: Bool = false,
    isItalic: Bool = false,
    isUnderlined: Bool = false,
    isStruckThrough: Bool = false,
    isInverse: Bool = false
  ) {
    self.foreground = foreground
    self.background = background
    self.isBold = isBold
    self.isItalic = isItalic
    self.isUnderlined = isUnderlined
    self.isStruckThrough = isStruckThrough
    self.isInverse = isInverse
  }

  static func plain(_ foreground: TextSurfaceColor) -> TextCellStyle {
    TextCellStyle(foreground: foreground)
  }
}

/// A contiguous piece of one row that shares a single style.
struct TextSurfaceSpan: Equatable, Hashable, Sendable {
  let text: String
  let style: TextCellStyle

  init(text: String, style: TextCellStyle) {
    self.text = text
    self.style = style
  }
}

/// One visible row supplied by a source. The engine never asks a source for the
/// whole document; `TextSurfaceRenderer` requests only the rows it is about to
/// draw.
struct TextSurfaceRow: Equatable, Hashable, Sendable {
  let index: Int
  let spans: [TextSurfaceSpan]

  init(index: Int, spans: [TextSurfaceSpan]) {
    self.index = index
    self.spans = spans
  }

  init(index: Int, text: String, style: TextCellStyle) {
    self.init(index: index, spans: [TextSurfaceSpan(text: text, style: style)])
  }

  var text: String {
    spans.reduce(into: "") { partial, span in
      partial += span.text
    }
  }

  /// Terminal cell columns the row occupies. Full-width clusters count as two.
  var columnWidth: Int {
    TextDisplayWidth.columns(in: text)
  }
}

/// Rows a source has invalidated.
///
/// There is deliberately no "everything" case. Damage is always a bounded set of
/// row ranges, which is what keeps the renderer from ever repainting a whole
/// document or a whole terminal grid.
struct TextSurfaceDamage: Equatable, Hashable, Sendable {
  private(set) var rowRanges: [Range<Int>]

  static let empty = TextSurfaceDamage()

  init() {
    rowRanges = []
  }

  init(rows: Range<Int>) {
    rowRanges = rows.isEmpty ? [] : [rows]
  }

  init(row: Int) {
    self.init(rows: row..<(row + 1))
  }

  init(rowRanges: [Range<Int>]) {
    self.rowRanges = TextSurfaceDamage.normalized(rowRanges)
  }

  var isEmpty: Bool {
    rowRanges.isEmpty
  }

  var rowCount: Int {
    rowRanges.reduce(0) { partial, range in
      partial + range.count
    }
  }

  var rows: [Int] {
    rowRanges.flatMap { Array($0) }
  }

  func contains(row: Int) -> Bool {
    rowRanges.contains { $0.contains(row) }
  }

  func union(_ other: TextSurfaceDamage) -> TextSurfaceDamage {
    TextSurfaceDamage(rowRanges: rowRanges + other.rowRanges)
  }

  mutating func formUnion(_ other: TextSurfaceDamage) {
    self = union(other)
  }

  /// Clamps the damage to a row window, which is how the renderer restricts work
  /// to the exposed viewport.
  func intersection(with rows: Range<Int>) -> TextSurfaceDamage {
    guard !rows.isEmpty else {
      return .empty
    }
    let clamped = rowRanges.compactMap { range -> Range<Int>? in
      let lower = max(range.lowerBound, rows.lowerBound)
      let upper = min(range.upperBound, rows.upperBound)
      return lower < upper ? lower..<upper : nil
    }
    return TextSurfaceDamage(rowRanges: clamped)
  }

  private static func normalized(_ ranges: [Range<Int>]) -> [Range<Int>] {
    let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
    var merged: [Range<Int>] = []
    for range in sorted {
      guard let last = merged.last else {
        merged.append(range)
        continue
      }
      if range.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        merged.append(range)
      }
    }
    return merged
  }
}

/// Receives invalidation from a source. The surface view adopts this and turns
/// each damaged row range into a dirty rectangle.
@MainActor
protocol TextSurfaceSourceObserver: AnyObject {
  func textSurfaceSource(
    _ source: any TextSurfaceSource,
    didInvalidate damage: TextSurfaceDamage
  )
}

/// The single seam between the shared surface and a model.
///
/// The editor (`TextBuffer`) and the terminal (`TerminalGridSource`) both adopt
/// this protocol; nothing above it knows which one is in use.
@MainActor
protocol TextSurfaceSource: AnyObject {
  /// Number of rows the source can supply.
  var rowCount: Int { get }
  /// Widest row in terminal cells, used for the content width only.
  var columnCount: Int { get }
  /// Set by the view that draws this source.
  var observer: (any TextSurfaceSourceObserver)? { get set }
  /// Returns the row, or `nil` when the index is outside the source.
  func row(at index: Int) -> TextSurfaceRow?
}

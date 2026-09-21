import CoreGraphics

/// Pure line-index/geometry math for `ClairEditorView`'s viewport-only
/// layout. No AppKit/CoreText dependency, so it is testable without a
/// window: `visibleLineRange` is the one call the view's `draw(_:)` uses to
/// decide which lines to lay out, and it is always O(visible lines), never
/// O(document) — the property E06's acceptance criteria requires.
public enum EditorViewGeometry {
  /// The top edge (distance from the document's top) of line `index`, in a
  /// top-down (flipped) coordinate space where line 0 starts at 0.
  public static func lineOrigin(_ index: Int, lineHeight: CGFloat) -> CGFloat {
    CGFloat(index) * lineHeight
  }

  /// The line index whose row contains `y` (top-down space), clamped to a
  /// document with `lineCount` lines.
  public static func lineIndex(atY y: CGFloat, lineHeight: CGFloat, lineCount: Int) -> Int {
    guard lineHeight > 0, lineCount > 0 else { return 0 }
    let index = Int((y / lineHeight).rounded(.down))
    return min(max(index, 0), lineCount - 1)
  }

  /// The half-open range of line indices intersecting `visibleRect`
  /// (top-down space), clamped to `0..<lineCount`.
  public static func visibleLineRange(
    visibleRect: CGRect, lineHeight: CGFloat, lineCount: Int
  ) -> Range<Int> {
    guard lineHeight > 0, lineCount > 0, visibleRect.height > 0 else { return 0..<0 }
    let first = lineIndex(atY: visibleRect.minY, lineHeight: lineHeight, lineCount: lineCount)
    let last = lineIndex(
      atY: max(visibleRect.maxY - 0.001, visibleRect.minY), lineHeight: lineHeight,
      lineCount: lineCount)
    return first..<(last + 1)
  }
}

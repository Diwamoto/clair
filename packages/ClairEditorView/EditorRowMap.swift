import Foundation

/// E13: document line ↔ visual row, under code folding (hidden lines take no
/// row) and soft wrap (a long line takes several). Pure and platform-free so
/// the arithmetic is testable without a window. With no folds and no wraps it
/// is the identity, which is what the view had before E13.
///
/// Lookups are O(log n) in the number of folds + wrapped lines, never in the
/// document's line count (`INV-PERF-001`).
public struct EditorRowMap: Sendable, Equatable {
  public private(set) var lineCount: Int
  /// Hidden (folded) line ranges: sorted, non-overlapping.
  public private(set) var hidden: [ClosedRange<Int>] = []
  /// Soft-wrapped lines and their extra rows (rows - 1), sorted by line.
  public private(set) var wraps: [(line: Int, extra: Int)] = []

  // Derived: wraps on visible lines only, with a running total.
  private var visibleWrapLines: [Int] = []
  private var wrapPrefix: [Int] = [0]
  private var hiddenPrefix: [Int] = [0]

  public init(lineCount: Int) { self.lineCount = max(lineCount, 1) }

  public static func == (a: Self, b: Self) -> Bool {
    a.lineCount == b.lineCount && a.hidden == b.hidden
      && a.wraps.elementsEqual(b.wraps) { $0.line == $1.line && $0.extra == $1.extra }
  }

  public var isIdentity: Bool { hidden.isEmpty && wraps.isEmpty }

  public mutating func setHidden(_ ranges: [ClosedRange<Int>]) {
    // Merge overlaps (a fold inside another fold is just covered by the outer one).
    var merged: [ClosedRange<Int>] = []
    for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound })
    where r.lowerBound >= 0 && r.upperBound < lineCount {
      if let last = merged.last, r.lowerBound <= last.upperBound + 1 {
        merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
      } else {
        merged.append(r)
      }
    }
    hidden = merged
    rebuild()
  }

  public mutating func setWraps(_ list: [(line: Int, extra: Int)], lineCount: Int) {
    self.lineCount = max(lineCount, 1)
    wraps = list.filter { $0.extra > 0 && $0.line < self.lineCount }.sorted { $0.line < $1.line }
    rebuild()
  }

  /// After an edit replaced old lines `first...oldLast` with new lines
  /// `first...newLast`: shifts every wrap below it and swaps in `recomputed`
  /// for the edited lines (only those lines are re-measured).
  public mutating func replaceWraps(
    first: Int, oldLast: Int, newLast: Int, recomputed: [(line: Int, extra: Int)], lineCount: Int
  ) {
    let delta = newLast - oldLast
    var next = wraps.filter { $0.line < first }
    next += recomputed.filter { $0.extra > 0 }
    next += wraps.filter { $0.line > oldLast }.map { (line: $0.line + delta, extra: $0.extra) }
    setWraps(next, lineCount: lineCount)
  }

  private mutating func rebuild() {
    hiddenPrefix = [0]
    for r in hidden { hiddenPrefix.append(hiddenPrefix.last! + r.count) }
    visibleWrapLines = []
    wrapPrefix = [0]
    for w in wraps where !isHidden(w.line) {
      visibleWrapLines.append(w.line)
      wrapPrefix.append(wrapPrefix.last! + w.extra)
    }
  }

  /// The hidden range containing `line`, if any.
  public func hiddenRange(containing line: Int) -> ClosedRange<Int>? {
    var lo = 0
    var hi = hidden.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if hidden[mid].upperBound < line { lo = mid + 1 } else { hi = mid }
    }
    return lo < hidden.count && hidden[lo].contains(line) ? hidden[lo] : nil
  }

  public func isHidden(_ line: Int) -> Bool { hiddenRange(containing: line) != nil }

  /// Number of elements of sorted `values` below `x`.
  private static func countBelow(_ values: [Int], _ x: Int) -> Int {
    var lo = 0
    var hi = values.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if values[mid] < x { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }

  private func hiddenBefore(_ line: Int) -> Int {
    var lo = 0
    var hi = hidden.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if hidden[mid].upperBound < line { lo = mid + 1 } else { hi = mid }
    }
    // Ranges fully above `line`, plus the part of one that contains it.
    var n = hiddenPrefix[lo]
    if lo < hidden.count, hidden[lo].lowerBound < line { n += line - hidden[lo].lowerBound }
    return n
  }

  /// Rows `line` occupies: 0 when folded away.
  public func rows(of line: Int) -> Int {
    if isHidden(line) { return 0 }
    let i = Self.countBelow(visibleWrapLines, line)
    return i < visibleWrapLines.count && visibleWrapLines[i] == line ? 1 + wrapPrefix[i + 1] - wrapPrefix[i] : 1
  }

  /// First visual row of `line`. A hidden line maps to the row after its fold's header.
  public func row(of line: Int) -> Int {
    let l = min(max(line, 0), lineCount - 1)
    return l - hiddenBefore(l) + wrapPrefix[Self.countBelow(visibleWrapLines, l)]
  }

  public var rowCount: Int { row(of: lineCount - 1) + rows(of: lineCount - 1) }

  /// The visible line on `row` (clamped) and which of its wrapped rows it is.
  public func line(atRow row: Int) -> (line: Int, subrow: Int) {
    let r = min(max(row, 0), max(rowCount - 1, 0))
    // Largest visible line whose first row is <= r.
    var lo = 0
    var hi = lineCount - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if self.row(of: mid) <= r { lo = mid } else { hi = mid - 1 }
    }
    var line = lo
    while line > 0, isHidden(line) { line -= 1 }
    return (line, r - self.row(of: line))
  }

  /// Visible lines intersecting rows `rows`, each with its first row.
  public func lines(inRows rows: Range<Int>) -> [(line: Int, row: Int)] {
    guard !rows.isEmpty else { return [] }
    var out: [(Int, Int)] = []
    var (line, _) = line(atRow: rows.lowerBound)
    while line < lineCount {
      if let h = hiddenRange(containing: line) { line = h.upperBound + 1; continue }
      let r = row(of: line)
      if r >= rows.upperBound { break }
      out.append((line, r))
      line += 1
    }
    return out
  }
}

/// E13 soft wrap on a monospace grid: where each wrapped row starts, in the
/// line's UTF-16 offsets. A grapheme is 2 columns when it is East Asian wide
/// (CJK, Hangul, fullwidth forms, most emoji), a tab 4, anything else 1.
/// Character wrapping, like ccedit's native editor (`.byCharWrapping`).
public enum EditorWrap {
  /// UTF-16 offsets where rows 2, 3, … begin; empty when the line fits.
  public static func breaks(_ text: Substring, columns: Int) -> [Int] {
    guard columns > 0, text.utf8.count > columns else { return [] }
    var out: [Int] = []
    var used = 0
    var utf16 = 0
    for g in text {
      let w = width(g)
      if used + w > columns, used > 0 {
        out.append(utf16)
        used = 0
      }
      used += w
      utf16 += g.utf16.count
    }
    return out
  }

  public static func width(_ g: Character) -> Int {
    if g == "\t" { return 4 }
    guard let s = g.unicodeScalars.first?.value else { return 1 }
    switch s {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
      0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
      0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
      return 2
    default:
      return 1
    }
  }
}

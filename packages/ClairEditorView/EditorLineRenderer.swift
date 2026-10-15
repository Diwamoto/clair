import ClairEditorCore
import CoreText
import Foundation

// `NSUnderlineStyle` lives in the AppKit/UIKit Swift overlay, not plain
// Foundation, despite the `NS` prefix — this is the only reason either
// import is needed here; everything else in this file only touches
// `PlatformFont`/`PlatformColor` (`PlatformTypes.swift`).
#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

// Cross-platform (E06 macOS + E08 iOS): CoreText/`NSAttributedString` line
// layout has no AppKit/UIKit-specific behavior beyond the `PlatformFont`/
// `PlatformColor` aliases (`PlatformTypes.swift`), so both `ClairEditorView`
// implementations share this cache instead of a forked copy per platform —
// iOS gets the same "only lay out lines actually drawn/hit-tested, evict
// only what an edit touched" guarantee E06 built for free.

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
  let font: PlatformFont
  /// Colour of text no highlight span covers.
  var baseColor: PlatformColor = .editorLabel
  /// Also underline U+3000 (`suspiciousCharacterRanges`).
  var flagsIdeographicSpace = false

  init(font: PlatformFont) {
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
    highlights: EditorSpanIndex<EditorHighlightSpan>, colorOverrides: [EditorTokenKind: PlatformColor]
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
    highlights: EditorSpanIndex<EditorHighlightSpan>, colorOverrides: [EditorTokenKind: PlatformColor]
  ) throws -> CTLine {
    let text = try snapshot.text(in: textLine.contentRange)
    let attributed = NSMutableAttributedString(
      string: text, attributes: [.font: font, .foregroundColor: baseColor])
    for span in highlights.overlapping(textLine.contentRange) {
      guard let local = try localUTF16Range(of: span.range, clippedTo: textLine, in: snapshot)
      else { continue }
      let color = colorOverrides[span.kind] ?? span.kind.defaultColor
      attributed.addAttribute(.foregroundColor, value: color, range: NSRange(local))
    }
    for range in suspiciousCharacterRanges(in: text, ideographicSpace: flagsIdeographicSpace) {
      attributed.addAttributes(
        [.underlineStyle: NSUnderlineStyle.thick.rawValue, NSAttributedString.Key(kCTUnderlineColorAttributeName as String): PlatformColor.systemRed.cgColor],
        range: NSRange(range, in: text))
    }
    return CTLineCreateWithAttributedString(attributed)
  }

  /// Renders `index` with `composition`'s text spliced in over the buffer
  /// range it stands in for, instead of that line's committed text
  /// (`EditorComposition`, `INV-UNDO-003`). Never cached — a composing
  /// line's content changes on every keystroke, and it is exactly one
  /// line, so rebuilding it each draw stays proportional to one line, not
  /// the document (`INV-PERF-001`). Syntax highlighting is skipped here:
  /// it is a short-lived visual state, and remapping highlight spans
  /// across a shifting splice is not worth the complexity.
  func composedLine(
    at index: TextLineIndex, in snapshot: TextSnapshot, composition: EditorComposition
  ) throws -> (line: TextLine, ctLine: CTLine) {
    let textLine = try snapshot.line(at: index)
    let text = try snapshot.text(in: textLine.contentRange)
    let attributed = NSMutableAttributedString(
      string: text, attributes: [.font: font, .foregroundColor: baseColor])
    let bounds = 0...(text as NSString).length
    let lineStart = try snapshot.convert(textLine.contentRange.lowerBound, to: UTF16Unit.self)
      .value
    let rawStart =
      try snapshot.convert(composition.replacedRange.lowerBound, to: UTF16Unit.self)
      .value - lineStart
    let rawEnd =
      try snapshot.convert(composition.replacedRange.upperBound, to: UTF16Unit.self)
      .value - lineStart
    let start = min(max(rawStart, bounds.lowerBound), bounds.upperBound)
    let end = min(max(rawEnd, start), bounds.upperBound)
    let spliceRange = NSRange(location: start, length: end - start)
    // Explicit attributes: a plain-String splice inherits from a neighbour,
    // and an empty line (or column 0) has none, so the text drew black.
    attributed.replaceCharacters(
      in: spliceRange,
      with: NSAttributedString(
        string: composition.text,
        attributes: [
          .font: font, .foregroundColor: baseColor,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
    return (textLine, CTLineCreateWithAttributedString(attributed))
  }
}

/// Characters a font draws like ASCII, or does not draw at all, but that are
/// something else — homoglyph phishing (`аma` with Cyrillic а), Trojan Source
/// bidi controls, prompts hidden in tag characters or variation selectors.
/// No font can tell them apart (the glyphs are identical on purpose), so the
/// editor underlines them instead:
/// - always: control characters (C0 but tab, DEL, C1), zero-width and bidi
///   controls, odd spaces (NBSP, en/em spaces, U+2028/9), tag characters, and
///   lookalike punctuation (Greek `;`, `−`, `∕`, `⁄`);
/// - variation selectors and combining marks right after an ASCII letter or
///   in a run (data smuggling, zalgo), but not after the emoji/kana they serve;
/// - Cyrillic, Greek, Armenian, Cherokee, small-cap, letterlike, math, Roman
///   numeral and fullwidth letters/digits inside a word that also has ASCII
///   letters or digits;
/// - the ideographic space U+3000 when `ideographicSpace` (Japanese prose uses
///   it, so it follows the editor's 空白文字を表示 setting).
// ponytail: an all-Cyrillic lookalike word (`аре`) is not flagged, so Russian
// or Greek prose stays clean; add Unicode's confusables table if that bites.
public func suspiciousCharacterRanges(in text: String, ideographicSpace: Bool = false) -> [Range<String.Index>] {
  func always(_ v: UInt32) -> Bool {
    switch v {
    case 0x00...0x08, 0x0B...0x1F, 0x7F...0x9F, 0xA0, 0xAD, 0x37E, 0x1680, 0x180E, 0x2000...0x200F,
      0x2028...0x202F, 0x2044, 0x205F...0x2064, 0x2066...0x206F, 0x2212, 0x2215, 0xFEFF, 0xFFF9...0xFFFB,
      0xE0000...0xE007F:
      return true
    case 0x3000: return ideographicSpace
    default: return false
    }
  }
  func lookalike(_ v: UInt32) -> Bool {
    switch v {
    case 0x370...0x58F, 0x13A0...0x13FF, 0x1D00...0x1D2B, 0x2100...0x214F, 0x2160...0x2188,
      0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A, 0x1D400...0x1D7FF:
      return true
    default: return false
    }
  }
  func selector(_ v: UInt32) -> Bool { (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v) }
  func asciiWord(_ s: Unicode.Scalar) -> Bool { s.isASCII && (s.properties.isAlphabetic || ("0"..."9").contains(s)) }

  var result: [Range<String.Index>] = []
  var word: [Range<String.Index>] = []
  var hasASCII = false
  func flush() {
    if hasASCII { result += word }
    word = []
    hasASCII = false
  }
  var previous: Unicode.Scalar?
  var previousFlaggedMark = false
  var i = text.startIndex
  while i < text.endIndex {
    let next = text.unicodeScalars.index(after: i)
    let s = text.unicodeScalars[i]
    let v = s.value
    let mark = selector(v) || s.properties.generalCategory == .nonspacingMark
    defer { previous = s; i = next }
    if always(v) {
      result.append(i..<next)
      flush()
    } else if mark {
      // A mark on an ASCII letter, or a second mark in a row, is not how real text is written.
      let flagged = previous.map { asciiWord($0) || (selector($0.value) && selector(v)) || previousFlaggedMark } ?? true
      if flagged { result.append(i..<next) }
      previousFlaggedMark = flagged
      continue
    } else if asciiWord(s) {
      hasASCII = true
    } else if !s.isASCII, s.properties.isAlphabetic || (0xFF10...0xFF19).contains(v) {
      if lookalike(v) { word.append(i..<next) }
    } else {
      flush()
    }
    previousFlaggedMark = false
  }
  flush()
  return result
}

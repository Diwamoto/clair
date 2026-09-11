import CoreGraphics
import CoreText
import Foundation

/// Cached CoreText lines, keyed by the exact text and style that produced them.
///
/// Shaping is the expensive half of the CoreText path, so a row that is redrawn
/// without changing is shaped once. The cache is bounded; it never grows with
/// document size.
@MainActor
final class TextRunCache {
  struct Key: Hashable {
    let text: String
    let style: TextCellStyle

    init(text: String, style: TextCellStyle) {
      self.text = text
      self.style = style
    }
  }

  let capacity: Int
  private var entries: [Key: CTLine] = [:]
  private var order: [Key] = []
  private(set) var hitCount = 0
  private(set) var missCount = 0

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  var count: Int {
    entries.count
  }

  func line(for key: Key, make: () -> CTLine) -> CTLine {
    if let cached = entries[key] {
      hitCount += 1
      touch(key)
      return cached
    }
    missCount += 1
    let line = make()
    entries[key] = line
    order.append(key)
    evictIfNeeded()
    return line
  }

  func removeAll() {
    entries.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
  }

  private func touch(_ key: Key) {
    if let index = order.firstIndex(of: key) {
      order.remove(at: index)
    }
    order.append(key)
  }

  private func evictIfNeeded() {
    while order.count > capacity {
      let oldest = order.removeFirst()
      entries.removeValue(forKey: oldest)
    }
  }
}

/// Font and cache settings for a surface.
struct TextSurfaceFontConfiguration: Equatable, Hashable, Sendable {
  var fontName: String
  var fontSize: CGFloat
  var lineHeightMultiple: CGFloat
  var ligaturesEnabled: Bool
  var runCacheCapacity: Int
  var fallbackCacheCapacity: Int

  init(
    fontName: String = "SFMono-Regular",
    fontSize: CGFloat = 13,
    lineHeightMultiple: CGFloat = 1.2,
    ligaturesEnabled: Bool = false,
    runCacheCapacity: Int = 512,
    fallbackCacheCapacity: Int = 128
  ) {
    self.fontName = fontName
    self.fontSize = fontSize
    self.lineHeightMultiple = lineHeightMultiple
    self.ligaturesEnabled = ligaturesEnabled
    self.runCacheCapacity = runCacheCapacity
    self.fallbackCacheCapacity = fallbackCacheCapacity
  }

  /// The editor shapes programming ligatures; the terminal never does, because
  /// a ligature must not change how many cells a sequence occupies.
  static let editor = TextSurfaceFontConfiguration(ligaturesEnabled: true)
  static let terminal = TextSurfaceFontConfiguration(
    lineHeightMultiple: 1.1,
    ligaturesEnabled: false
  )
}

/// Font metrics, the single-width ASCII glyph table, the run cache, and fallback
/// resolution for CJK, emoji, and combining marks.
///
/// Everything the renderer needs to place text on the monospace grid comes from
/// here, so the editor and the terminal cannot drift apart on cell geometry.
@MainActor
final class TextFontMetrics {
  private struct FallbackKey: Hashable {
    let cluster: String
    let isBold: Bool
  }

  let configuration: TextSurfaceFontConfiguration
  let regularFont: CTFont
  let boldFont: CTFont
  let ascent: CGFloat
  let descent: CGFloat
  let leading: CGFloat
  let cellSize: CGSize
  let runCache: TextRunCache

  private let asciiGlyphs: [CGGlyph]
  private let asciiBoldGlyphs: [CGGlyph]
  private var fallbackFonts: [FallbackKey: CTFont] = [:]
  private(set) var fallbackResolutionCount = 0
  private(set) var fallbackCacheHitCount = 0

  private static let asciiRange = 0x20...0x7e

  init(configuration: TextSurfaceFontConfiguration = TextSurfaceFontConfiguration()) {
    self.configuration = configuration
    let regular = TextFontMetrics.makeFont(
      name: configuration.fontName,
      size: configuration.fontSize,
      bold: false
    )
    let bold = TextFontMetrics.makeFont(
      name: configuration.fontName,
      size: configuration.fontSize,
      bold: true
    )
    regularFont = regular
    boldFont = bold
    ascent = CTFontGetAscent(regular)
    descent = CTFontGetDescent(regular)
    leading = CTFontGetLeading(regular)
    let advance = TextFontMetrics.advance(of: "M", in: regular)
    // Snap the cell to a half-point grid so columns stay on exact multiples and
    // adjacent cells cannot leave seams between damage rectangles.
    let width = max(1, (advance * 2).rounded(.up) / 2)
    let lineHeight = (ascent + descent + leading) * configuration.lineHeightMultiple
    let height = max(1, lineHeight.rounded(.up))
    cellSize = CGSize(width: width, height: height)
    asciiGlyphs = TextFontMetrics.makeASCIIGlyphs(font: regular)
    asciiBoldGlyphs = TextFontMetrics.makeASCIIGlyphs(font: bold)
    runCache = TextRunCache(capacity: configuration.runCacheCapacity)
  }

  /// Distance from the top of a row to its text baseline, in flipped
  /// coordinates.
  var baselineOffset: CGFloat {
    ((cellSize.height - (ascent + descent)) / 2 + ascent).rounded()
  }

  func font(bold: Bool) -> CTFont {
    bold ? boldFont : regularFont
  }

  func columnX(_ column: Int) -> CGFloat {
    CGFloat(column) * cellSize.width
  }

  func rowTop(_ row: Int) -> CGFloat {
    CGFloat(row) * cellSize.height
  }

  /// Glyph for a single-width ASCII scalar, or `nil` when the font does not map
  /// it. A missing glyph is not an error: the renderer shapes that run with
  /// CoreText instead of drawing nothing.
  func asciiGlyph(for scalar: Unicode.Scalar, bold: Bool) -> CGGlyph? {
    guard TextRunClassifier.isFastASCII(scalar) else {
      return nil
    }
    let index = Int(scalar.value) - TextFontMetrics.asciiRange.lowerBound
    let glyph = bold ? asciiBoldGlyphs[index] : asciiGlyphs[index]
    return glyph == 0 ? nil : glyph
  }

  /// Whether the font maps every UTF-16 unit of the cluster.
  func covers(_ cluster: String, bold: Bool) -> Bool {
    TextFontMetrics.covers(cluster, in: font(bold: bold))
  }

  /// Font that can draw the cluster: the base font when it maps the cluster, and
  /// a CoreText-resolved fallback otherwise. Resolutions are cached because
  /// fallback lookup is far more expensive than drawing.
  func font(for cluster: String, bold: Bool) -> CTFont {
    let base = font(bold: bold)
    guard !cluster.isEmpty, !TextFontMetrics.covers(cluster, in: base) else {
      return base
    }
    let key = FallbackKey(cluster: cluster, isBold: bold)
    fallbackResolutionCount += 1
    if let cached = fallbackFonts[key] {
      fallbackCacheHitCount += 1
      return cached
    }
    if fallbackFonts.count >= configuration.fallbackCacheCapacity {
      fallbackFonts.removeAll(keepingCapacity: true)
    }
    let resolved = CTFontCreateForString(
      base,
      cluster as CFString,
      CFRange(location: 0, length: cluster.utf16.count)
    )
    fallbackFonts[key] = resolved
    return resolved
  }

  private static func makeFont(name: String, size: CGFloat, bold: Bool) -> CTFont {
    let font = CTFontCreateWithName(name as CFString, size, nil)
    guard bold else {
      return font
    }
    let traits = CTFontSymbolicTraits.traitBold
    guard let boldFont = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) else {
      return font
    }
    return boldFont
  }

  private static func makeASCIIGlyphs(font: CTFont) -> [CGGlyph] {
    let characters = asciiRange.map { UniChar($0) }
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    // A partial mapping leaves the unmapped entries at zero, which the renderer
    // treats as "shape this run with CoreText".
    _ = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    return glyphs
  }

  private static func covers(_ cluster: String, in font: CTFont) -> Bool {
    let characters = Array(cluster.utf16)
    guard !characters.isEmpty else {
      return true
    }
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    return CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
  }

  private static func advance(of character: Character, in font: CTFont) -> CGFloat {
    let characters = Array(String(character).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else {
      return CTFontGetSize(font) * 0.6
    }
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, glyphs.count)
    let advance = advances.first?.width ?? 0
    return advance > 0 ? advance : CTFontGetSize(font) * 0.6
  }
}

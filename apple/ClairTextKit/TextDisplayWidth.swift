import Foundation

/// Terminal cell width of grapheme clusters.
///
/// Both surfaces place text on the same monospace grid, so the editor and the
/// terminal must agree on how many cells a cluster occupies. Full-width CJK and
/// emoji take two cells, combining marks take none, and everything else takes
/// one.
enum TextDisplayWidth {
  /// East Asian Wide and Fullwidth blocks, plus the emoji planes that render at
  /// double width in monospace fonts.
  private static let wideScalarRanges: [ClosedRange<UInt32>] = [
    0x1100...0x115f,
    0x231a...0x231b,
    0x2329...0x232a,
    0x23e9...0x23ec,
    0x25fd...0x25fe,
    0x2614...0x2615,
    0x2648...0x2653,
    0x267f...0x267f,
    0x2693...0x2693,
    0x26a1...0x26a1,
    0x2e80...0x303e,
    0x3041...0x33ff,
    0x3400...0x4dbf,
    0x4e00...0x9fff,
    0xa000...0xa4cf,
    0xa960...0xa97f,
    0xac00...0xd7a3,
    0xf900...0xfaff,
    0xfe10...0xfe19,
    0xfe30...0xfe6f,
    0xff00...0xff60,
    0xffe0...0xffe6,
    0x1_6fe0...0x1_6fe4,
    0x1_7000...0x1_87f7,
    0x1_b000...0x1_b16f,
    0x1_f004...0x1_f004,
    0x1_f0cf...0x1_f0cf,
    0x1_f18e...0x1_f18e,
    0x1_f191...0x1_f19a,
    0x1_f200...0x1_f320,
    0x1_f32d...0x1_f335,
    0x1_f337...0x1_f37c,
    0x1_f37e...0x1_f393,
    0x1_f3a0...0x1_f3ca,
    0x1_f3cf...0x1_f3d3,
    0x1_f3e0...0x1_f3f0,
    0x1_f3f4...0x1_f3f4,
    0x1_f3f8...0x1_f43e,
    0x1_f440...0x1_f440,
    0x1_f442...0x1_f4fc,
    0x1_f4ff...0x1_f53d,
    0x1_f54b...0x1_f54e,
    0x1_f550...0x1_f567,
    0x1_f57a...0x1_f57a,
    0x1_f595...0x1_f596,
    0x1_f5a4...0x1_f5a4,
    0x1_f5fb...0x1_f64f,
    0x1_f680...0x1_f6c5,
    0x1_f6cc...0x1_f6cc,
    0x1_f6d0...0x1_f6d2,
    0x1_f6d5...0x1_f6d7,
    0x1_f6eb...0x1_f6ec,
    0x1_f6f4...0x1_f6fc,
    0x1_f7e0...0x1_f7eb,
    0x1_f90c...0x1_f93a,
    0x1_f93c...0x1_f945,
    0x1_f947...0x1_f978,
    0x1_f97a...0x1_f9cb,
    0x1_f9cd...0x1_f9ff,
    0x1_fa70...0x1_faff,
    0x2_0000...0x2_fffd,
    0x3_0000...0x3_fffd,
  ]

  /// Splits text into extended grapheme clusters. A family emoji joined by
  /// zero-width joiners and a base character followed by combining marks are each
  /// one cluster.
  static func clusters(in text: String) -> [String] {
    text.map { String($0) }
  }

  /// Cell width of one cluster.
  static func columns(for cluster: Character) -> Int {
    guard let first = cluster.unicodeScalars.first else {
      return 0
    }
    if isZeroWidth(first) {
      return 0
    }
    if cluster.unicodeScalars.contains(where: isEmojiPresentation) {
      return 2
    }
    return isWide(first) ? 2 : 1
  }

  /// Cell width of one cluster expressed as a string.
  static func columns(for cluster: String) -> Int {
    guard let character = cluster.first, cluster.count == 1 else {
      return columns(in: cluster)
    }
    return columns(for: character)
  }

  /// Cell width of a whole row.
  static func columns(in text: String) -> Int {
    text.reduce(0) { partial, character in
      partial + columns(for: character)
    }
  }

  /// Cell column at which the cluster with the given offset starts.
  static func column(ofClusterAt clusterIndex: Int, in text: String) -> Int {
    var column = 0
    for (index, character) in text.enumerated() {
      if index == clusterIndex {
        return column
      }
      column += columns(for: character)
    }
    return column
  }

  private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .enclosingMark, .format:
      return true
    default:
      break
    }
    return scalar.value < 0x20 || scalar.value == 0x7f
  }

  private static func isEmojiPresentation(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isEmojiPresentation
  }

  private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
    wideScalarRanges.contains { $0.contains(scalar.value) }
  }
}

/// Which drawing path a run of text takes.
enum TextRunPath: String, Equatable, Hashable, Sendable {
  /// Single-width ASCII drawn from the precomputed glyph table with arithmetic
  /// positions. This is why the terminal is fast, and the editor uses it too.
  case fastASCII
  /// Anything CoreText has to shape: CJK, emoji, combining marks, and ligatures.
  case coreText
}

/// Decides which path a row takes.
enum TextRunClassifier {
  /// Sequences a programming font may shape into a single ligature glyph. A row
  /// containing one of them is shaped by CoreText even when it is pure ASCII.
  static let ligatureSequences: [String] = [
    "->", "<-", "=>", "<=", ">=", "!=", "==", "===", "!==", "::", ":=", "|>", "<|",
    "//", "/*", "*/", "++", "--", "&&", "||", "...", "<>", "<<", ">>", "??", "?.",
  ]

  static func path(for text: String, ligaturesEnabled: Bool) -> TextRunPath {
    for scalar in text.unicodeScalars where !isFastASCII(scalar) {
      return .coreText
    }
    if ligaturesEnabled, containsLigatureCandidate(text) {
      return .coreText
    }
    return .fastASCII
  }

  static func containsLigatureCandidate(_ text: String) -> Bool {
    ligatureSequences.contains { text.contains($0) }
  }

  static func isFastASCII(_ scalar: Unicode.Scalar) -> Bool {
    (0x20...0x7e).contains(scalar.value)
  }
}

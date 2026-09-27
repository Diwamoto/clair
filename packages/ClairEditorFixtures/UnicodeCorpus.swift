import Foundation

/// A curated set of Unicode cases used to validate editor coordinate and input rules.
///
/// Each case is a named string with a documented purpose. They are intentionally small
/// enough to embed so that tests can run without reading files from disk.
public enum UnicodeCorpus: Sendable {
  /// ASCII with CRLF line endings.
  public static let crlfLines = "line1\r\nline2\r\nline3"

  /// Mixed line endings.
  public static let mixedLineEndings = "a\nb\r\nc\r\nd\n"

  /// Simple CJK.
  public static let japanese = "こんにちは世界"

  /// Combining marks (two visible characters, six scalars).
  public static let combiningMarks = "élève"

  /// ZWJ emoji family.
  public static let zwjEmoji = "👨‍👩‍👧‍👦"

  /// Regional indicator flags (two grapheme clusters, four scalars).
  public static let flags = "🇯🇵🇺🇸"

  /// Right-to-left text.
  public static let rtl = "مرحبا"

  /// Zero-width joiner and variation selector.
  public static let zwjAndVariant = "❤️‍🔥"

  /// A string where every grapheme cluster boundary matters for delete.
  public static let deleteBoundaryCases: [String] = [
    "a",
    "🇯🇵",
    "👨‍👩‍👧‍👦",
    "é",
    "\r\n",
    "こ",
  ]

  /// Names and contents for documented test fixtures.
  public static let namedCases: [(name: String, text: String)] = [
    ("crlf", crlfLines),
    ("mixed-endings", mixedLineEndings),
    ("japanese", japanese),
    ("combining", combiningMarks),
    ("zwj-emoji", zwjEmoji),
    ("flags", flags),
    ("rtl", rtl),
    ("zwj-variant", zwjAndVariant),
  ]

  /// All cases concatenated with newlines, useful for a single-document smoke test.
  public static let concatenated: String = {
    namedCases.map(\.text).joined(separator: "\n")
  }()
}

import Foundation

/// A source backed by plain lines of text.
///
/// It is the terminal-agnostic, editor-agnostic model used by the Dev harness and
/// by tests. `TextBuffer` (`P22`) and `TerminalGridSource` (`P30`) adopt the same
/// protocol later without changing anything above it.
@MainActor
final class TextFixtureSource: TextSurfaceSource {
  private var lines: [String]
  private let style: TextCellStyle
  weak var observer: (any TextSurfaceSourceObserver)?

  init(lines: [String], style: TextCellStyle = .plain(TextSurfaceTheme.oneDark.foreground)) {
    self.lines = lines
    self.style = style
  }

  var rowCount: Int {
    lines.count
  }

  var columnCount: Int {
    lines.reduce(0) { partial, line in
      max(partial, TextDisplayWidth.columns(in: line))
    }
  }

  func row(at index: Int) -> TextSurfaceRow? {
    guard lines.indices.contains(index) else {
      return nil
    }
    return TextSurfaceRow(index: index, text: lines[index], style: style)
  }

  func text(at index: Int) -> String? {
    lines.indices.contains(index) ? lines[index] : nil
  }

  /// Replaces one row and reports exactly that row as damaged.
  func replace(row index: Int, with text: String) {
    guard lines.indices.contains(index) else {
      return
    }
    lines[index] = text
    observer?.textSurfaceSource(self, didInvalidate: TextSurfaceDamage(row: index))
  }

  /// Replaces a range of rows and reports exactly that range as damaged.
  func replace(rows range: Range<Int>, with texts: [String]) {
    let clamped = range.clamped(to: 0..<lines.count)
    guard !clamped.isEmpty, clamped.count == texts.count else {
      return
    }
    lines.replaceSubrange(clamped, with: texts)
    observer?.textSurfaceSource(self, didInvalidate: TextSurfaceDamage(rows: clamped))
  }
}

/// Fixtures the Dev harness draws.
///
/// They exercise the paths the shared surface has to get right before either
/// model layer exists: the single-width ASCII fast path, CJK cell width, emoji
/// and combining clusters, and programming ligatures.
enum TextSurfaceFixture: String, CaseIterable, Identifiable, Sendable {
  case asciiCode
  case ligatures
  case japanese
  case emojiAndCombining
  case mixed

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .asciiCode:
      "ASCII fast path"
    case .ligatures:
      "Ligatures"
    case .japanese:
      "Japanese"
    case .emojiAndCombining:
      "Emoji and combining"
    case .mixed:
      "Mixed"
    }
  }

  var lines: [String] {
    switch self {
    case .asciiCode:
      return TextSurfaceFixture.asciiLines
    case .ligatures:
      return TextSurfaceFixture.ligatureLines
    case .japanese:
      return TextSurfaceFixture.japaneseLines
    case .emojiAndCombining:
      return TextSurfaceFixture.emojiLines
    case .mixed:
      return TextSurfaceFixture.asciiLines + TextSurfaceFixture.japaneseLines
        + TextSurfaceFixture.emojiLines + TextSurfaceFixture.ligatureLines
    }
  }

  @MainActor
  func makeSource() -> TextFixtureSource {
    TextFixtureSource(lines: lines)
  }

  private static let asciiLines = [
    "func render(rows: Range<Int>) {",
    "  for row in rows {",
    "    let text = source.row(at: row)",
    "    renderer.draw(text)",
    "  }",
    "}",
  ]

  private static let ligatureLines = [
    "let mapped = values.map { $0 -> Int }",
    "if a != b && c >= d || e <= f { return }",
    "stream |> filter |> collect // => done",
  ]

  private static let japaneseLines = [
    "日本語の全角文字は二セル幅を占める。",
    "編集中のテキストは damage 矩形だけを描き直す。",
    "半角ｶﾅと全角カナが同じ行に並ぶ場合の桁送り。",
  ]

  private static let emojiLines = [
    "family 👨‍👩‍👧‍👦 and flag 🇯🇵 stay one cluster",
    "combining e\u{0301}\u{0323} and ligature ﬁ in one line",
    "🙂🙃🚀 emoji run followed by ASCII tail",
  ]
}

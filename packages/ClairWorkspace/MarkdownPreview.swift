import Foundation

/// E15: block-level Markdown for the native preview pane. Inline markup (emphasis, code, links) is left to
/// `AttributedString(markdown:)` at render time; this only splits blocks and remembers each block's source line
/// so the preview can follow the editor's scroll position.
/// ponytail: a line-based CommonMark subset (no nested blocks inside quotes/lists, no setext headings, no HTML);
/// swap in swift-markdown if real documents need the full grammar.
public enum MarkdownBlock: Sendable, Equatable {
  case heading(level: Int, text: String)
  case paragraph(String)
  /// `marker` is "•" or the ordered number with its dot; `checked` is set for task-list items.
  case listItem(marker: String, depth: Int, text: String, checked: Bool?)
  case code(language: String, text: String)
  case quote(String)
  case table(header: [String], rows: [[String]])
  case image(alt: String, source: String)
  case rule
}

public struct MarkdownPreviewBlock: Sendable, Equatable {
  /// 0-based source line where the block starts.
  public let line: Int
  public let block: MarkdownBlock
}

public enum MarkdownPreview {
  public static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

  public static func isMarkdown(_ path: String) -> Bool {
    extensions.contains((path as NSString).pathExtension.lowercased())
  }

  public static func parse(_ text: String) -> [MarkdownPreviewBlock] {
    // "\r\n" is one Character, so split on newline characters rather than on "\n".
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    var out: [MarkdownPreviewBlock] = []
    var i = 0
    func add(_ line: Int, _ b: MarkdownBlock) { out.append(MarkdownPreviewBlock(line: line, block: b)) }

    while i < lines.count {
      let raw = lines[i]
      let t = raw.trimmingCharacters(in: .whitespaces)
      let start = i
      if t.isEmpty { i += 1; continue }

      // Fenced code: everything up to the matching fence (or the end) is literal.
      if let fence = ["```", "~~~"].first(where: { t.hasPrefix($0) }) {
        let language = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        i += 1
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { body.append(lines[i]); i += 1 }
        i += 1
        add(start, .code(language: language, text: body.joined(separator: "\n")))
        continue
      }
      if let level = heading(t) {
        add(start, .heading(level: level, text: t.dropFirst(level).trimmingCharacters(in: .whitespaces)
          .replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)))
        i += 1; continue
      }
      if t.count >= 3, let c = t.first, "-*_".contains(c), t.allSatisfy({ $0 == c || $0 == " " }) {
        add(start, .rule); i += 1; continue
      }
      if let (alt, src) = image(t) { add(start, .image(alt: alt, source: src)); i += 1; continue }
      if t.hasPrefix(">") {
        var body: [String] = []
        while i < lines.count, case let q = lines[i].trimmingCharacters(in: .whitespaces), q.hasPrefix(">") {
          body.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
        }
        add(start, .quote(body.joined(separator: "\n"))); continue
      }
      if let item = listItem(raw) { add(start, item); i += 1; continue }
      if t.hasPrefix("|"), i + 1 < lines.count, isTableDivider(lines[i + 1]) {
        let header = cells(t)
        var rows: [[String]] = []
        i += 2
        while i < lines.count, case let r = lines[i].trimmingCharacters(in: .whitespaces), r.hasPrefix("|") {
          rows.append(cells(r)); i += 1
        }
        add(start, .table(header: header, rows: rows)); continue
      }
      // Paragraph: consecutive lines until a blank line or another block starts.
      var body = [t]
      i += 1
      while i < lines.count {
        let n = lines[i].trimmingCharacters(in: .whitespaces)
        if n.isEmpty || heading(n) != nil || n.hasPrefix("```") || n.hasPrefix("~~~") || n.hasPrefix(">")
          || listItem(lines[i]) != nil || image(n) != nil { break }
        body.append(n); i += 1
      }
      add(start, .paragraph(body.joined(separator: "\n")))
    }
    return out
  }

  /// Index of the last block starting at or above `line` — what the preview scrolls to.
  public static func block(at line: Int, in blocks: [MarkdownPreviewBlock]) -> Int? {
    blocks.lastIndex { $0.line <= line } ?? (blocks.isEmpty ? nil : 0)
  }

  /// An image source as a local file inside `root`, or nil. Remote/scheme URLs are never loaded (spec §12:
  /// the preview must not fetch arbitrary URLs), and `..`/symlinks cannot escape the Project.
  public static func localImage(_ source: String, root: String, file: String) -> URL? {
    let src = source.removingPercentEncoding ?? source
    guard !src.isEmpty, !src.contains(":") else { return nil }
    let base = src.hasPrefix("/") ? root : (root as NSString).appendingPathComponent((file as NSString).deletingLastPathComponent)
    let resolved = URL(fileURLWithPath: (base as NSString).appendingPathComponent(src)).standardizedFileURL.resolvingSymlinksInPath()
    let top = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    return resolved.path.hasPrefix(top.hasSuffix("/") ? top : top + "/") ? resolved : nil
  }

  private static func heading(_ t: String) -> Int? {
    let n = t.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(n) else { return nil }
    let rest = t.dropFirst(n)
    return rest.isEmpty || rest.first == " " ? n : nil
  }

  private static func image(_ t: String) -> (String, String)? {
    guard let m = t.wholeMatch(of: /!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/) else { return nil }
    return (String(m.1), String(m.2))
  }

  private static func listItem(_ raw: String) -> MarkdownBlock? {
    guard let m = raw.wholeMatch(of: /(\s*)([-*+]|\d{1,9}[.)])\s+(.*)/) else { return nil }
    let depth = m.1.replacingOccurrences(of: "\t", with: "  ").count / 2
    var text = String(m.3)
    var checked: Bool?
    if let box = text.prefixMatch(of: /\[([ xX])\]\s+/) {
      checked = box.1 != " "
      text = String(text[box.range.upperBound...])
    }
    let marker = m.2.count > 1 ? String(m.2.dropLast()) + "." : "•"
    return .listItem(marker: marker, depth: depth, text: text, checked: checked)
  }

  private static func isTableDivider(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
  }

  private static func cells(_ row: String) -> [String] {
    var t = Substring(row)
    if t.hasPrefix("|") { t = t.dropFirst() }
    if t.hasSuffix("|") { t = t.dropLast() }
    return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
  }
}

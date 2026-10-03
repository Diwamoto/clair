import Foundation

/// Whole-document formatters that don't need a language server. Only JSON; source files go through the
/// language server's `textDocument/formatting` (the GUI falls back to this when the server cannot format).
public enum DocumentFormatter {
  public static func supports(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "json"
  }

  /// Files `editor.format` is offered for: JSON here, or a language whose server may format it (the GUI asks the
  /// server and reports when it cannot).
  // ponytail: mirrors the extensions of `EditorLanguageID` that have a formatting-capable server; keep in step.
  public static func mayFormat(_ path: String) -> Bool {
    supports(path) || serverFormatted.contains((path as NSString).pathExtension.lowercased())
  }

  static let serverFormatted: Set<String> = [
    "go", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rs", "swift", "c", "h", "rb", "java", "php", "tf", "tfvars", "hcl",
    "sh", "bash", "zsh", "html", "htm", "css", "yaml", "yml", "toml",
  ]

  /// nil when `path` isn't a supported format or `text` isn't valid JSON.
  public static func format(_ path: String, _ text: String) -> String? {
    guard supports(path) else { return nil }
    return JSONFormatter.format(text)
  }
}

/// A minimal recursive-descent JSON pretty-printer. It re-indents structure only: object/array
/// entries, strings and numbers are kept as their exact source substrings (quotes, escapes, and
/// numeric text untouched), so it never re-orders keys or rewrites a literal the way decoding
/// through `JSONSerialization`/`Codable` and re-encoding would. Malformed JSON returns nil rather
/// than guessing at a repair.
public enum JSONFormatter {
  indirect enum Node {
    case object([(key: String, value: Node)])
    case array([Node])
    case scalar(String)
  }

  public static func format(_ text: String, indent: Int = 2) -> String? {
    var parser = Parser(text)
    guard let node = parser.parseValue() else { return nil }
    parser.skipWhitespace()
    guard parser.atEnd else { return nil }
    var out = ""
    write(node, depth: 0, indent: indent, into: &out)
    out += "\n"
    return out
  }

  private static func write(_ node: Node, depth: Int, indent: Int, into out: inout String) {
    switch node {
    case .scalar(let raw):
      out += raw
    case .array(let items):
      guard !items.isEmpty else { out += "[]"; return }
      out += "[\n"
      let pad = String(repeating: " ", count: (depth + 1) * indent)
      for (i, item) in items.enumerated() {
        out += pad
        write(item, depth: depth + 1, indent: indent, into: &out)
        out += i < items.count - 1 ? ",\n" : "\n"
      }
      out += String(repeating: " ", count: depth * indent) + "]"
    case .object(let entries):
      guard !entries.isEmpty else { out += "{}"; return }
      out += "{\n"
      let pad = String(repeating: " ", count: (depth + 1) * indent)
      for (i, entry) in entries.enumerated() {
        out += pad + entry.key + ": "
        write(entry.value, depth: depth + 1, indent: indent, into: &out)
        out += i < entries.count - 1 ? ",\n" : "\n"
      }
      out += String(repeating: " ", count: depth * indent) + "}"
    }
  }

  private struct Parser {
    let chars: [Character]
    var i = 0

    init(_ s: String) { chars = Array(s) }

    var atEnd: Bool { i >= chars.count }
    func peek() -> Character? { i < chars.count ? chars[i] : nil }

    mutating func skipWhitespace() { while let c = peek(), c.isWhitespace { i += 1 } }

    mutating func parseValue() -> Node? {
      skipWhitespace()
      switch peek() {
      case "{": return parseObject()
      case "[": return parseArray()
      case "\"": return parseStringLiteral().map { .scalar($0) }
      case .some: return parseLiteral()
      case nil: return nil
      }
    }

    mutating func parseObject() -> Node? {
      i += 1  // consume "{"
      var entries: [(key: String, value: Node)] = []
      skipWhitespace()
      if peek() == "}" { i += 1; return .object(entries) }
      while true {
        skipWhitespace()
        guard peek() == "\"", let key = parseStringLiteral() else { return nil }
        skipWhitespace()
        guard peek() == ":" else { return nil }
        i += 1
        guard let value = parseValue() else { return nil }
        entries.append((key, value))
        skipWhitespace()
        switch peek() {
        case ",": i += 1
        case "}": i += 1; return .object(entries)
        default: return nil
        }
      }
    }

    mutating func parseArray() -> Node? {
      i += 1  // consume "["
      var items: [Node] = []
      skipWhitespace()
      if peek() == "]" { i += 1; return .array(items) }
      while true {
        guard let value = parseValue() else { return nil }
        items.append(value)
        skipWhitespace()
        switch peek() {
        case ",": i += 1
        case "]": i += 1; return .array(items)
        default: return nil
        }
      }
    }

    /// Raw source text of the string literal, quotes and escapes included.
    mutating func parseStringLiteral() -> String? {
      guard peek() == "\"" else { return nil }
      var raw = "\""
      i += 1
      while true {
        guard let c = peek() else { return nil }  // unterminated
        if c == "\\" {
          raw.append(c); i += 1
          guard let escaped = peek() else { return nil }
          raw.append(escaped); i += 1
          continue
        }
        raw.append(c); i += 1
        if c == "\"" { return raw }
      }
    }

    /// A bare number/`true`/`false`/`null` token, up to the next structural character or whitespace.
    mutating func parseLiteral() -> Node? {
      let start = i
      while let c = peek(), !"{}[]:,\"".contains(c), !c.isWhitespace { i += 1 }
      guard i > start else { return nil }
      let raw = String(chars[start..<i])
      guard raw == "true" || raw == "false" || raw == "null"
        || raw.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) != nil
      else { return nil }
      return .scalar(raw)
    }
  }
}

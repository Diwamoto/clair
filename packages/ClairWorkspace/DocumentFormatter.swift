import Foundation

/// Whole-document formatters that don't need a language server: JSON and SQL, picked by extension or — for a file
/// without one (`.eslintrc`, `query`, a scratch file) — by sniffing its text. Other source files go through the
/// language server's `textDocument/formatting`.
public enum DocumentFormatter {
  public enum Builtin { case json, sql }

  /// The built-in formatter for `path`, or nil when its language server formats it.
  public static func builtin(_ path: String, _ text: String) -> Builtin? {
    switch (path as NSString).pathExtension.lowercased() {
    case "json": return .json
    case "sql": return .sql
    case "":
      let t = text.drop { $0.isWhitespace }
      if t.first == "{" || t.first == "[" { return .json }
      let word = t.prefix { $0.isLetter }.uppercased()
      return sqlStarts.contains(word) ? .sql : nil
    default: return nil
    }
  }

  static let sqlStarts: Set<String> = [
    "SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "TRUNCATE", "EXPLAIN", "MERGE", "GRANT",
  ]

  /// Files `editor.format` is offered for: JSON/SQL here, an extensionless file (sniffed when formatted), or a
  /// language whose server may format it (the GUI asks the server and reports when it cannot).
  // ponytail: mirrors the extensions of `EditorLanguageID` that have a formatting-capable server; keep in step.
  public static func mayFormat(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return ["json", "sql", ""].contains(ext) || serverFormatted.contains(ext)
  }

  static let serverFormatted: Set<String> = [
    "go", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rs", "swift", "c", "h", "rb", "java", "php", "tf", "tfvars", "hcl",
    "sh", "bash", "zsh", "html", "htm", "css", "yaml", "yml", "toml",
  ]

  /// nil when no built-in formatter handles `path`, or `text` doesn't parse.
  public static func format(_ path: String, _ text: String) -> String? {
    switch builtin(path, text) {
    case .json: JSONFormatter.format(text)
    case .sql: SQLFormatter.format(text)
    case nil: nil
    }
  }

  /// The UTF-8 byte range of `old` to replace, and its replacement, that turns `old` into `new` — whole lines, with the
  /// unchanged leading and trailing lines left out, so applying it leaves the caret and scroll of untouched lines alone.
  public static func changedLines(from old: String, to new: String) -> (range: Range<Int>, replacement: String) {
    let a = old.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    let b = new.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    var head = 0
    while head < min(a.count, b.count) - 1, a[head].elementsEqual(b[head]) { head += 1 }
    var tail = 0
    while tail < min(a.count, b.count) - head - 1, a[a.count - 1 - tail].elementsEqual(b[b.count - 1 - tail]) { tail += 1 }
    let lineBytes = { (l: [Substring.UTF8View]) in l.reduce(0) { $0 + $1.count + 1 } }
    let start = lineBytes(Array(a[..<head]))
    let end = old.utf8.count - lineBytes(Array(a.suffix(tail)))
    let bStart = lineBytes(Array(b[..<head]))
    let bEnd = new.utf8.count - lineBytes(Array(b.suffix(tail)))
    let bytes = Array(new.utf8)[bStart..<bEnd]
    return (start..<end, String(decoding: bytes, as: UTF8.self))
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

/// A small SQL layout pass: clauses start their own line with their body indented below, top-level list commas and
/// AND/OR break lines, a `(SELECT …)` subquery is indented as a block, and known keywords are upper-cased. Strings,
/// quoted identifiers and comments are kept byte for byte. No dialect parse, so it never rejects input.
// ponytail: no line-width wrapping and CREATE TABLE column lists stay on one line; a dialect-aware formatter
// (sqls/pg_format) is the upgrade if that matters.
public enum SQLFormatter {
  static let clauses: Set<String> = [
    "SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "UNION", "UNION ALL", "INTERSECT",
    "EXCEPT", "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "RETURNING", "WITH", "WINDOW", "ON CONFLICT",
  ]
  static let keywords: Set<String> = Set([
    "AS", "ON", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "ILIKE", "BETWEEN", "EXISTS", "CASE", "WHEN", "THEN",
    "ELSE", "END", "DISTINCT", "ALL", "ASC", "DESC", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS",
    "NATURAL", "USING", "INTO", "BY", "GROUP", "ORDER", "UNION", "INSERT", "DELETE", "CREATE", "TABLE", "INDEX", "VIEW",
    "ALTER", "DROP", "ADD", "COLUMN", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "UNIQUE", "CONSTRAINT",
    "IF", "TRUE", "FALSE", "DO", "NOTHING", "CONFLICT", "RECURSIVE", "OVER", "PARTITION", "FILTER", "CAST", "INTERVAL",
  ]).union(clauses)
  static let joinWords: Set<String> = ["LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL", "JOIN"]

  enum Kind { case word, string, lineComment, blockComment, punct }

  static func tokenize(_ text: String) -> [(kind: Kind, text: String, newlineBefore: Bool)] {
    let c = Array(text)
    var out: [(Kind, String, Bool)] = []
    var i = 0
    var newline = false
    func run(while ok: (Character) -> Bool) -> String {
      let s = i
      while i < c.count, ok(c[i]) { i += 1 }
      return String(c[s..<i])
    }
    while i < c.count {
      let ch = c[i]
      if ch.isWhitespace { if ch.isNewline { newline = true }; i += 1; continue }
      let start = i
      let kind: Kind
      if ch == "-", i + 1 < c.count, c[i + 1] == "-" {
        _ = run { !$0.isNewline }; kind = .lineComment
      } else if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
        i += 2
        while i < c.count, !(c[i] == "*" && i + 1 < c.count && c[i + 1] == "/") { i += 1 }
        i = min(i + 2, c.count); kind = .blockComment
      } else if ch == "'" || ch == "\"" || ch == "`" {
        i += 1
        while i < c.count {
          if c[i] == ch { if i + 1 < c.count, c[i + 1] == ch { i += 2; continue }; i += 1; break }
          i += 1
        }
        kind = .string
      } else if ch.isLetter || ch.isNumber || "_$@:?.".contains(ch) && !(ch == ":" && i + 1 < c.count && c[i + 1] == ":") {
        i += 1
        _ = run { $0.isLetter || $0.isNumber || "_$.".contains($0) }; kind = .word
      } else if "(),;".contains(ch) {
        i += 1; kind = .punct
      } else {
        _ = run { "<>=!|:+-*/%&^~".contains($0) }
        if i == start { i += 1 }
        kind = .punct
      }
      out.append((kind, String(c[start..<i]), newline))
      newline = false
    }
    return out.map { (kind: $0.0, text: $0.1, newlineBefore: $0.2) }
  }

  public static func format(_ text: String, indent: Int = 2) -> String {
    var toks = tokenize(text)
    // Merge multi-word clauses (GROUP BY, LEFT OUTER JOIN, …) into one word token.
    var merged: [(kind: Kind, text: String, newlineBefore: Bool)] = []
    var k = 0
    while k < toks.count {
      var t = toks[k]
      if t.kind == .word {
        let up = t.text.uppercased()
        if joinWords.contains(up) {
          var j = k
          while j + 1 < toks.count, toks[j].text.uppercased() != "JOIN", toks[j + 1].kind == .word,
            joinWords.contains(toks[j + 1].text.uppercased()) { j += 1 }
          if toks[j].text.uppercased() == "JOIN" {
            t.text = toks[k...j].map(\.text).joined(separator: " "); k = j
          }
        } else if k + 1 < toks.count, toks[k + 1].kind == .word,
          clauses.contains(up + " " + toks[k + 1].text.uppercased())
        {
          t.text += " " + toks[k + 1].text; k += 1
          if up == "UNION", k + 1 < toks.count, toks[k + 1].text.uppercased() == "ALL" { t.text += " " + toks[k + 1].text; k += 1 }
        }
      }
      merged.append(t); k += 1
    }
    toks = merged

    var out = ""
    var base = 0  // indent level of the current clause keyword
    var blocks: [(isBlock: Bool, base: Int)] = []  // open parens
    var pendingBreak: Int?  // indent level of a line break owed before the next token
    var prev: (kind: Kind, text: String)?
    func pad(_ level: Int) -> String { String(repeating: " ", count: level * indent) }
    func emit(_ s: String, space: Bool) {
      if let level = pendingBreak {
        if !out.isEmpty { out += (out.hasSuffix("\n") ? "" : "\n") + pad(level) }
        pendingBreak = nil
      } else if space, !out.isEmpty, !out.hasSuffix("\n") {
        out += " "
      }
      out += s
    }

    for (n, t) in toks.enumerated() {
      let up = t.text.uppercased()
      let isKeyword = t.kind == .word && (keywords.contains(up) || up.hasSuffix(" JOIN"))
      let word = isKeyword ? up : t.text
      let inList = blocks.last.map { !$0.isBlock } ?? false
      switch t.kind {
      case .lineComment, .blockComment:
        if t.newlineBefore, pendingBreak == nil, !out.isEmpty { pendingBreak = out.hasSuffix("\n") ? base : base + 1 }
        if !t.newlineBefore, let owed = pendingBreak {  // a trailing comment stays on its line
          pendingBreak = nil; emit(t.text, space: true); pendingBreak = owed
        } else {
          emit(t.text, space: true)
        }
        if t.kind == .lineComment { pendingBreak = pendingBreak ?? base + 1 }
      case .word where !inList && clauses.contains(up):
        if up == "UPDATE", prev?.text.uppercased() == "DO" { emit(word, space: true); break }  // ON CONFLICT DO UPDATE
        pendingBreak = base
        emit(word, space: true)
        if up != "ON CONFLICT" { pendingBreak = base + 1 }
      case .word where !inList && up.hasSuffix(" JOIN"):
        pendingBreak = base + 1
        emit(word, space: true)
      case .word where !inList && (up == "AND" || up == "OR"):
        if !betweenOpen(toks, before: n) { pendingBreak = base + 1 }
        emit(word, space: true)
      case .punct where t.text == "(":
        let isSub = n + 1 < toks.count && ["SELECT", "WITH"].contains(toks[n + 1].text.uppercased())
        // `count(` hugs its name; `INSERT INTO t (a, b)` / `CREATE TABLE t (…)` keep the space.
        let call = prev.map { $0.kind == .word && !keywords.contains($0.text.uppercased()) } ?? false
          && !(n >= 2 && ["INSERT INTO", "INTO", "TABLE", "EXISTS", "REFERENCES", "VIEW"].contains(toks[n - 2].text.uppercased()))
        emit("(", space: !call)
        blocks.append((isSub, base))
        if isSub { base += 2; pendingBreak = base }  // the paren sits on the clause body line, one level in
      case .punct where t.text == ")":
        let open = blocks.popLast()
        if let open, open.isBlock { base = open.base; pendingBreak = base + 1 }
        emit(")", space: false)
      case .punct where t.text == ",":
        pendingBreak = nil
        emit(",", space: false)
        if !inList { pendingBreak = base + 1 }
      case .punct where t.text == ";":
        pendingBreak = nil
        emit(";", space: false)
        out += "\n"
        base = 0; blocks = []
        if n + 1 < toks.count { out += "\n" }
      case .punct where t.text == "::":
        emit(t.text, space: false)
      default:
        let glued = prev.map { $0.text == "(" || $0.text == "::" } ?? true
        emit(word, space: !glued)
      }
      prev = (t.kind, t.text)
    }
    if !out.hasSuffix("\n") { out += "\n" }
    return out
  }

  /// Whether the AND at `n` closes a `BETWEEN x AND y` (it stays on the line).
  static func betweenOpen(_ toks: [(kind: Kind, text: String, newlineBefore: Bool)], before n: Int) -> Bool {
    var depth = 0
    for j in stride(from: n - 1, through: 0, by: -1) {
      let up = toks[j].text.uppercased()
      if toks[j].text == ")" { depth += 1 } else if toks[j].text == "(" { if depth == 0 { return false }; depth -= 1 }
      if depth > 0 { continue }
      if up == "BETWEEN" { return true }
      if up == "AND" || up == "OR" || clauses.contains(up) || toks[j].text == "," { return false }
    }
    return false
  }
}

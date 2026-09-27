import Foundation

/// CSV / TSV for the table view in the preview pane: RFC 4180 quoting, a round trip back to text.
/// ponytail: whole-file parse per render; stream or page rows if multi-MB tables lag.
public enum TableFile {
  /// Field separator by extension, nil when the file is not a table.
  public static func separator(_ path: String) -> Character? {
    switch (path as NSString).pathExtension.lowercased() {
    case "csv": ","
    case "tsv", "tab": "\t"
    default: nil
    }
  }

  /// Spreadsheet column label: 0 → "A", 25 → "Z", 26 → "AA".
  public static func columnName(_ i: Int) -> String {
    i < 26 ? String(UnicodeScalar(65 + i)!) : columnName(i / 26 - 1) + columnName(i % 26)
  }

  public static func parse(_ text: String, separator sep: Character) -> [[String]] {
    var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
    var it = Array(text).makeIterator(), pending: Character? = nil
    func next() -> Character? { if let p = pending { pending = nil; return p }; return it.next() }
    while let c = next() {
      if quoted {
        if c == "\"" {
          if let n = next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
        } else { field.append(c) }
      } else if c == "\"" && field.isEmpty {
        quoted = true
      } else if c == sep {
        row.append(field); field = ""
      } else if c == "\n" || c == "\r\n" || c == "\r" {  // "\r\n" is one Character in Swift
        row.append(field); rows.append(row); row = []; field = ""
      } else { field.append(c) }
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
  }

  /// Rows back to text; a trailing newline and CRLF are kept when the original had them.
  public static func serialize(_ rows: [[String]], separator sep: Character, lineEnding: String = "\n", trailingNewline: Bool = true) -> String {
    let body = rows.map { $0.map { quote($0, sep) }.joined(separator: String(sep)) }.joined(separator: lineEnding)
    return trailingNewline && !rows.isEmpty ? body + lineEnding : body
  }

  private static func quote(_ f: String, _ sep: Character) -> String {
    guard f.contains(sep) || f.contains("\"") || f.contains(where: \.isNewline) else { return f }
    return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

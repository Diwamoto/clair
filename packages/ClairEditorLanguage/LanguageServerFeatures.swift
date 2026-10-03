import ClairEditorCore
import Foundation
import LanguageServerProtocol

// Host-side shapes of the language features beyond completion/definition (hover, signature help, rename,
// code actions, formatting, document symbols, server-initiated edits). The host never touches LSP wire types:
// an edit stays in LSP coordinates (0-based line, UTF-16 character) until the host converts it against the
// snapshot it applies to, because a file the server edits may not be open anywhere in Clair.

/// One replacement in LSP coordinates.
public struct LanguageServerTextEdit: Sendable, Hashable {
  public let startLine: Int
  public let startCharacter: Int
  public let endLine: Int
  public let endCharacter: Int
  public let newText: String

  public init(startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int, newText: String) {
    self.startLine = startLine; self.startCharacter = startCharacter
    self.endLine = endLine; self.endCharacter = endCharacter
    self.newText = newText
  }

  init(_ e: LanguageServerProtocol.TextEdit) {
    self.init(
      startLine: e.range.start.line, startCharacter: e.range.start.character,
      endLine: e.range.end.line, endCharacter: e.range.end.character, newText: e.newText)
  }

  var range: LSPRange {
    LSPRange(start: Position(line: startLine, character: startCharacter), end: Position(line: endLine, character: endCharacter))
  }

  /// `edits` as one editor transaction on `snapshot`: sorted, with touching inserts merged (LSP applies inserts at the
  /// same position in array order; the editor wants non-overlapping edits). nil when a range is outside `snapshot`.
  public static func editorEdits(_ edits: [LanguageServerTextEdit], in snapshot: TextSnapshot) -> [ClairEditorCore.TextEdit]? {
    var converted: [(range: TextUTF8Range, text: String, order: Int)] = []
    for (i, e) in edits.enumerated() {
      guard let r = try? LSPCoordinates.utf8Range(e.range, in: snapshot), r.lowerBound.value <= r.upperBound.value else { return nil }
      converted.append((r, e.newText, i))
    }
    converted.sort { ($0.range.lowerBound.value, $0.order) < ($1.range.lowerBound.value, $1.order) }
    var out: [ClairEditorCore.TextEdit] = []
    for c in converted {
      if let last = out.last, last.range.upperBound.value > c.range.lowerBound.value { return nil }  // overlapping: not a valid LSP edit
      if let last = out.last, last.range.upperBound == c.range.lowerBound,
        last.range.lowerBound == last.range.upperBound || c.range.lowerBound == c.range.upperBound
      {
        out[out.count - 1] = ClairEditorCore.TextEdit(
          range: TextUTF8Range(last.range.lowerBound, c.range.upperBound), replacement: last.replacement + c.text)
        continue
      }
      out.append(ClairEditorCore.TextEdit(range: c.range, replacement: c.text))
    }
    return out.filter { !($0.range.lowerBound == $0.range.upperBound && $0.replacement.isEmpty) }
  }

  /// `edits` applied to `text` (a file that is not open), or nil when a range does not fit it.
  public static func apply(_ edits: [LanguageServerTextEdit], to text: String) -> String? {
    guard let buffer = try? TextBuffer(text), let changes = editorEdits(edits, in: buffer.snapshot) else { return nil }
    let snapshot = buffer.snapshot
    var out = ""
    var cursor = UTF8Offset(0)
    for c in changes {
      guard let kept = try? snapshot.text(in: TextUTF8Range(cursor, c.range.lowerBound)) else { return nil }
      out += kept + c.replacement
      cursor = c.range.upperBound
    }
    guard let tail = try? snapshot.text(in: TextUTF8Range(cursor, UTF8Offset(snapshot.utf8Count))) else { return nil }
    return out + tail
  }
}

/// Text edits per absolute file path. File creation, renaming and deletion are not carried.
// ponytail: resource operations (create/rename/delete) are dropped; a server that needs them gets `applied: false`.
public struct LanguageServerWorkspaceEdit: Sendable, Hashable {
  public var files: [String: [LanguageServerTextEdit]]
  /// Present when the server sent file operations Clair does not perform.
  public var unsupported: Bool

  public init(files: [String: [LanguageServerTextEdit]], unsupported: Bool = false) {
    self.files = files; self.unsupported = unsupported
  }

  init(_ e: WorkspaceEdit) {
    var files: [String: [LanguageServerTextEdit]] = [:]
    var unsupported = false
    for (uri, edits) in e.changes ?? [:] { files[LanguageServerClient.path(uri), default: []] += edits.map(LanguageServerTextEdit.init) }
    for change in e.documentChanges ?? [] {
      switch change {
      case .textDocumentEdit(let d):
        files[LanguageServerClient.path(d.textDocument.uri), default: []] += d.edits.map(LanguageServerTextEdit.init)
      case .createFile, .renameFile, .deleteFile: unsupported = true
      }
    }
    self.init(files: files, unsupported: unsupported)
  }

  public var isEmpty: Bool { files.values.allSatisfy(\.isEmpty) }
}

/// A quick fix / refactoring offered at a range. Choosing it applies `edit`, then runs its server command, if any.
public struct LanguageServerCodeAction: Sendable, Hashable {
  public let title: String
  public let kind: String?
  public let isPreferred: Bool
  public let edit: LanguageServerWorkspaceEdit?
  let command: Command?

  public var runsCommand: Bool { command != nil }
}

/// The signature the caret is inside, for the parameter hint under the caret.
public struct LanguageServerSignature: Sendable, Hashable {
  public let label: String
  /// The active parameter's span inside `label` (Character offsets), when the server names one.
  public let activeParameter: Range<Int>?
  public let documentation: String?
}

/// A symbol of one document, for "Go to Symbol in File".
public struct LanguageServerDocumentSymbol: Sendable, Hashable {
  public let name: String
  public let detail: String?
  /// Nesting depth (0 = top level), for indentation.
  public let depth: Int
  /// 0-based line and UTF-16 column of the symbol's name.
  public let line: Int
  public let character: Int
}

/// Plain text of an LSP documentation value; Markdown is kept as written (the popup shows it verbatim).
func documentationText(_ doc: TwoTypeOption<String, MarkupContent>?) -> String? {
  switch doc {
  case .optionA(let s)?: s.isEmpty ? nil : s
  case .optionB(let m)?: m.value.isEmpty ? nil : m.value
  case nil: nil
  }
}

/// Expands an LSP snippet (`$1`, `${2:name}`, `${3|a,b|}`, `$TM_FILENAME`, `${VAR:default}`) into plain text and the
/// span of the first stop (`$1`, else `$0`, else the end), so accepting a completion inserts text and places the caret.
// ponytail: one-shot expansion; tab-stop navigation (Tab to $2…) is not kept after insertion.
public enum LanguageServerSnippet {
  public struct Expansion: Sendable, Equatable {
    public let text: String
    /// UTF-8 offsets inside `text` of the first stop; an empty range is a caret, else the placeholder to select.
    public let selection: Range<Int>
  }

  public static func expand(_ snippet: String) -> Expansion {
    var out = ""
    var stops: [Int: Range<Int>] = [:]
    let chars = Array(snippet)
    var i = 0
    func parse(until terminator: Character?) {
      while i < chars.count {
        let c = chars[i]
        if let terminator, c == terminator { return }
        if c == "\\", i + 1 < chars.count, "$}\\,|".contains(chars[i + 1]) {
          out.append(chars[i + 1]); i += 2; continue
        }
        guard c == "$", i + 1 < chars.count else { out.append(c); i += 1; continue }
        let next = chars[i + 1]
        if next.isNumber {  // $1
          var j = i + 1, n = 0
          while j < chars.count, let d = chars[j].wholeNumberValue { n = n * 10 + d; j += 1 }
          let at = out.utf8.count
          if stops[n] == nil { stops[n] = at..<at }
          i = j; continue
        }
        if next.isLetter || next == "_" {  // $VAR: no variables are resolved
          var j = i + 1
          while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
          i = j; continue
        }
        guard next == "{" else { out.append(c); i += 1; continue }
        i += 2
        var name = ""
        while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { name.append(chars[i]); i += 1 }
        let number = Int(name)
        let start = out.utf8.count
        if i < chars.count, chars[i] == ":" {  // ${1:placeholder} / ${VAR:default}, possibly nested
          i += 1
          parse(until: "}")
        } else if i < chars.count, chars[i] == "|" {  // ${1|a,b|}: the first choice
          i += 1
          var choice = "", first = true
          while i < chars.count, chars[i] != "|" {
            if chars[i] == "," { first = false } else if first { choice.append(chars[i]) }
            i += 1
          }
          out += choice
          i += 1
        }
        while i < chars.count, chars[i] != "}" { i += 1 }  // skip an unsupported transform
        i += 1
        if let number, stops[number] == nil { stops[number] = start..<out.utf8.count }
      }
    }
    parse(until: nil)
    let end = out.utf8.count
    let first = stops.keys.filter { $0 > 0 }.min().flatMap { stops[$0] } ?? stops[0] ?? (end..<end)
    return Expansion(text: out, selection: first)
  }
}

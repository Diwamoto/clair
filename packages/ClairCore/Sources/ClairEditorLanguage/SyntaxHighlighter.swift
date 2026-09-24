import ClairEditorCore
import ClairEditorView
import SwiftTreeSitter

/// E11: maps a tree-sitter capture name (`@keyword`, `@string.special`, ...)
/// onto the coarse `EditorTokenKind` the renderer knows how to paint.
/// Unrecognized captures — punctuation, delimiters, `@spell`, anything a
/// vendored query names that this switch doesn't list — fall back to
/// `.plain`, never throw. Matched on the capture's first dotted component
/// only (`nameComponents.first`), since e.g. `string.special.key` should
/// still resolve as a string.
///
/// ponytail: coarse first-component matching, not the full capture
/// hierarchy (e.g. `@keyword.return` and `@keyword.function` both just
/// become `.keyword`). `EditorTokenKind` only has 9 cases; a richer palette
/// would need `EditorTokenKind` itself to grow first.
enum CaptureMapping {
  static func kind(for nameComponents: [String]) -> EditorTokenKind {
    guard let first = nameComponents.first else { return .plain }
    switch first {
    case "keyword": return .keyword
    // JSON object keys, Markdown headings/markers, JSX tags: One Dark red.
    case "string" where nameComponents.last == "key": return .tag
    case "tag": return .tag
    case "text":
      switch nameComponents.dropFirst().first {
      case "title": return .tag
      case "literal": return .string
      case "uri", "reference": return .function
      default: return .plain
      }
    case "string", "character": return .string
    case "comment": return .comment
    case "number", "float": return .number
    case "constant" where nameComponents.count > 1: return .number
    case "type": return .type
    case "function", "method", "constructor": return .function
    case "variable", "parameter", "property", "field", "attribute": return .variable
    default: return .plain
    }
  }
}

/// Owns one file's `SyntaxParser` + compiled query and turns a parse tree
/// into `[EditorHighlightSpan]`. One instance per open file, on the actor
/// that also owns that file's parser (see `ClairAppKit`'s per-file
/// highlight task) — not `Sendable`, same as `SyntaxParser` itself.
public final class SyntaxHighlighter {
  public let languageID: EditorLanguageID
  private let parser: SyntaxParser
  private let query: Query?
  /// E13: foldable ranges of the last parse — one per header line (the
  /// widest multi-line syntax node starting on it), sorted by start.
  public private(set) var foldRanges: [TextUTF8Range] = []

  public init(languageID: EditorLanguageID) throws {
    self.languageID = languageID
    let grammar = languageID.grammar
    self.parser = try SyntaxParser(language: grammar.language)
    self.query = grammar.query
  }

  /// Full parse + highlight, for a freshly opened file or whenever `update`
  /// falls back to it. `INV-PERF-005`: cancellable by the caller wrapping
  /// this in a `Task` it can cancel; a mid-flight cancellation just discards
  /// the result, `parser`'s own state is left exactly as it was before.
  public func reset(to snapshot: TextSnapshot) throws -> [EditorHighlightSpan] {
    let tree = try parser.reset(to: snapshot)
    foldRanges = Self.folds(tree: tree, languageID: languageID)
    return Self.spans(tree: tree, query: query)
  }

  /// Incremental reparse (`SyntaxParser.update`, this type never reparses
  /// from scratch itself) plus a fresh highlight pass over the resulting
  /// tree. tree-sitter has no incremental *query* API in this binding, so
  /// re-running the query over the (incrementally reparsed) tree is what
  /// keeps this fast: `SyntaxParser.lastReadByteCount` after this call is
  /// still the cheap incremental number: BUDGET-OP-100 measured 4.13 ms for
  /// a 4 MiB JSON single-character edit.
  public func update(
    edits: [TextEdit], oldSnapshot: TextSnapshot, newSnapshot: TextSnapshot
  ) throws -> [EditorHighlightSpan] {
    let tree = try parser.update(edits: edits, oldSnapshot: oldSnapshot, newSnapshot: newSnapshot)
    foldRanges = Self.folds(tree: tree, languageID: languageID)
    return Self.spans(tree: tree, query: query)
  }

  /// Walks every named node once (same order of cost as the highlight query pass).
  static func folds(tree: Tree, languageID: EditorLanguageID) -> [TextUTF8Range] {
    guard let root = tree.rootNode else { return [] }
    var widest: [UInt32: (start: UInt32, end: UInt32)] = [:]
    // `node.parent` walks from the root in tree-sitter, so the root is excluded by position instead.
    func visit(_ node: Node, root: Bool) {
      let rows = node.pointRange
      let foldable = node.nodeType.map { Self.isFoldable($0, languageID: languageID) } ?? false
      if !root, node.isNamed, foldable, rows.upperBound.row > rows.lowerBound.row {
        let bytes = node.byteRange
        let row = rows.lowerBound.row
        if widest[row].map({ bytes.upperBound > $0.end }) ?? true {
          widest[row] = (min(bytes.lowerBound, widest[row]?.start ?? .max), bytes.upperBound)
        }
      }
      node.enumerateChildren { visit($0, root: false) }
    }
    visit(root, root: true)
    return widest.values.sorted { $0.start < $1.start }
      .map { TextUTF8Range(UTF8Offset(Int($0.start)), UTF8Offset(Int($0.end))) }
  }

  /// Only structural containers earn a gutter marker. A multiline expression,
  /// argument list, string, or comment is not a useful fold by itself.
  private static func isFoldable(_ type: String, languageID: EditorLanguageID) -> Bool {
    switch languageID {
    case .markdown: return ["section", "fenced_code_block"].contains(type)
    case .swift:
      return ["class_declaration", "struct_declaration", "enum_declaration", "protocol_declaration",
              "extension_declaration", "function_declaration", "init_declaration", "deinit_declaration",
              "if_statement", "for_statement", "while_statement", "switch_statement", "do_statement",
              "guard_statement", "lambda_literal"].contains(type)
    case .python:
      return ["class_definition", "function_definition", "if_statement", "for_statement",
              "while_statement", "try_statement", "with_statement", "match_statement"].contains(type)
    case .ruby:
      return ["class", "module", "method", "singleton_method", "if", "unless", "case",
              "case_match", "while", "until", "for", "do_block", "begin_block", "lambda"].contains(type)
    case .go:
      return ["function_declaration", "method_declaration", "type_declaration", "if_statement",
              "for_statement", "expression_switch_statement", "type_switch_statement", "select_statement"].contains(type)
    case .javascript, .typescript:
      return ["class_declaration", "function_declaration", "generator_function_declaration",
              "method_definition", "arrow_function", "function_expression", "if_statement",
              "for_statement", "for_in_statement", "while_statement", "do_statement",
              "switch_statement", "try_statement", "interface_declaration", "enum_declaration"].contains(type)
    case .json: return ["object", "array"].contains(type)
    case .rust:
      return ["function_item", "struct_item", "enum_item", "impl_item", "trait_item", "mod_item",
              "if_expression", "for_expression", "while_expression", "loop_expression", "match_expression"].contains(type)
    case .shell:
      return ["function_definition", "if_statement", "for_statement", "while_statement",
              "case_statement", "c_style_for_statement"].contains(type)
    case .java:
      return ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration",
              "method_declaration", "constructor_declaration", "if_statement", "for_statement",
              "enhanced_for_statement", "while_statement", "do_statement", "switch_expression",
              "switch_statement", "try_statement"].contains(type)
    case .php:
      return ["class_declaration", "interface_declaration", "enum_declaration", "function_definition",
              "method_declaration", "namespace_definition", "if_statement", "for_statement",
              "foreach_statement", "while_statement", "do_statement", "switch_statement", "try_statement"].contains(type)
    case .terraform: return ["block", "object", "for_object_expr", "for_tuple_expr"].contains(type)
    }
  }

  private static func spans(tree: Tree, query: Query?) -> [EditorHighlightSpan] {
    // No compiled query (e.g. a malformed vendored `.scm` — `EditorGrammar`
    // swallows `Query.init` failures into `nil` rather than crashing a
    // parse) means no spans, not a crash: `INV-PERF-005`'s "欠けても正しさは
    // 損なわれない" (missing highlights degrade the view, never correctness).
    guard let query else { return [] }
    let cursor = query.execute(in: tree)
    var spans: [EditorHighlightSpan] = []
    while let capture = cursor.nextCapture() {
      let byteRange = capture.node.byteRange
      guard byteRange.upperBound > byteRange.lowerBound else { continue }
      let range = TextUTF8Range(
        UTF8Offset(Int(byteRange.lowerBound)), UTF8Offset(Int(byteRange.upperBound)))
      spans.append(EditorHighlightSpan(range: range, kind: CaptureMapping.kind(for: capture.nameComponents)))
    }
    return spans
  }
}

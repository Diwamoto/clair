import ClairEditorLanguageGo
import ClairEditorLanguageJava
import ClairEditorLanguageJSON
import ClairEditorLanguageJavaScript
import ClairEditorLanguageMarkdown
import ClairEditorLanguagePHP
import ClairEditorLanguagePython
import ClairEditorLanguageRuby
import ClairEditorLanguageRust
import ClairEditorLanguageShell
import ClairEditorLanguageSwift
import ClairEditorLanguageTerraform
import ClairEditorLanguageTypeScript
import Foundation
import SwiftTreeSitter

/// E11 §5.11: the languages a real Clair user opens daily. Detected from the
/// file's extension (or, for shell, its shebang) — see `detect(path:contents:)`.
public enum EditorLanguageID: String, Sendable, CaseIterable {
  case swift, go, typescript, javascript, python, json, markdown, rust, shell, ruby, java, php, terraform

  /// The grammar + query pair for this language, built once and cached
  /// (`Query` compilation is expensive — E05's `SyntaxParser` doc comment on
  /// `Language` makes the same point for parser construction).
  var grammar: EditorGrammar {
    EditorGrammar.cached(for: self)
  }

  /// Extension-first detection; shell also accepts an extensionless file
  /// whose first line is a `#!` shebang naming a shell. A file whose
  /// extension matches nothing here returns `nil` — the caller (E11 wiring
  /// in `ClairAppKit`) must leave `highlights` empty in that case, not error.
  public static func detect(path: String, shebangLine: String? = nil) -> EditorLanguageID? {
    let name = (path as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return .swift
    case "go": return .go
    // ponytail: `.tsx` is parsed with the plain `typescript` grammar, not
    // the separate `tsx` dialect grammar (JSX syntax inside a `.tsx` file
    // will misparse past the JSX boundary). A fuller version vendors
    // `tree-sitter-typescript`'s sibling `tsx/` grammar and dispatches on
    // it instead — see `ClairEditorLanguageTypeScript/VENDOR.md`.
    case "ts", "tsx": return .typescript
    case "js", "jsx", "mjs", "cjs": return .javascript
    case "py": return .python
    case "json": return .json
    // ponytail: block grammar only, no injected inline grammar — see
    // `ClairEditorLanguageMarkdown/VENDOR.md`.
    case "md", "markdown": return .markdown
    case "rs": return .rust
    case "sh", "bash", "zsh": return .shell
    case "rb", "rake", "gemspec": return .ruby
    case "java": return .java
    case "php": return .php
    case "tf", "tfvars", "hcl": return .terraform
    case "":
      // No extension: only shell identifies itself this way, via shebang.
      if let shebangLine, shebangLine.hasPrefix("#!"), shebangLine.contains("sh") {
        return .shell
      }
      return nil
    default: return nil
    }
  }
}

/// A compiled `Language` + `Query` pair, cached per `EditorLanguageID` for
/// the process lifetime (both are expensive to build and immutable once
/// built, so building them once per language is a straightforward win, not
/// a "cache invalidation" concern — there is nothing to invalidate).
public struct EditorGrammar: Sendable {
  public let language: Language
  public let query: Query?

  private init(language: Language, queryText: String) {
    self.language = language
    self.query = try? Query(language: language, data: Data(queryText.utf8))
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var cache: [EditorLanguageID: EditorGrammar] = [:]

  static func cached(for id: EditorLanguageID) -> EditorGrammar {
    lock.lock()
    defer { lock.unlock() }
    if let existing = cache[id] { return existing }
    let built = build(id)
    cache[id] = built
    return built
  }

  private static func build(_ id: EditorLanguageID) -> EditorGrammar {
    switch id {
    case .swift:
      return EditorGrammar(language: Language(tree_sitter_swift()), queryText: HighlightQueries.swift)
    case .go:
      return EditorGrammar(language: Language(tree_sitter_go()), queryText: HighlightQueries.go)
    case .typescript:
      return EditorGrammar(
        language: Language(tree_sitter_typescript()), queryText: HighlightQueries.typescript)
    case .javascript:
      return EditorGrammar(
        language: Language(tree_sitter_javascript()), queryText: HighlightQueries.javascript)
    case .python:
      return EditorGrammar(language: Language(tree_sitter_python()), queryText: HighlightQueries.python)
    case .json:
      return EditorGrammar(
        language: Language(clair_editor_tree_sitter_json()), queryText: HighlightQueries.json)
    case .markdown:
      return EditorGrammar(
        language: Language(tree_sitter_markdown()), queryText: HighlightQueries.markdown)
    case .rust:
      return EditorGrammar(language: Language(tree_sitter_rust()), queryText: HighlightQueries.rust)
    case .shell:
      return EditorGrammar(language: Language(tree_sitter_bash()), queryText: HighlightQueries.shell)
    case .ruby:
      return EditorGrammar(language: Language(tree_sitter_ruby()), queryText: HighlightQueries.ruby)
    case .java:
      return EditorGrammar(language: Language(tree_sitter_java()), queryText: HighlightQueries.java)
    case .php:
      return EditorGrammar(language: Language(tree_sitter_php()), queryText: HighlightQueries.php)
    case .terraform:
      return EditorGrammar(
        language: Language(tree_sitter_terraform()), queryText: HighlightQueries.terraform)
    }
  }
}

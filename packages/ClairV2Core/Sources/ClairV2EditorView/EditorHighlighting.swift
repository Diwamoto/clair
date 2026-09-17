import ClairV2EditorCore

#if os(macOS)
  import AppKit

  /// A coarse syntax token category. Mapping a specific language's
  /// tree-sitter captures (`@keyword`, `@string`, ...) onto these is a later
  /// per-language wiring task's job, not this rendering primitive's; E06
  /// only needs to prove the viewport can paint spans it is handed.
  public enum EditorTokenKind: Sendable, Hashable {
    case keyword, string, comment, number, type, function, variable, plain

    /// A default, theme-agnostic color. `ClairEditorView.tokenColors` lets a
    /// caller override any subset; full design-system theming is a `U05`
    /// concern.
    public var defaultColor: NSColor {
      switch self {
      case .keyword: return .systemPink
      case .string: return .systemRed
      case .comment: return .systemGray
      case .number: return .systemBlue
      case .type: return .systemTeal
      case .function: return .systemPurple
      case .variable, .plain: return .labelColor
      }
    }
  }

  /// One syntax-colored run, in absolute document UTF-8 coordinates.
  public struct EditorHighlightSpan: Sendable {
    public let range: TextUTF8Range
    public let kind: EditorTokenKind

    public init(range: TextUTF8Range, kind: EditorTokenKind) {
      self.range = range
      self.kind = kind
    }
  }

  public enum EditorDiagnosticSeverity: Sendable, Hashable {
    case error, warning, information, hint

    public var color: NSColor {
      switch self {
      case .error: return .systemRed
      case .warning: return .systemYellow
      case .information: return .systemBlue
      case .hint: return .systemGray
      }
    }
  }

  /// One diagnostic underline, in absolute document UTF-8 coordinates.
  /// Deliberately not the LSP wire `Diagnostic` type: the view layer stays
  /// provider-agnostic the same way `ClairAgent` keeps provider adapters out
  /// of its core model. Convert with `ClairV2EditorLanguage.LSPCoordinates`
  /// at the call site that owns an `LSPDocumentSession`.
  public struct EditorDiagnosticSpan: Sendable {
    public let range: TextUTF8Range
    public let severity: EditorDiagnosticSeverity

    public init(range: TextUTF8Range, severity: EditorDiagnosticSeverity) {
      self.range = range
      self.severity = severity
    }
  }
#endif

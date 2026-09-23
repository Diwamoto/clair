import ClairEditorCore
import CoreGraphics

// Cross-platform (E06 macOS + E08 iOS): these span/kind types carry no
// AppKit/UIKit behavior beyond `PlatformColor` (`PlatformTypes.swift`), so
// both `ClairEditorView` implementations share one definition instead of a
// forked copy per platform.

/// A coarse syntax token category. Mapping a specific language's
/// tree-sitter captures (`@keyword`, `@string`, ...) onto these is a later
/// per-language wiring task's job, not this rendering primitive's; E06
/// only needs to prove the viewport can paint spans it is handed.
public enum EditorTokenKind: Sendable, Hashable {
  case keyword, string, comment, number, type, function, variable, plain

  /// Atom One Dark, matching `ClairColor.Surface.code*` in the design
  /// system. `ClairEditorView.tokenColors` lets a caller override any subset.
  public var defaultColor: PlatformColor {
    switch self {
    case .keyword: return .oneDark(0xc678dd)
    case .string: return .oneDark(0x98c379)
    case .comment: return .oneDark(0x5c6370)
    case .number: return .oneDark(0xd19a66)
    case .type: return .oneDark(0xe5c07b)
    case .function: return .oneDark(0x61afef)
    case .variable, .plain: return .editorLabel
    }
  }
}

extension PlatformColor {
  fileprivate static func oneDark(_ rgb: Int) -> PlatformColor {
    PlatformColor(
      red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
      blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
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

  public var color: PlatformColor {
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
/// of its core model. Convert with `ClairEditorLanguage.LSPCoordinates`
/// at the call site that owns an `LSPDocumentSession`.
public struct EditorDiagnosticSpan: Sendable {
  public let range: TextUTF8Range
  public let severity: EditorDiagnosticSeverity
  /// Shown as the hover tooltip over the underline (macOS).
  public let message: String

  public init(range: TextUTF8Range, severity: EditorDiagnosticSeverity, message: String = "") {
    self.range = range
    self.severity = severity
    self.message = message
  }

  /// `INV-REV-004`: carries a span from the pre-edit revision onto the
  /// post-edit one instead of leaving it on stale offsets until the server
  /// republishes. `edits` must be sorted and non-overlapping (what
  /// `EditorTransactionManager.apply` already guarantees).
  public func mapped(through edits: [TextEdit]) -> EditorDiagnosticSpan {
    let lower = TextEdit.map(range.lowerBound.value, through: edits)
    let upper = max(lower, TextEdit.map(range.upperBound.value, through: edits))
    return EditorDiagnosticSpan(
      range: TextUTF8Range(UTF8Offset(lower), UTF8Offset(upper)), severity: severity, message: message)
  }
}

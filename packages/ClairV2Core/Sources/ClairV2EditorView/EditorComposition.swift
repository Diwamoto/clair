import ClairV2EditorCore
import Foundation

/// One in-flight IME composition session (E07).
///
/// A composition is a pure view-local rendering overlay: the buffer and undo
/// stack are never touched while it is live (`INV-UNDO-003` — "IME
/// composition is not undoable while marked. Only the committed result
/// enters the undo stack, as one unit."). `replacedRange` is the buffer
/// range this composition is standing in for — a zero-length insertion
/// point for ordinary typing, or a real range when the input method is
/// reconverting already-committed text.
public struct EditorComposition: Equatable {
  public let replacedRange: TextUTF8Range
  public let text: String
  /// The input method's own cursor within `text`. Reported back through
  /// `NSTextInputClient.selectedRange()` but never drawn as a second caret
  /// (`INV-INPUT-009`): the OS candidate window is the only composition
  /// cursor the user sees.
  public let selectedRangeInText: NSRange

  public init(replacedRange: TextUTF8Range, text: String, selectedRangeInText: NSRange) {
    self.replacedRange = replacedRange
    self.text = text
    self.selectedRangeInText = selectedRangeInText
  }
}

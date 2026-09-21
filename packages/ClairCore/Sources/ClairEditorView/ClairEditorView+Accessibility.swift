import ClairEditorCore

#if os(macOS)
  import AppKit

  /// VoiceOver support (E07).
  ///
  /// **Scope decision (`INV-INPUT-008`)**: unlike `draw`/`applyEdits`,
  /// these methods are queried rarely (a VoiceOver focus event, not every
  /// keystroke), so materializing the whole document as a `String` or
  /// converting a document-wide UTF-16 offset here is acceptable in a way
  /// it is not on the hot path `INV-PERF-001` binds. Selection/visible
  /// range are reported in ordinary document-wide UTF-16 terms, not the
  /// line-local space `NSTextInputClient` uses (`INV-INPUT-001` is a
  /// hot-path decision specific to that protocol, not a general rule).
  extension ClairEditorView {
    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    public override func accessibilityValue() -> Any? { snapshot.string() }

    public override func accessibilityNumberOfCharacters() -> Int { snapshot.utf16Count }

    public override func accessibilitySelectedText() -> String? {
      guard let primary = selection.selections.first, !primary.isEmpty else { return nil }
      return try? snapshot.text(in: primary.range)
    }

    public override func accessibilitySelectedTextRange() -> NSRange {
      guard let primary = selection.selections.first,
        let start = try? snapshot.convert(primary.range.lowerBound, to: UTF16Unit.self).value,
        let end = try? snapshot.convert(primary.range.upperBound, to: UTF16Unit.self).value
      else { return NSRange(location: 0, length: 0) }
      return NSRange(location: start, length: end - start)
    }

    public override func setAccessibilitySelectedTextRange(_ range: NSRange) {
      guard
        let start = try? snapshot.convert(
          UTF16Offset(range.location), to: UTF8Unit.self, rounding: .down),
        let end = try? snapshot.convert(
          UTF16Offset(range.location + range.length), to: UTF8Unit.self, rounding: .up),
        let updated = try? TextSelectionSet([TextSelection(anchor: start, head: end)])
      else { return }
      selection = updated
      needsDisplay = true
      onSelectionChange?(selection)
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
      // `visibleRect` is `NSView`'s own notion of "the portion actually on
      // screen" and, per its documented behavior, is an enormous sentinel
      // rect (not `bounds`) for a view with no window — intersect with
      // `bounds` so that degenerate case still yields a real, in-range
      // rect instead of feeding a huge/NaN-adjacent value into line math.
      let visible = EditorViewGeometry.visibleLineRange(
        visibleRect: bounds.intersection(visibleRect), lineHeight: lineHeight,
        lineCount: snapshot.lineCount)
      guard !visible.isEmpty,
        let firstLine = try? snapshot.line(at: TextLineIndex(visible.lowerBound)),
        let lastLine = try? snapshot.line(at: TextLineIndex(visible.upperBound - 1)),
        let start = try? snapshot.convert(firstLine.contentRange.lowerBound, to: UTF16Unit.self)
          .value,
        let end = try? snapshot.convert(lastLine.contentRange.upperBound, to: UTF16Unit.self).value
      else { return NSRange(location: 0, length: 0) }
      return NSRange(location: start, length: end - start)
    }

    public override func accessibilityString(for range: NSRange) -> String? {
      guard
        let start = try? snapshot.convert(
          UTF16Offset(range.location), to: UTF8Unit.self, rounding: .down),
        let end = try? snapshot.convert(
          UTF16Offset(range.location + range.length), to: UTF8Unit.self, rounding: .up)
      else { return nil }
      return try? snapshot.text(in: TextUTF8Range(start, end))
    }
  }
#endif

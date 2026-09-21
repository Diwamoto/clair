#if os(macOS)
  import AppKit

  /// Cross-platform aliases so rendering primitives shared by both
  /// `ClairEditorView` implementations (`EditorHighlighting.swift`,
  /// `EditorLineRenderer.swift`) compile once instead of forking per
  /// platform. E08 (iOS) reuses E06/E07's CoreText line cache and syntax/
  /// diagnostic span types as-is rather than duplicating them; this file is
  /// the only place that names `NSColor`/`UIColor`/`NSFont`/`UIFont`
  /// directly.
  public typealias PlatformColor = NSColor
  public typealias PlatformFont = NSFont
#elseif os(iOS)
  import UIKit

  public typealias PlatformColor = UIColor
  public typealias PlatformFont = UIFont
#endif

extension PlatformColor {
  /// AppKit spells the primary label color `.labelColor`; UIKit spells it
  /// `.label`. One name so shared rendering code doesn't need a second
  /// `#if os(...)` branch just for this.
  static var editorLabel: PlatformColor {
    #if os(macOS)
      return .labelColor
    #else
      return .label
    #endif
  }
}

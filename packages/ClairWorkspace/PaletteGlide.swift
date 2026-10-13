import Foundation

/// The palette's filter motion, ported from arc-library (MIT,
/// github.com/kuratlielia/arc-library): `GLIDE_ROWS` in
/// registry/components/command-palette. When every surviving row moves within
/// about a viewport, the list closes its gaps with a glide; a long jump — the
/// first letters typed into a long list — snaps like a search-result list
/// instead of streaking rows through the frame.
public enum PaletteGlide {
  /// Rows landing within this many positions of their old place glide;
  /// anything farther snaps.
  public static let glideRows = 6

  /// Whether the rows of `current` all sit within `glideRows` of their
  /// position in `previous`. Rows only in `current` just appear and never
  /// block the glide — but with no shared rows nothing can glide, so snap.
  /// Keys must identify a row across a filter change; use `paletteKey`.
  public static func shouldGlide(previous: [String], current: [String]) -> Bool {
    let before = Dictionary(previous.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
    var shared = 0
    for (i, key) in current.enumerated() {
      guard let from = before[key] else { continue }
      shared += 1
      if abs(from - i) > glideRows { return false }
    }
    return shared > 0
  }
}

extension PaletteItem {
  /// Identity across a palette filter change: `id` repeats across rows (every
  /// branch row is `git.switch`), so pair it with the title.
  public var paletteKey: String { id + "\u{1f}" + title }
}

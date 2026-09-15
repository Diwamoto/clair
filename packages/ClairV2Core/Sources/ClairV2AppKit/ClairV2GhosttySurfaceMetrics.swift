import ClairV2Terminal
import Foundation

#if os(macOS)
  import AppKit

  /// Font/DPI cell geometry for the macOS Ghostty surface (T03). This is pure
  /// arithmetic over an `NSFont` and a backing scale factor — it never
  /// interprets terminal output, so it stays valid whether or not the
  /// vendored `GhosttyKit` renderer is present: the same cell grid math this
  /// task's window-resize path uses today is exactly what a real Ghostty
  /// surface will be handed once `T01`'s vendor step lands.
  public struct ClairV2GhosttyCellMetrics: Equatable, Sendable {
    public let cellWidth: Double
    public let cellHeight: Double
    public let contentScale: Double

    public init(cellWidth: Double, cellHeight: Double, contentScale: Double) {
      self.cellWidth = cellWidth
      self.cellHeight = cellHeight
      self.contentScale = contentScale
    }

    /// Derives cell geometry from a monospaced font at `contentScale` (a
    /// window's `backingScaleFactor`, e.g. `2.0` on a Retina display). Uses
    /// the font's advancement for `0` (typical monospace glyphs share one
    /// advance width) and its line height for the cell height, matching how
    /// every fixed-grid terminal renderer sizes a cell.
    public static func measuring(font: NSFont, contentScale: Double) -> ClairV2GhosttyCellMetrics {
      let glyph = font.advancement(forGlyph: font.glyph(withName: "zero"))
      let width = glyph.width > 0 ? Double(glyph.width) : Double(font.maximumAdvancement.width)
      let height = Double(font.ascender - font.descender + font.leading)
      return ClairV2GhosttyCellMetrics(
        cellWidth: max(width, 1), cellHeight: max(height, 1), contentScale: contentScale)
    }
  }

  public enum ClairV2GhosttySurfaceGeometry {
    /// Converts a view's point-space bounds into a terminal size, clamped to
    /// `ClairV2TerminalSize`'s validated `1...4096` range so a tiny or huge
    /// window can never request an invalid PTY geometry.
    public static func terminalSize(
      forViewSize viewSize: CGSize, metrics: ClairV2GhosttyCellMetrics
    ) throws -> ClairV2TerminalSize {
      let columns = max(1, Int(viewSize.width / metrics.cellWidth))
      let rows = max(1, Int(viewSize.height / metrics.cellHeight))
      return try ClairV2TerminalSize(
        rows: UInt16(min(rows, 4096)), columns: UInt16(min(columns, 4096)))
    }
  }
#endif

import Foundation
import Testing

@testable import ClairV2AppKit
@testable import ClairV2Terminal

#if os(macOS)
  import AppKit

  @Suite
  struct ClairV2GhosttySurfaceMetricsTests {
    @Test func t03CellMetricsScaleWithContentScale() {
      let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
      let scale1 = ClairV2GhosttyCellMetrics.measuring(font: font, contentScale: 1)
      let scale2 = ClairV2GhosttyCellMetrics.measuring(font: font, contentScale: 2)
      #expect(scale1.cellWidth > 0 && scale1.cellHeight > 0)
      #expect(scale1.cellWidth == scale2.cellWidth)
      #expect(scale2.contentScale == 2)
    }

    @Test func t03ViewSizeConvertsToAClampedTerminalSize() throws {
      let metrics = ClairV2GhosttyCellMetrics(cellWidth: 8, cellHeight: 16, contentScale: 1)
      let size = try ClairV2GhosttySurfaceGeometry.terminalSize(
        forViewSize: CGSize(width: 800, height: 400), metrics: metrics)
      #expect(size.columns == 100)
      #expect(size.rows == 25)
    }

    @Test func t03ViewSizeNeverProducesAnInvalidTerminalSize() throws {
      let metrics = ClairV2GhosttyCellMetrics(cellWidth: 8, cellHeight: 16, contentScale: 1)
      let tiny = try ClairV2GhosttySurfaceGeometry.terminalSize(
        forViewSize: CGSize(width: 0, height: 0), metrics: metrics)
      #expect(tiny.rows >= 1 && tiny.columns >= 1)
      let huge = try ClairV2GhosttySurfaceGeometry.terminalSize(
        forViewSize: CGSize(width: 1_000_000, height: 1_000_000), metrics: metrics)
      #expect(huge.rows <= 4096 && huge.columns <= 4096)
    }
  }
#endif

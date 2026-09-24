import Foundation
import Testing

@testable import ClairAppKit
@testable import ClairTerminal

#if os(macOS)
  import AppKit

  @Suite
  struct ClairGhosttySurfaceMetricsTests {
    @Test func shiftTabSendsNoControlTextSoGhosttyEncodesBacktab() throws {
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
          context: nil, characters: "\u{19}", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
      let key = ClairGhosttySurfaceView.ghosttyKeyEvent(event, action: .press)
      #expect(key.text == nil)
      #expect(key.mods.contains(.shift))
      #expect(ClairGhosttySurfaceView.keyEventText("a") == "a")
    }

    @Test func t03CellMetricsScaleWithContentScale() {
      let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
      let scale1 = ClairGhosttyCellMetrics.measuring(font: font, contentScale: 1)
      let scale2 = ClairGhosttyCellMetrics.measuring(font: font, contentScale: 2)
      #expect(scale1.cellWidth > 0 && scale1.cellHeight > 0)
      #expect(scale1.cellWidth == scale2.cellWidth)
      #expect(scale2.contentScale == 2)
    }

    @Test func t03ViewSizeConvertsToAClampedTerminalSize() throws {
      let metrics = ClairGhosttyCellMetrics(cellWidth: 8, cellHeight: 16, contentScale: 1)
      let size = try ClairGhosttySurfaceGeometry.terminalSize(
        forViewSize: CGSize(width: 800, height: 400), metrics: metrics)
      #expect(size.columns == 100)
      #expect(size.rows == 25)
    }

    @Test func t03ViewSizeNeverProducesAnInvalidTerminalSize() throws {
      let metrics = ClairGhosttyCellMetrics(cellWidth: 8, cellHeight: 16, contentScale: 1)
      let tiny = try ClairGhosttySurfaceGeometry.terminalSize(
        forViewSize: CGSize(width: 0, height: 0), metrics: metrics)
      #expect(tiny.rows >= 1 && tiny.columns >= 1)
      let huge = try ClairGhosttySurfaceGeometry.terminalSize(
        forViewSize: CGSize(width: 1_000_000, height: 1_000_000), metrics: metrics)
      #expect(huge.rows <= 4096 && huge.columns <= 4096)
    }
  }
#endif

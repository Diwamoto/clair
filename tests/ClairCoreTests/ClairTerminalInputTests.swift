import Foundation
import Testing

@testable import ClairTerminal

@Suite
struct ClairTerminalInputTests {
  private func modes(_ s: String) -> ClairTerminalModes {
    var m = ClairTerminalModes()
    m.feed(Data(s.utf8))
    return m
  }

  @Test func modeScannerTracksSetAndReset() {
    var m = modes("\u{1B}[?2004h\u{1B}[?1004;1002;1006h")
    #expect(m.bracketedPaste && m.focusReporting && m.mouseSGR && m.mouseTracking == 1002)
    m.feed(Data("\u{1B}[?2004l\u{1B}[?1002l".utf8))
    #expect(!m.bracketedPaste && m.mouseTracking == nil && m.mouseSGR)
  }

  @Test func modeScannerSurvivesSplitFramesAndIgnoresOtherCSI() {
    var m = ClairTerminalModes()
    for chunk in ["hi\u{1B}", "[?20", "04", "h", "\u{1B}[31mred\u{1B}[?25l"] { m.feed(Data(chunk.utf8)) }
    #expect(m.bracketedPaste)
    #expect(m.mouseTracking == nil && !m.focusReporting)
  }

  @Test func pasteIsBracketedStrippedAndConfirmedWhenMultilineUnbracketed() {
    let on = modes("\u{1B}[?2004h")
    let evil = "a\u{1B}[201~rm -rf\nb"
    #expect(ClairTerminalPaste.encode(evil, modes: on)
      == ClairTerminalPaste.bracketStart + Data("a[201~rm -rf\rb".utf8) + ClairTerminalPaste.bracketEnd)
    let off = ClairTerminalModes()
    #expect(ClairTerminalPaste.encode("日本\r\n語", modes: off) == Data("日本\r語".utf8))
    #expect(ClairTerminalPaste.needsConfirmation("a\nb", modes: off))
    #expect(!ClairTerminalPaste.needsConfirmation("a\nb", modes: on))
    #expect(!ClairTerminalPaste.needsConfirmation("ab", modes: off))
  }

  @Test func focusOnlyWhenRequested() {
    #expect(ClairTerminalFocus.encode(focused: true, modes: ClairTerminalModes()).isEmpty)
    let m = modes("\u{1B}[?1004h")
    #expect(ClairTerminalFocus.encode(focused: true, modes: m) == Data([0x1B, 0x5B, 0x49]))
    #expect(ClairTerminalFocus.encode(focused: false, modes: m) == Data([0x1B, 0x5B, 0x4F]))
  }

  @Test func mouseSGRAndLegacyEncoding() {
    let sgr = modes("\u{1B}[?1002h\u{1B}[?1006h")
    #expect(ClairTerminalMouse.encode(.left, .press, column: 4, row: 2, modes: sgr) == Data("\u{1B}[<0;5;3M".utf8))
    #expect(ClairTerminalMouse.encode(.left, .release, column: 4, row: 2, modes: sgr) == Data("\u{1B}[<0;5;3m".utf8))
    #expect(ClairTerminalMouse.encode(.left, .drag, column: 0, row: 0, modes: sgr) == Data("\u{1B}[<32;1;1M".utf8))
    #expect(ClairTerminalMouse.encode(.wheelUp, .press, column: 0, row: 0, modes: sgr) == Data("\u{1B}[<64;1;1M".utf8))
    let legacy = modes("\u{1B}[?1000h")
    #expect(ClairTerminalMouse.encode(.left, .press, column: 0, row: 0, modes: legacy) == Data([0x1B, 0x5B, 0x4D, 32, 33, 33]))
    #expect(ClairTerminalMouse.encode(.left, .drag, column: 0, row: 0, modes: legacy).isEmpty)
    #expect(ClairTerminalMouse.encode(.left, .press, column: 300, row: 0, modes: legacy).isEmpty)
    #expect(ClairTerminalMouse.encode(.left, .press, column: 0, row: 0, modes: ClairTerminalModes()).isEmpty)
  }

  @Test func cellWidthCoversCJKAndCombining() {
    #expect(ClairTerminalCellWidth.of("a") == 1)
    #expect(ClairTerminalCellWidth.of("日") == 2)
    #expect(ClairTerminalCellWidth.of("ア") == 2)
    #expect(ClairTerminalCellWidth.of("\u{0301}") == 0)
  }
}

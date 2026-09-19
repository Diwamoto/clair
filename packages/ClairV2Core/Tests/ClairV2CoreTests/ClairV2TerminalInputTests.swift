import Foundation
import Testing

@testable import ClairV2Terminal

@Suite
struct ClairV2TerminalInputTests {
  private func modes(_ s: String) -> ClairV2TerminalModes {
    var m = ClairV2TerminalModes()
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
    var m = ClairV2TerminalModes()
    for chunk in ["hi\u{1B}", "[?20", "04", "h", "\u{1B}[31mred\u{1B}[?25l"] { m.feed(Data(chunk.utf8)) }
    #expect(m.bracketedPaste)
    #expect(m.mouseTracking == nil && !m.focusReporting)
  }

  @Test func pasteIsBracketedStrippedAndConfirmedWhenMultilineUnbracketed() {
    let on = modes("\u{1B}[?2004h")
    let evil = "a\u{1B}[201~rm -rf\nb"
    #expect(ClairV2TerminalPaste.encode(evil, modes: on)
      == ClairV2TerminalPaste.bracketStart + Data("a[201~rm -rf\rb".utf8) + ClairV2TerminalPaste.bracketEnd)
    let off = ClairV2TerminalModes()
    #expect(ClairV2TerminalPaste.encode("日本\r\n語", modes: off) == Data("日本\r語".utf8))
    #expect(ClairV2TerminalPaste.needsConfirmation("a\nb", modes: off))
    #expect(!ClairV2TerminalPaste.needsConfirmation("a\nb", modes: on))
    #expect(!ClairV2TerminalPaste.needsConfirmation("ab", modes: off))
  }

  @Test func focusOnlyWhenRequested() {
    #expect(ClairV2TerminalFocus.encode(focused: true, modes: ClairV2TerminalModes()).isEmpty)
    let m = modes("\u{1B}[?1004h")
    #expect(ClairV2TerminalFocus.encode(focused: true, modes: m) == Data([0x1B, 0x5B, 0x49]))
    #expect(ClairV2TerminalFocus.encode(focused: false, modes: m) == Data([0x1B, 0x5B, 0x4F]))
  }

  @Test func mouseSGRAndLegacyEncoding() {
    let sgr = modes("\u{1B}[?1002h\u{1B}[?1006h")
    #expect(ClairV2TerminalMouse.encode(.left, .press, column: 4, row: 2, modes: sgr) == Data("\u{1B}[<0;5;3M".utf8))
    #expect(ClairV2TerminalMouse.encode(.left, .release, column: 4, row: 2, modes: sgr) == Data("\u{1B}[<0;5;3m".utf8))
    #expect(ClairV2TerminalMouse.encode(.left, .drag, column: 0, row: 0, modes: sgr) == Data("\u{1B}[<32;1;1M".utf8))
    #expect(ClairV2TerminalMouse.encode(.wheelUp, .press, column: 0, row: 0, modes: sgr) == Data("\u{1B}[<64;1;1M".utf8))
    let legacy = modes("\u{1B}[?1000h")
    #expect(ClairV2TerminalMouse.encode(.left, .press, column: 0, row: 0, modes: legacy) == Data([0x1B, 0x5B, 0x4D, 32, 33, 33]))
    #expect(ClairV2TerminalMouse.encode(.left, .drag, column: 0, row: 0, modes: legacy).isEmpty)
    #expect(ClairV2TerminalMouse.encode(.left, .press, column: 300, row: 0, modes: legacy).isEmpty)
    #expect(ClairV2TerminalMouse.encode(.left, .press, column: 0, row: 0, modes: ClairV2TerminalModes()).isEmpty)
  }

  @Test func cellWidthCoversCJKAndCombining() {
    #expect(ClairV2TerminalCellWidth.of("a") == 1)
    #expect(ClairV2TerminalCellWidth.of("日") == 2)
    #expect(ClairV2TerminalCellWidth.of("ア") == 2)
    #expect(ClairV2TerminalCellWidth.of("\u{0301}") == 0)
  }
}

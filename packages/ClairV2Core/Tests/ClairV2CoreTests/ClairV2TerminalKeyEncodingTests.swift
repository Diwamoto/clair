import Foundation
import Testing

@testable import ClairV2Terminal

@Suite
struct ClairV2TerminalKeyEncodingTests {
  @Test func plainTextPassesThroughAsUTF8() {
    #expect(ClairV2TerminalKeyEncoding.encode(.text("ls -la")) == Data("ls -la".utf8))
    #expect(ClairV2TerminalKeyEncoding.encode(.text("日本語")) == Data("日本語".utf8))
  }

  @Test func namedKeysEncodeToTheirStandardBytes() {
    #expect(ClairV2TerminalKeyEncoding.encode(.return) == Data([0x0D]))
    #expect(ClairV2TerminalKeyEncoding.encode(.tab) == Data([0x09]))
    #expect(ClairV2TerminalKeyEncoding.encode(.backspace) == Data([0x7F]))
    #expect(ClairV2TerminalKeyEncoding.encode(.escape) == Data([0x1B]))
    #expect(ClairV2TerminalKeyEncoding.encode(.delete) == Data([0x1B, 0x5B, 0x33, 0x7E]))
  }

  @Test func arrowKeysEncodeToCSIDirectionBytes() {
    #expect(ClairV2TerminalKeyEncoding.encode(.up) == Data([0x1B, 0x5B, 0x41]))
    #expect(ClairV2TerminalKeyEncoding.encode(.down) == Data([0x1B, 0x5B, 0x42]))
    #expect(ClairV2TerminalKeyEncoding.encode(.right) == Data([0x1B, 0x5B, 0x43]))
    #expect(ClairV2TerminalKeyEncoding.encode(.left) == Data([0x1B, 0x5B, 0x44]))
  }

  @Test func navigationKeysEncodeToCSISequences() {
    #expect(ClairV2TerminalKeyEncoding.encode(.home) == Data([0x1B, 0x5B, 0x48]))
    #expect(ClairV2TerminalKeyEncoding.encode(.end) == Data([0x1B, 0x5B, 0x46]))
    #expect(ClairV2TerminalKeyEncoding.encode(.pageUp) == Data([0x1B, 0x5B, 0x35, 0x7E]))
    #expect(ClairV2TerminalKeyEncoding.encode(.pageDown) == Data([0x1B, 0x5B, 0x36, 0x7E]))
  }

  @Test func controlChordsMapLetterToC0ControlByte() {
    #expect(ClairV2TerminalKeyEncoding.encode(.control("c")) == Data([0x03]))
    #expect(ClairV2TerminalKeyEncoding.encode(.control("C")) == Data([0x03]))
    #expect(ClairV2TerminalKeyEncoding.encode(.control("a")) == Data([0x01]))
    #expect(ClairV2TerminalKeyEncoding.encode(.control("z")) == Data([0x1A]))
    #expect(ClairV2TerminalKeyEncoding.encode(.control("d")) == Data([0x04]))
  }

  @Test func controlChordOutsideLettersEncodesToNothing() {
    #expect(ClairV2TerminalKeyEncoding.encode(.control("1")) == Data())
    #expect(ClairV2TerminalKeyEncoding.encode(.control("@")) == Data())
    #expect(ClairV2TerminalKeyEncoding.encode(.control(" ")) == Data())
  }
}

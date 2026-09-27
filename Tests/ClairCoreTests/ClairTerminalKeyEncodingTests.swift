import Foundation
import Testing

@testable import ClairTerminal

@Suite
struct ClairTerminalKeyEncodingTests {
  @Test func plainTextPassesThroughAsUTF8() {
    #expect(ClairTerminalKeyEncoding.encode(.text("ls -la")) == Data("ls -la".utf8))
    #expect(ClairTerminalKeyEncoding.encode(.text("日本語")) == Data("日本語".utf8))
  }

  @Test func namedKeysEncodeToTheirStandardBytes() {
    #expect(ClairTerminalKeyEncoding.encode(.return) == Data([0x0D]))
    #expect(ClairTerminalKeyEncoding.encode(.tab) == Data([0x09]))
    #expect(ClairTerminalKeyEncoding.encode(.backspace) == Data([0x7F]))
    #expect(ClairTerminalKeyEncoding.encode(.escape) == Data([0x1B]))
    #expect(ClairTerminalKeyEncoding.encode(.delete) == Data([0x1B, 0x5B, 0x33, 0x7E]))
  }

  @Test func arrowKeysEncodeToCSIDirectionBytes() {
    #expect(ClairTerminalKeyEncoding.encode(.up) == Data([0x1B, 0x5B, 0x41]))
    #expect(ClairTerminalKeyEncoding.encode(.down) == Data([0x1B, 0x5B, 0x42]))
    #expect(ClairTerminalKeyEncoding.encode(.right) == Data([0x1B, 0x5B, 0x43]))
    #expect(ClairTerminalKeyEncoding.encode(.left) == Data([0x1B, 0x5B, 0x44]))
  }

  @Test func navigationKeysEncodeToCSISequences() {
    #expect(ClairTerminalKeyEncoding.encode(.home) == Data([0x1B, 0x5B, 0x48]))
    #expect(ClairTerminalKeyEncoding.encode(.end) == Data([0x1B, 0x5B, 0x46]))
    #expect(ClairTerminalKeyEncoding.encode(.pageUp) == Data([0x1B, 0x5B, 0x35, 0x7E]))
    #expect(ClairTerminalKeyEncoding.encode(.pageDown) == Data([0x1B, 0x5B, 0x36, 0x7E]))
  }

  @Test func controlChordsMapLetterToC0ControlByte() {
    #expect(ClairTerminalKeyEncoding.encode(.control("c")) == Data([0x03]))
    #expect(ClairTerminalKeyEncoding.encode(.control("C")) == Data([0x03]))
    #expect(ClairTerminalKeyEncoding.encode(.control("a")) == Data([0x01]))
    #expect(ClairTerminalKeyEncoding.encode(.control("z")) == Data([0x1A]))
    #expect(ClairTerminalKeyEncoding.encode(.control("d")) == Data([0x04]))
  }

  @Test func controlChordOutsideLettersEncodesToNothing() {
    #expect(ClairTerminalKeyEncoding.encode(.control("1")) == Data())
    #expect(ClairTerminalKeyEncoding.encode(.control("@")) == Data())
    #expect(ClairTerminalKeyEncoding.encode(.control(" ")) == Data())
  }
}

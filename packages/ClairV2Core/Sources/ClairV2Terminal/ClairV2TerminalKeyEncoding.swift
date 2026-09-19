import Foundation

/// A single hardware-keyboard key event, already decoded from whatever
/// platform key-event type produced it (iOS: `UIKeyCommand`/`UIKeyInput`).
/// Deliberately not `UIKeyCommand` itself: this type is platform-neutral so
/// the encoding table below is plain, host-testable Swift with no UIKit
/// dependency, following T04/T01's existing split between transport-neutral
/// core logic and platform glue.
public enum ClairV2TerminalKey: Equatable, Sendable {
  case text(String)
  case `return`
  case tab
  case backspace
  case escape
  case up, down, left, right
  case home, end
  case pageUp, pageDown
  case delete
  /// A control-chord letter, e.g. `.control("c")` for Ctrl-C. `letter` must
  /// be a single ASCII letter; anything else encodes to nothing (see
  /// `ClairV2TerminalKeyEncoding.encode`).
  case control(Character)
}

/// Encodes a hardware-keyboard key event into the raw bytes a terminal
/// expects on its input stream (the same direction T04's
/// `ClairV2TerminalProcess.enqueueTerminalInput` accepts). This is a
/// minimal, standard VT100/xterm encoding -- plain characters pass through
/// as UTF-8, arrows become `ESC [ A/B/C/D`, and Ctrl-<letter> becomes the
/// corresponding C0 control byte. It intentionally does not implement
/// libghostty-vt's Kitty-keyboard-protocol key encoder (`ghostty/vt/key.h`)
/// or mouse SGR encoding (`ghostty/vt/mouse.h`): those handle modifier
/// disambiguation and application-mode variants a future task (T06: IME/
/// CJK, paste guard, mouse reporting integration) is scoped to add: this
/// table is deliberately the smallest thing that makes basic hardware-
/// keyboard typing and navigation work today, additive with room for T06
/// to extend rather than replace it.
public enum ClairV2TerminalKeyEncoding {
  public static func encode(_ key: ClairV2TerminalKey) -> Data {
    switch key {
    case .text(let string):
      return Data(string.utf8)
    case .return:
      return Data([0x0D])
    case .tab:
      return Data([0x09])
    case .backspace:
      return Data([0x7F])
    case .escape:
      return Data([0x1B])
    case .up:
      return Data([0x1B, 0x5B, 0x41])
    case .down:
      return Data([0x1B, 0x5B, 0x42])
    case .right:
      return Data([0x1B, 0x5B, 0x43])
    case .left:
      return Data([0x1B, 0x5B, 0x44])
    case .home:
      return Data([0x1B, 0x5B, 0x48])
    case .end:
      return Data([0x1B, 0x5B, 0x46])
    case .pageUp:
      return Data([0x1B, 0x5B, 0x35, 0x7E])
    case .pageDown:
      return Data([0x1B, 0x5B, 0x36, 0x7E])
    case .delete:
      return Data([0x1B, 0x5B, 0x33, 0x7E])
    case .control(let letter):
      guard let ascii = letter.asciiValue else { return Data() }
      // Ctrl-<letter> maps to the letter's position in the alphabet as a
      // C0 control code: 'A'/'a' -> 0x01 ... 'Z'/'z' -> 0x1A. Anything
      // outside A-Z/a-z (e.g. digits, punctuation) has no single-byte C0
      // mapping in this minimal table and encodes to nothing rather than
      // guessing.
      let upper = ascii & ~0x20
      guard (0x41...0x5A).contains(upper) else { return Data() }
      return Data([upper - 0x40])
    }
  }
}

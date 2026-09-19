import Foundation

/// DEC private modes the remote program has switched on, tracked by scanning
/// the raw output stream (`CSI ? Pm h/l`). `GhosttyVTTerminal` exposes no mode
/// getters, and the byte stream is already in hand, so this stays a tiny
/// scanner rather than a second VT parser: it only recognizes the modes T06
/// needs and tolerates sequences split across frames.
public struct ClairV2TerminalModes: Sendable {
  public var bracketedPaste = false
  public var focusReporting = false
  /// 1000 = press/release, 1002 = + drag, 1003 = + any motion; nil = off.
  public var mouseTracking: Int?
  public var mouseSGR = false

  private enum ScanState { case ground, escape, csi(String) }
  private var scan = ScanState.ground

  public init() {}

  public var mouseReporting: Bool { mouseTracking != nil }

  public mutating func feed(_ bytes: Data) {
    for byte in bytes {
      switch scan {
      case .ground:
        if byte == 0x1B { scan = .escape }
      case .escape:
        scan = byte == 0x5B ? .csi("") : (byte == 0x1B ? .escape : .ground)
      case .csi(let params):
        switch byte {
        case 0x30...0x3F where params.count < 32:
          scan = .csi(params + String(UnicodeScalar(byte)))
        case 0x40...0x7E:
          if params.hasPrefix("?"), byte == 0x68 || byte == 0x6C {
            apply(params.dropFirst().split(separator: ";").compactMap { Int($0) }, on: byte == 0x68)
          }
          scan = .ground
        default:
          scan = byte == 0x1B ? .escape : .ground
        }
      }
    }
  }

  private mutating func apply(_ modes: [Int], on: Bool) {
    for mode in modes {
      switch mode {
      case 2004: bracketedPaste = on
      case 1004: focusReporting = on
      case 1006: mouseSGR = on
      case 1000, 1002, 1003:
        if on { mouseTracking = mode } else if mouseTracking == mode { mouseTracking = nil }
      default: break
      }
    }
  }
}

/// Paste guard: what actually reaches the PTY when the user pastes.
public enum ClairV2TerminalPaste {
  public static let bracketStart = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
  public static let bracketEnd = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])

  /// True when a paste would execute lines immediately (multi-line into a
  /// program that did not ask for bracketed paste) -- the caller should
  /// confirm with the user first.
  public static func needsConfirmation(_ text: String, modes: ClairV2TerminalModes) -> Bool {
    !modes.bracketedPaste && text.contains(where: \.isNewline)
  }

  /// Strips control characters (ESC in particular, so pasted text cannot
  /// close the bracket early or inject sequences), normalizes newlines to CR,
  /// and wraps in the bracket markers when the program enabled the mode.
  public static func encode(_ text: String, modes: ClairV2TerminalModes) -> Data {
    var out = ""
    var afterCR = false
    for scalar in text.unicodeScalars {
      defer { afterCR = scalar.value == 0x0D }
      switch scalar.value {
      case 0x0A where afterCR: break  // CRLF collapses to one CR
      case 0x0A, 0x0D: out.unicodeScalars.append("\r")
      case 0x09, 0x20...0x7E, 0xA0...: out.unicodeScalars.append(scalar)
      default: break
      }
    }
    let body = Data(out.utf8)
    return modes.bracketedPaste ? bracketStart + body + bracketEnd : body
  }
}

public enum ClairV2TerminalFocus {
  public static func encode(focused: Bool, modes: ClairV2TerminalModes) -> Data {
    modes.focusReporting ? Data([0x1B, 0x5B, focused ? 0x49 : 0x4F]) : Data()
  }
}

public enum ClairV2TerminalMouseButton: Equatable, Sendable {
  case left, middle, right, wheelUp, wheelDown
}

public enum ClairV2TerminalMouseAction: Equatable, Sendable {
  case press, release, drag
}

public enum ClairV2TerminalMouse {
  /// Encodes one mouse event for a 0-based `column`/`row`. Empty when the
  /// program has not enabled reporting, or when the event kind is not part of
  /// the enabled level (drag needs 1002+; X10 encoding cannot address cells
  /// past 222).
  public static func encode(
    _ button: ClairV2TerminalMouseButton, _ action: ClairV2TerminalMouseAction,
    column: Int, row: Int, modes: ClairV2TerminalModes
  ) -> Data {
    guard let level = modes.mouseTracking, column >= 0, row >= 0 else { return Data() }
    if action == .drag, level < 1002 { return Data() }
    let isWheel = button == .wheelUp || button == .wheelDown
    if isWheel, action != .press { return Data() }

    var code: Int
    switch button {
    case .left: code = 0
    case .middle: code = 1
    case .right: code = 2
    case .wheelUp: code = 64
    case .wheelDown: code = 65
    }
    if action == .drag { code += 32 }

    if modes.mouseSGR {
      let final = action == .release ? "m" : "M"
      return Data("\u{1B}[<\(code);\(column + 1);\(row + 1)\(final)".utf8)
    }
    guard column < 223, row < 223 else { return Data() }
    if action == .release { code = 3 }  // legacy encoding has no per-button release
    return Data([0x1B, 0x5B, 0x4D, UInt8(32 + code), UInt8(33 + column), UInt8(33 + row)])
  }
}

/// Terminal cell width of a character (0 combining, 2 East-Asian wide/emoji,
/// else 1), so CJK text lines up with the VT grid's columns.
public enum ClairV2TerminalCellWidth {
  public static func of(_ character: Character) -> Int {
    guard let scalar = character.unicodeScalars.first else { return 0 }
    switch scalar.value {
    case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F: return 0
    case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
      0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
      return 2
    default: return 1
    }
  }
}

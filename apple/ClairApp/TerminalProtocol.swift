import Foundation

enum TerminalFrameKind: UInt8, Equatable, Sendable {
  case input = 1
  case resize = 2
  case close = 3
  case output = 0x81
  case exit = 0x82
  case error = 0xff
}

enum TerminalProtocolError: Error, Equatable {
  case invalidMagic
  case unsupportedVersion(UInt8)
  case unknownFrameKind(UInt8)
  case payloadTooLarge(Int)
  case invalidPayloadLength(kind: TerminalFrameKind, expected: Int, actual: Int)
  case invalidDimensions
}

struct TerminalFrame: Equatable, Sendable {
  static let protocolVersion: UInt8 = 1
  static let maxPayloadLength = 64 * 1024
  private static let magic: [UInt8] = [0x43, 0x50]

  let kind: TerminalFrameKind
  let payload: Data

  init(kind: TerminalFrameKind, payload: Data) throws {
    guard payload.count <= Self.maxPayloadLength else {
      throw TerminalProtocolError.payloadTooLarge(payload.count)
    }

    let expectedLength: Int?
    switch kind {
    case .resize:
      expectedLength = 4
    case .close:
      expectedLength = 0
    case .exit:
      expectedLength = 1
    case .input, .output, .error:
      expectedLength = nil
    }

    if let expectedLength, payload.count != expectedLength {
      throw TerminalProtocolError.invalidPayloadLength(
        kind: kind,
        expected: expectedLength,
        actual: payload.count
      )
    }

    self.kind = kind
    self.payload = payload
  }

  static func input(_ text: String) throws -> TerminalFrame {
    try TerminalFrame(kind: .input, payload: Data(text.utf8))
  }

  static func input(_ data: Data) throws -> TerminalFrame {
    try TerminalFrame(kind: .input, payload: data)
  }

  static func resize(rows: UInt16, columns: UInt16) throws -> TerminalFrame {
    guard rows > 0, columns > 0 else {
      throw TerminalProtocolError.invalidDimensions
    }

    var payload = Data()
    payload.append(contentsOf: rows.bigEndianBytes)
    payload.append(contentsOf: columns.bigEndianBytes)
    return try TerminalFrame(kind: .resize, payload: payload)
  }

  static var close: TerminalFrame {
    // The fixed-size close payload is part of the protocol contract and cannot fail.
    try! TerminalFrame(kind: .close, payload: Data())
  }

  static func exit(status: UInt8) -> TerminalFrame {
    // The fixed-size exit payload is part of the protocol contract and cannot fail.
    try! TerminalFrame(kind: .exit, payload: Data([status]))
  }

  static func error(message: String) throws -> TerminalFrame {
    try TerminalFrame(kind: .error, payload: Data(message.utf8))
  }

  var dimensions: (rows: UInt16, columns: UInt16)? {
    guard kind == .resize, payload.count == 4 else {
      return nil
    }
    let bytes = Array(payload)
    let rows = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    let columns = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
    guard rows > 0, columns > 0 else {
      return nil
    }
    return (rows, columns)
  }

  var encoded: Data {
    var data = Data(Self.magic)
    data.append(Self.protocolVersion)
    data.append(kind.rawValue)
    let length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
  }
}

struct TerminalFrameDecoder {
  private var buffer = Data()

  mutating func append(_ data: Data) throws -> [TerminalFrame] {
    buffer.append(data)
    var frames: [TerminalFrame] = []

    while buffer.count >= 8 {
      let header = Array(buffer.prefix(8))
      guard Array(header.prefix(2)) == [0x43, 0x50] else {
        throw TerminalProtocolError.invalidMagic
      }
      guard header[2] == TerminalFrame.protocolVersion else {
        throw TerminalProtocolError.unsupportedVersion(header[2])
      }
      guard let kind = TerminalFrameKind(rawValue: header[3]) else {
        throw TerminalProtocolError.unknownFrameKind(header[3])
      }

      let length = Int(
        UInt32(header[4]) << 24
          | UInt32(header[5]) << 16
          | UInt32(header[6]) << 8
          | UInt32(header[7])
      )
      guard length <= TerminalFrame.maxPayloadLength else {
        throw TerminalProtocolError.payloadTooLarge(length)
      }
      let totalLength = 8 + length
      guard buffer.count >= totalLength else {
        break
      }

      let payload = Data(buffer.dropFirst(8).prefix(length))
      frames.append(try TerminalFrame(kind: kind, payload: payload))
      buffer.removeFirst(totalLength)
    }

    return frames
  }
}

struct TerminalDimensions: Equatable, Sendable {
  static let defaultDimensions = TerminalDimensions(rows: 24, columns: 80)

  let rows: UInt16
  let columns: UInt16
}

struct TerminalOutputSanitizer {
  private enum State {
    case ground
    case escape
    case csi
    case osc
    case oscEscape
  }

  private var state: State = .ground

  mutating func filter(_ data: Data) -> Data {
    var filtered = Data()
    for byte in data {
      switch state {
      case .ground:
        consumeGround(byte, into: &filtered)
      case .escape:
        consumeEscape(byte)
      case .csi:
        if (0x40...0x7e).contains(byte) {
          state = .ground
        }
      case .osc:
        if byte == 0x07 {
          state = .ground
        } else if byte == 0x1b {
          state = .oscEscape
        }
      case .oscEscape:
        if byte == 0x5c || byte == 0x07 {
          state = .ground
        } else {
          state = .osc
        }
      }
    }
    return filtered
  }

  private mutating func consumeGround(_ byte: UInt8, into filtered: inout Data) {
    switch byte {
    case 0x1b:
      state = .escape
    case 0x08, 0x0d, 0x07:
      // A plain transcript cannot faithfully redraw a cursor position. Drop
      // these controls while retaining the following line feed and text.
      break
    case 0x09, 0x0a:
      filtered.append(byte)
    case 0x20...0x7e, 0x80...0xff:
      filtered.append(byte)
    default:
      break
    }
  }

  private mutating func consumeEscape(_ byte: UInt8) {
    switch byte {
    case 0x5b:
      state = .csi
    case 0x5d, 0x50, 0x5e, 0x5f:
      state = .osc
    default:
      state = .ground
    }
  }
}

struct TerminalTranscriptBuffer {
  static let defaultMaximumBytes = 2 * 1024 * 1024

  private let maximumBytes: Int
  private var data = Data()
  private var sanitizer = TerminalOutputSanitizer()

  init(maximumBytes: Int = Self.defaultMaximumBytes) {
    self.maximumBytes = max(1, maximumBytes)
  }

  mutating func append(_ output: Data) {
    data.append(sanitizer.filter(output))
    trimIfNeeded()
  }

  var string: String {
    String(decoding: data, as: UTF8.self)
  }

  var byteCount: Int {
    data.count
  }

  private mutating func trimIfNeeded() {
    guard data.count > maximumBytes else {
      return
    }
    data.removeFirst(data.count - maximumBytes)
    while let first = data.first, (first & 0xc0) == 0x80 {
      data.removeFirst()
    }
  }
}

extension UInt16 {
  fileprivate var bigEndianBytes: [UInt8] {
    [UInt8(self >> 8), UInt8(self & 0xff)]
  }
}

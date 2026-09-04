import Foundation

public enum MobileTransportFrameKind: UInt8, Codable, Sendable {
  case control = 1
  case terminal = 2
}

public enum MobileTransportError: Error, Equatable, LocalizedError, Sendable {
  case invalidFrameKind(UInt8)
  case frameTooLarge(Int)
  case truncatedFrame
  case invalidTerminalFrame
  case emptyControlFrame

  public var errorDescription: String? {
    switch self {
    case .invalidFrameKind(let kind):
      "Unknown mobile transport frame kind 0x\(String(kind, radix: 16))."
    case .frameTooLarge(let length):
      "Mobile transport frame is too large: \(length) bytes."
    case .truncatedFrame:
      "Mobile transport frame is truncated."
    case .invalidTerminalFrame:
      "Mobile transport terminal payload is not a valid terminal frame."
    case .emptyControlFrame:
      "Mobile transport control payload must not be empty."
    }
  }
}

/// A transport-neutral envelope. Network adapters may put this envelope on a
/// WebSocket message, a loopback connection, or a private-network tunnel.
/// Terminal bytes remain binary and are never JSON/base64 encoded.
public struct MobileTransportFrame: Equatable, Sendable {
  public static let headerLength = 5
  public static let maximumControlPayloadLength = 64 * 1024
  public static let maximumTerminalPayloadLength = MobileTerminalFrame.headerLength + 64 * 1024

  public let kind: MobileTransportFrameKind
  public let payload: Data

  public init(kind: MobileTransportFrameKind, payload: Data) throws {
    switch kind {
    case .control:
      guard !payload.isEmpty else {
        throw MobileTransportError.emptyControlFrame
      }
      guard payload.count <= Self.maximumControlPayloadLength else {
        throw MobileTransportError.frameTooLarge(payload.count)
      }
    case .terminal:
      guard payload.count <= Self.maximumTerminalPayloadLength else {
        throw MobileTransportError.frameTooLarge(payload.count)
      }
      guard (try? MobileTerminalFrame.decode(payload)) != nil else {
        throw MobileTransportError.invalidTerminalFrame
      }
    }
    self.kind = kind
    self.payload = payload
  }

  public static func control(_ data: Data) throws -> Self {
    try Self(kind: .control, payload: data)
  }

  public static func terminal(_ frame: MobileTerminalFrame) throws -> Self {
    try Self(kind: .terminal, payload: frame.encoded)
  }

  public var encoded: Data {
    var data = Data([kind.rawValue])
    let length = UInt32(payload.count)
    data.append(UInt8((length >> 24) & 0xff))
    data.append(UInt8((length >> 16) & 0xff))
    data.append(UInt8((length >> 8) & 0xff))
    data.append(UInt8(length & 0xff))
    data.append(payload)
    return data
  }
}

public struct MobileTransportFrameDecoder: Sendable {
  private var buffer = Data()

  public init() {}

  public mutating func append(_ data: Data) throws -> [MobileTransportFrame] {
    guard data.count <= Self.maximumBufferedBytes - buffer.count else {
      throw MobileTransportError.frameTooLarge(data.count + buffer.count)
    }
    buffer.append(data)
    var frames: [MobileTransportFrame] = []

    while buffer.count >= MobileTransportFrame.headerLength {
      let kindByte = buffer[buffer.startIndex]
      guard let kind = MobileTransportFrameKind(rawValue: kindByte) else {
        throw MobileTransportError.invalidFrameKind(kindByte)
      }
      let length = Int(
        UInt32(buffer[buffer.startIndex + 1]) << 24
          | UInt32(buffer[buffer.startIndex + 2]) << 16
          | UInt32(buffer[buffer.startIndex + 3]) << 8
          | UInt32(buffer[buffer.startIndex + 4])
      )
      let maximum =
        kind == .control
        ? MobileTransportFrame.maximumControlPayloadLength
        : MobileTransportFrame.maximumTerminalPayloadLength
      guard length <= maximum else {
        throw MobileTransportError.frameTooLarge(length)
      }
      let totalLength = MobileTransportFrame.headerLength + length
      guard buffer.count >= totalLength else {
        break
      }
      let payload = Data(buffer.dropFirst(MobileTransportFrame.headerLength).prefix(length))
      frames.append(try MobileTransportFrame(kind: kind, payload: payload))
      buffer.removeFirst(totalLength)
    }
    return frames
  }

  public var hasPartialFrame: Bool {
    !buffer.isEmpty
  }

  public mutating func finish() throws {
    guard buffer.isEmpty else {
      throw MobileTransportError.truncatedFrame
    }
  }

  private static let maximumBufferedBytes =
    MobileTransportFrame.maximumTerminalPayloadLength + MobileTransportFrame.headerLength
}

public enum MobilePrivateTransportKind: String, Codable, CaseIterable, Sendable {
  case loopback
  case tailscaleServe = "tailscale_serve"
  case cloudflarePrivateRoute = "cloudflare_private_route"
}

public struct MobileControlEndpoint: Codable, Equatable, Sendable {
  public let kind: MobilePrivateTransportKind
  public let address: String

  public init(kind: MobilePrivateTransportKind, address: String) throws {
    let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      normalized.utf8.count <= 2 * 1024,
      !normalized.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    else {
      throw MobileHostError.invalidEndpoint
    }
    self.kind = kind
    self.address = normalized
  }
}

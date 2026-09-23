import Foundation

/// DAP uses Content-Length framed JSON over a byte stream. This parser owns only
/// framing; the adapter owns request IDs, session state, and transport lifetime.
public struct DAPFrameParser: Sendable {
  public enum Failure: Error, Equatable { case malformedHeader, oversizedMessage }
  public static let maximumBodyBytes = 8 * 1024 * 1024
  private var buffer = Data()
  private var bodyLength: Int?

  public init() {}

  public mutating func append(_ bytes: Data) throws -> [Data] {
    buffer.append(bytes)
    var messages: [Data] = []
    while true {
      if bodyLength == nil {
        guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
          if buffer.count > 4096 { throw Failure.malformedHeader }
          break
        }
        let header = buffer.subdata(in: 0..<boundary.lowerBound)
        guard header.count <= 4096, let text = String(data: header, encoding: .ascii) else { throw Failure.malformedHeader }
        let lengths = text.components(separatedBy: "\r\n").compactMap { line -> Int? in
          let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
          guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
          return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        guard lengths.count == 1, let length = lengths.first, length >= 0 else { throw Failure.malformedHeader }
        guard length <= Self.maximumBodyBytes else { throw Failure.oversizedMessage }
        bodyLength = length
        buffer.removeSubrange(0..<boundary.upperBound)
      }
      guard let length = bodyLength, buffer.count >= length else { break }
      messages.append(buffer.subdata(in: 0..<length))
      buffer.removeSubrange(0..<length)
      bodyLength = nil
    }
    return messages
  }

  public static func encode(_ body: Data) throws -> Data {
    guard body.count <= maximumBodyBytes else { throw Failure.oversizedMessage }
    var result = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
    result.append(body)
    return result
  }
}

import ClairV2Shared
import Foundation

public enum ClairV2TerminalError: Error, Equatable, Sendable {
  case invalidLimits, invalidFrame, invalidCursor, staleEpoch, staleSession
  case gap(availableOffset: UInt64)
  case capacity, backpressure, closed, ioFailure, unauthorized, resizeDenied
  case invalidOperation, conflictingOperation, operationCapacity
}

public struct ClairV2TerminalSize: Codable, Equatable, Sendable {
  public let rows: UInt16
  public let columns: UInt16

  public init(rows: UInt16 = 24, columns: UInt16 = 80) throws {
    guard (1...4096).contains(rows), (1...4096).contains(columns) else {
      throw ClairV2TerminalError.invalidLimits
    }
    self.rows = rows
    self.columns = columns
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      rows: c.decode(UInt16.self, forKey: .rows), columns: c.decode(UInt16.self, forKey: .columns))
  }
}

public struct ClairV2TerminalLimits: Sendable {
  public let journalBytes: Int
  public let inputBytes: Int
  public static let standard = try! Self()

  public init(journalBytes: Int = 1_048_576, inputBytes: Int = 262_144) throws {
    guard (1...16_777_216).contains(journalBytes), (1...1_048_576).contains(inputBytes) else {
      throw ClairV2TerminalError.invalidLimits
    }
    self.journalBytes = journalBytes
    self.inputBytes = inputBytes
  }
}

public struct ClairV2TerminalCursor: Codable, Equatable, Sendable {
  public let epoch: SessionEpoch
  public let offset: UInt64

  public init(epoch: SessionEpoch, offset: UInt64) {
    self.epoch = epoch
    self.offset = offset
  }
}

/// Bound to an authenticated attachment by its caller. Raw bytes never go
/// through JSON/base64. B03 framing encloses big-endian epoch + offset + bytes.
public struct ClairV2TerminalFrame: Equatable, Sendable, CustomStringConvertible {
  public static let maximumPayloadBytes = 65_536
  public let cursor: ClairV2TerminalCursor
  public let bytes: Data
  public var nextCursor: ClairV2TerminalCursor {
    ClairV2TerminalCursor(epoch: cursor.epoch, offset: cursor.offset + UInt64(bytes.count))
  }
  public var description: String { "TerminalFrame(<redacted>)" }

  public init(cursor: ClairV2TerminalCursor, bytes: Data) throws {
    guard !bytes.isEmpty, bytes.count <= Self.maximumPayloadBytes,
      cursor.offset <= UInt64.max - UInt64(bytes.count)
    else { throw ClairV2TerminalError.invalidFrame }
    self.cursor = cursor
    self.bytes = bytes
  }

  public func encoded() throws -> Data {
    var body = Data()
    for value in [cursor.epoch.value, cursor.offset] {
      for shift in stride(from: 56, through: 0, by: -8) {
        body.append(UInt8(truncatingIfNeeded: value >> shift))
      }
    }
    body.append(bytes)
    return try BoundedFrame(payload: body, limits: Self.frameLimits).encoded
  }

  public static func decode(_ data: Data) throws -> Self {
    let body = try BoundedFrame.decode(data, limits: frameLimits).payload
    guard body.count > 16 else { throw ClairV2TerminalError.invalidFrame }
    let epoch = body.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    let offset = body.dropFirst(8).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    return try Self(
      cursor: ClairV2TerminalCursor(epoch: SessionEpoch(epoch), offset: offset),
      bytes: Data(body.dropFirst(16)))
  }

  private static let frameLimits = try! FrameLimits(maximumPayloadBytes: maximumPayloadBytes + 16)
}

public struct ClairV2TerminalStreamSnapshot: Equatable, Sendable {
  public let epoch: SessionEpoch
  public let retainedStart: UInt64
  public let endOffset: UInt64
  public let isClosed: Bool
  public let inputIsUncertain: Bool
  public let outputFailed: Bool
  public var historyTruncated: Bool { retainedStart > 0 }
}

/// One bounded memory journal per process, independent of subscriber count.
/// The PTY pump appends synchronously; there is no unbounded task/stream queue.
public final class ClairV2TerminalJournal: @unchecked Sendable {
  public let epoch: SessionEpoch
  private let lock = NSLock()
  private let capacity: Int
  private var bytes = Data()
  private var endOffset: UInt64 = 0
  private var closed = false
  private var uncertain = false
  private var failed = false

  public init(capacity: Int, epoch: SessionEpoch? = nil) throws {
    guard (1...16_777_216).contains(capacity) else { throw ClairV2TerminalError.invalidLimits }
    self.capacity = capacity
    self.epoch = try epoch ?? SessionEpoch(UInt64.random(in: 1...UInt64.max))
  }

  public func append(_ data: Data) throws {
    try lock.withLock {
      guard !closed, !failed else { throw ClairV2TerminalError.closed }
      guard data.count <= ClairV2TerminalFrame.maximumPayloadBytes,
        endOffset <= UInt64.max - UInt64(data.count)
      else {
        failed = true
        throw ClairV2TerminalError.invalidFrame
      }
      endOffset += UInt64(data.count)
      let excess = max(0, bytes.count + data.count - capacity)
      if excess >= bytes.count {
        bytes = Data(data.suffix(capacity))
      } else {
        bytes.removeFirst(excess)
        bytes.append(data)
      }
    }
  }

  public func read(from cursor: ClairV2TerminalCursor, maximumBytes: Int = 65_536) throws
    -> ClairV2TerminalFrame?
  {
    try lock.withLock {
      guard cursor.epoch == epoch else { throw ClairV2TerminalError.staleEpoch }
      guard (1...ClairV2TerminalFrame.maximumPayloadBytes).contains(maximumBytes),
        cursor.offset <= endOffset
      else {
        throw ClairV2TerminalError.invalidCursor
      }
      let start = endOffset - UInt64(bytes.count)
      guard cursor.offset >= start else { throw ClairV2TerminalError.gap(availableOffset: start) }
      guard cursor.offset < endOffset else {
        if failed { throw ClairV2TerminalError.ioFailure }
        return nil
      }
      return try ClairV2TerminalFrame(
        cursor: cursor,
        bytes: Data(bytes.dropFirst(Int(cursor.offset - start)).prefix(maximumBytes)))
    }
  }

  public func finish(inputIsUncertain: Bool, outputFailed: Bool = false) {
    lock.withLock {
      closed = true
      uncertain = uncertain || inputIsUncertain
      failed = failed || outputFailed
    }
  }

  public func snapshot() -> ClairV2TerminalStreamSnapshot {
    lock.withLock {
      ClairV2TerminalStreamSnapshot(
        epoch: epoch, retainedStart: endOffset - UInt64(bytes.count), endOffset: endOffset,
        isClosed: closed, inputIsUncertain: uncertain, outputFailed: failed)
    }
  }
}

public enum ClairV2TerminalCommitOutcome: String, Codable, Equatable, Sendable {
  case queued, rejected, indeterminate
}

/// Internal daemon-owned process seam. A surface only obtains an attachment,
/// never this raw handle. enqueue must synchronously commit a bounded FIFO item.
public protocol ClairV2TerminalProcess: AnyObject, Sendable {
  var terminalJournal: ClairV2TerminalJournal { get }
  var terminalSize: ClairV2TerminalSize { get }
  func enqueueTerminalInput(_ bytes: Data) -> ClairV2TerminalCommitOutcome
  func commitTerminalSignal(_ signal: Int32) -> ClairV2TerminalCommitOutcome
  func resizeTerminal(_ size: ClairV2TerminalSize) throws
}

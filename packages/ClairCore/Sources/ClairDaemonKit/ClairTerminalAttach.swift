#if os(macOS)

  import ClairTerminal
  import Foundation

  public enum ClairTerminalAttachError: Error, Equatable, Sendable {
    case rejected
  }

  /// One surface's attachment to a daemon-owned shell (spec §7). It holds only a cursor: the
  /// daemon's journal is the source of truth, so `detach` is just dropping this object and the
  /// shell keeps running. `clair attach` runs this inside the Ghostty surface's child process.
  public final class ClairTerminalAttach: @unchecked Sendable {
    /// Keep a request under the control-frame limit once JSON/base64 encoded.
    static let inputChunkBytes = 16_384

    public let sessionID: String
    private let client: ClairDaemonControlClient
    private var epoch: UInt64
    private var offset: UInt64

    public init(
      client: ClairDaemonControlClient, key: String, cwd: String, command: String?,
      size: ClairTerminalSize, environment: [String: String]
    ) throws {
      self.client = client
      let response = try client.terminal(
        .open(
          key: key, cwd: cwd, command: command, rows: size.rows, columns: size.columns,
          environment: environment))
      guard case .opened(let id, let epoch, let start) = response else {
        throw ClairTerminalAttachError.rejected
      }
      self.sessionID = id
      self.epoch = epoch
      self.offset = start
    }

    /// Waits up to `waitMilliseconds` for output and hands it to `sink`. Returns false once the
    /// shell has exited and everything it wrote has been delivered.
    public func pump(waitMilliseconds: Int = 500, _ sink: (Data) throws -> Void) throws -> Bool {
      let response = try client.terminal(
        .read(
          sessionID: sessionID, epoch: epoch, offset: offset, waitMilliseconds: waitMilliseconds))
      switch response {
      case .output(let bytes, let newEpoch, let next, let isClosed):
        if !bytes.isEmpty { try sink(bytes) }
        epoch = newEpoch
        offset = next
        return !isClosed
      case .gap(let available):
        // Output that fell out of the bounded journal is gone; continue from what is retained.
        offset = available
        return true
      default:
        throw ClairTerminalAttachError.rejected
      }
    }

    public func send(_ bytes: Data) throws {
      var rest = bytes[...]
      while !rest.isEmpty {
        let chunk = rest.prefix(Self.inputChunkBytes)
        rest = rest.dropFirst(chunk.count)
        guard case .accepted = try client.terminal(.input(sessionID: sessionID, bytes: Data(chunk)))
        else { throw ClairTerminalAttachError.rejected }
      }
    }

    public func resize(rows: UInt16, columns: UInt16) throws {
      guard
        case .accepted = try client.terminal(
          .resize(sessionID: sessionID, rows: rows, columns: columns))
      else { throw ClairTerminalAttachError.rejected }
    }
  }

#endif

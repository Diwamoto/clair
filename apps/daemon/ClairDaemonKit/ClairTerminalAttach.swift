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
    ///
    /// One slow reply (a busy or throttled daemon) must not end the pane: the read restarts from
    /// the same cursor, so retrying loses nothing. A daemon that is gone fails to connect instead.
    public func pump(waitMilliseconds: Int = 500, _ sink: (Data) throws -> Void) throws -> Bool {
      let request = ClairDaemonTerminalRequest.read(
        sessionID: sessionID, epoch: epoch, offset: offset, waitMilliseconds: waitMilliseconds)
      var response: ClairDaemonTerminalResponse?
      var timeouts = 0
      let started = Date()
      while response == nil {
        do { response = try client.terminal(request) } catch ClairDaemonError.transportTimedOut {
          timeouts += 1
        }
      }
      if timeouts > 0 {
        // The cause of these stalls is still unknown; the report carries sleep/wake timing.
        ClairIssueReporter.reportInBackground(
          "terminal: a daemon reply took longer than the control timeout",
          "`clair attach` waited \(Int(Date().timeIntervalSince(started))) s (\(timeouts) timed-out "
            + "read request(s)) before the daemon answered. The pane recovered.")
      }
      switch response! {
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
        // Input is not idempotent, so a timed-out chunk is not resent: it counts as rejected
        // (dropped with a bell) instead of ending the attachment.
        let response: ClairDaemonTerminalResponse
        do { response = try client.terminal(.input(sessionID: sessionID, bytes: Data(chunk))) }
        catch ClairDaemonError.transportTimedOut { throw ClairTerminalAttachError.rejected }
        guard case .accepted = response else { throw ClairTerminalAttachError.rejected }
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

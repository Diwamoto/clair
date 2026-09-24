#if os(macOS)

  import ClairShared
  import ClairTerminal
  import Foundation

  /// T09: local, same-user terminal operations carried on the daemon control socket.
  /// The socket is owner-only (0700 directory, 0600 socket, peer uid checked), so this is
  /// separate from the paired-device path; both reach the same `ClairTerminalBoundary`.
  public enum ClairDaemonTerminalRequest: Codable, Equatable, Sendable {
    /// Idempotent per `key` while that shell is running. `command` runs via `$SHELL -l -c`.
    case open(
      key: String, cwd: String, command: String?, rows: UInt16, columns: UInt16,
      environment: [String: String])
    case read(sessionID: String, epoch: UInt64?, offset: UInt64?, waitMilliseconds: Int)
    case input(sessionID: String, bytes: Data)
    case resize(sessionID: String, rows: UInt16, columns: UInt16)
    /// The user closed the pane: end that shell. (Detaching is just dropping the attachment.)
    case close(key: String)
    /// Shell PID for a GUI-owned pane; the GUI uses it to identify CLI children.
    case processID(key: String)
  }

  public enum ClairDaemonTerminalResponse: Codable, Equatable, Sendable {
    case opened(sessionID: String, epoch: UInt64, retainedStart: UInt64)
    /// Empty `bytes` means nothing arrived within the wait. `isClosed` is final: the shell
    /// exited and every byte up to `nextOffset` has been delivered.
    case output(bytes: Data, epoch: UInt64, nextOffset: UInt64, isClosed: Bool)
    /// The requested offset fell out of the bounded journal; resume from `availableOffset`.
    case gap(availableOffset: UInt64)
    case accepted
    case rejected
    case processID(Int32?)
  }

  /// Owns every shell the Mac GUI shows. A shell is a `ClairTerminalProcess` installed in the
  /// same boundary as agent sessions, so journal, epoch/cursor, gap resync, input FIFO and
  /// desktop-owned geometry are the shared ones; there is no GUI-only path.
  public final class ClairLocalTerminalHost: @unchecked Sendable {
    public static let projectID = try! ProjectID("local-terminal")
    static let generation: UInt64 = 1
    /// Anything else in the client's environment stays out of the daemon's shell.
    public static let forwardedEnvironment: Set<String> = [
      "TERM", "TERMINFO", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
      "GHOSTTY_RESOURCES_DIR",
    ]
    static let maximumWaitMilliseconds = 2_000
    static let maximumKeyBytes = 1_024

    private struct Entry {
      let sessionID: SessionID
      let scope: ResourceScope
      let process: ClairLocalShellSession
      let owner: ClairTerminalResizeOwner
      let cwd: String
      let command: String?
    }
    private let boundary: ClairTerminalBoundary
    private let lock = NSLock()
    private var byKey: [String: Entry] = [:]

    public init(boundary: ClairTerminalBoundary) {
      self.boundary = boundary
    }

    public func handle(_ request: ClairDaemonTerminalRequest) -> ClairDaemonTerminalResponse {
      switch request {
      case .open(let key, let cwd, let command, let rows, let columns, let environment):
        return open(
          key: key, cwd: cwd, command: command, rows: rows, columns: columns,
          environment: environment)
      case .read(let id, let epoch, let offset, let wait):
        return read(id: id, epoch: epoch, offset: offset, wait: wait)
      case .input(let id, let bytes):
        return input(id: id, bytes: bytes)
      case .resize(let id, let rows, let columns):
        guard let entry = entry(id: id), let size = try? ClairTerminalSize(rows: rows, columns: columns),
          (try? boundary.resize(size, owner: entry.owner)) != nil
        else { return .rejected }
        return .accepted
      case .close(let key):
        guard let entry = lock.withLock({ byKey.removeValue(forKey: key) }) else {
          return .rejected
        }
        discard(entry)
        return .accepted
      case .processID(let key):
        let pid = lock.withLock { () -> Int32? in
          guard let process = byKey[key]?.process, process.isRunning else { return nil }
          return process.processID
        }
        return .processID(pid.flatMap { $0 > 0 ? $0 : nil })
      }
    }

    /// Explicit Clair quit / daemon stop: the only thing that ends shells besides their own exit.
    public func closeAll() {
      let entries = lock.withLock {
        defer { byKey.removeAll() }
        return Array(byKey.values)
      }
      for entry in entries { discard(entry) }
    }

    private func discard(_ entry: Entry) {
      entry.process.terminate()
      boundary.invalidate(sessionID: entry.sessionID, generation: Self.generation)
      boundary.remove(sessionID: entry.sessionID, generation: Self.generation)
    }

    private func open(
      key: String, cwd: String, command: String?, rows: UInt16, columns: UInt16,
      environment: [String: String]
    ) -> ClairDaemonTerminalResponse {
      guard !key.isEmpty, key.utf8.count <= Self.maximumKeyBytes, cwd.hasPrefix("/"),
        let size = try? ClairTerminalSize(rows: rows, columns: columns)
      else { return .rejected }
      return lock.withLock {
        // A running shell is reused only for the same launch; a pane that now wants another
        // cwd/command (e.g. after a pane swap) gets a fresh shell instead of a stale one.
        if let existing = byKey[key], existing.process.isRunning, existing.cwd == cwd,
          existing.command == command
        {
          let attachment = opened(existing, fromCurrentOutput: true)
          try? existing.process.resizeAndRedraw(size)
          // Old VT bytes were drawn at a different width. Replaying them into a new
          // surface corrupts wrapped prompts; the resize above repaints live content.
          return attachment
        }
        // Shells that exited on their own were only kept so their last output could be read.
        // ponytail: a client still draining a just-exited shell can lose its tail here.
        for (other, entry) in byKey where other != key && !entry.process.isRunning {
          byKey.removeValue(forKey: other)
          discard(entry)
        }
        if let stale = byKey.removeValue(forKey: key) { discard(stale) }

        var spec = ClairLocalShellSpec.loginShell(workingDirectoryURL: URL(fileURLWithPath: cwd))
        var env = spec.environment
        for (name, value) in environment where Self.forwardedEnvironment.contains(name) {
          env[name] = value
        }
        env["CLAIR_TERMINAL_KEY"] = key  // V16: lets `clair` inside this shell say which pane it runs in
        spec = ClairLocalShellSpec(
          executableURL: spec.executableURL,
          arguments: command.map { ["-l", "-c", $0] } ?? spec.arguments,
          environment: env, workingDirectoryURL: spec.workingDirectoryURL)
        guard let process = try? ClairLocalShellSession(spec: spec, size: size),
          (try? process.start()) != nil
        else { return .rejected }
        // From here the shell is live: every failure path must end it, not abandon it.
        guard let sessionID = try? SessionID(UUID().uuidString.lowercased()),
          let scope = try? ResourceScope(projectID: Self.projectID, sessionID: sessionID),
          (try? boundary.install(
            sessionID: sessionID, scope: scope, generation: Self.generation, process: process))
            != nil
        else {
          process.terminate()
          return .rejected
        }
        guard
          let owner = try? boundary.claimDesktopResizeOwner(
            scope: scope, generation: Self.generation)
        else {
          process.terminate()
          boundary.remove(sessionID: sessionID, generation: Self.generation)
          return .rejected
        }
        let entry = Entry(
          sessionID: sessionID, scope: scope, process: process, owner: owner, cwd: cwd,
          command: command)
        byKey[key] = entry
        return opened(entry)
      }
    }

    private func opened(_ entry: Entry, fromCurrentOutput: Bool = false) -> ClairDaemonTerminalResponse {
      let state = entry.process.terminalJournal.snapshot()
      return .opened(
        sessionID: entry.sessionID.rawValue, epoch: state.epoch.value,
        retainedStart: fromCurrentOutput ? state.endOffset : state.retainedStart)
    }

    private func read(id: String, epoch: UInt64?, offset: UInt64?, wait: Int)
      -> ClairDaemonTerminalResponse
    {
      guard let entry = entry(id: id) else { return .rejected }
      let journal = entry.process.terminalJournal
      let deadline = Date().addingTimeInterval(
        Double(min(max(wait, 0), Self.maximumWaitMilliseconds)) / 1_000)
      // ponytail: 5 ms poll instead of a condition variable; add one if idle CPU shows up.
      while true {
        let state = journal.snapshot()
        let start = ClairTerminalCursor(
          epoch: epoch.flatMap { try? SessionEpoch($0) } ?? state.epoch,
          offset: offset ?? state.retainedStart)
        do {
          if let frame = try journal.read(from: start, maximumBytes: 16_384) {
            let next = frame.nextCursor.offset
            // A re-attach that starts past dropped history first restores the window title.
            let title = start.offset == state.retainedStart && start.offset > 0 ? journal.titleSequence : nil
            return .output(
              bytes: (title ?? Data()) + frame.bytes, epoch: state.epoch.value, nextOffset: next,
              isClosed: state.isClosed && next == state.endOffset)
          }
        } catch ClairTerminalError.gap(let available) {
          return .gap(availableOffset: available)
        } catch {
          return .rejected
        }
        if state.isClosed || Date() >= deadline {
          return .output(
            bytes: Data(), epoch: state.epoch.value, nextOffset: start.offset,
            isClosed: state.isClosed)
        }
        Thread.sleep(forTimeInterval: 0.005)
      }
    }

    private func input(id: String, bytes: Data) -> ClairDaemonTerminalResponse {
      guard let entry = entry(id: id), !bytes.isEmpty,
        bytes.count <= ClairTerminalFrame.maximumPayloadBytes,
        (try? boundary.localWrite(
          scope: entry.scope, generation: Self.generation, bytes: bytes)) == .queued
      else { return .rejected }
      return .accepted
    }

    private func entry(id: String) -> Entry? {
      lock.withLock { byKey.values.first { $0.sessionID.rawValue == id } }
    }
  }

#endif

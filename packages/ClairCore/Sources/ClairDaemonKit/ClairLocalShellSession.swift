import ClairShared
import ClairTerminal
import Dispatch
import Foundation

#if os(macOS)
  import ClairPTY
  import Darwin

  /// Typed, fail-closed errors for the T03 local shell leg. There is no
  /// fallback terminal engine here either: a launch or write failure is a
  /// distinct reported state, never silently retried against a different
  /// process or discarded.
  public enum ClairLocalShellError: Error, Equatable, Sendable {
    case alreadyStarted
    case notRunning
    case workingDirectoryUnavailable(URL)
    case launchFailed
    case inputRejected
  }

  /// Describes the local shell process a macOS Ghostty surface should spawn.
  /// This is deliberately independent of `ClairAgent`'s launch-spec/session
  /// machinery: T03's "local shell" is a plain interactive shell owned by the
  /// Mac app's own trusted surface, not an agent provider session, and does
  /// not need project/workspace/approval semantics to exist.
  public struct ClairLocalShellSpec: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL

    public init(
      executableURL: URL,
      arguments: [String],
      environment: [String: String],
      workingDirectoryURL: URL
    ) {
      self.executableURL = executableURL
      self.arguments = arguments
      self.environment = environment
      self.workingDirectoryURL = workingDirectoryURL
    }

    /// Resolves the user's login shell from `$SHELL`, matching what Terminal.app
    /// and every other macOS terminal emulator launches by default. Falls back
    /// to `/bin/zsh` (the macOS default login shell) only when `$SHELL` is
    /// absent or empty; never silently substitutes a different interactive
    /// program.
    public static func loginShell(
      workingDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClairLocalShellSpec {
      var environment = ProcessInfo.processInfo.environment
      let shellPath = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
      if environment["TERM"] == nil || environment["TERM"]?.isEmpty == true {
        environment["TERM"] = "xterm-256color"
      }
      return ClairLocalShellSpec(
        executableURL: URL(fileURLWithPath: shellPath),
        arguments: ["-l"],
        environment: environment,
        workingDirectoryURL: workingDirectoryURL
      )
    }
  }

  public typealias ClairLocalShellTerminationHandler = @Sendable (ClairLocalShellExit) -> Void

  public struct ClairLocalShellExit: Equatable, Sendable {
    public let status: Int32?
    public let signal: Int32?
    public let wasRequestedByClair: Bool
    public let didLaunch: Bool

    public init(
      status: Int32? = nil, signal: Int32? = nil, wasRequestedByClair: Bool = false,
      didLaunch: Bool = true
    ) {
      self.status = status
      self.signal = signal
      self.wasRequestedByClair = wasRequestedByClair
      self.didLaunch = didLaunch
    }
  }

  /// A single local, macOS-only PTY-backed shell process for the Mac app's own
  /// trusted Ghostty surface (T03). This is not the daemon-owned remote-attach
  /// path (T02's `ClairTerminalBoundary`/`ClairPTYAgentProcess` own that,
  /// for T04/T06 remote surfaces); it reuses the same bounded
  /// `ClairTerminalJournal` and the same `ClairPTY` C spawn/resize
  /// primitives so a real PTY, not an emulated one, backs the surface.
  public final class ClairLocalShellSession: ClairTerminalProcess, @unchecked Sendable {
    public let terminalJournal: ClairTerminalJournal
    private let lock = NSLock()
    private let spec: ClairLocalShellSpec
    private let cwd: Int32
    private let limits: ClairTerminalLimits
    private let onTermination: ClairLocalShellTerminationHandler
    private var handle: clair_pty_handle?
    private var started = false
    private var running = false
    private var requested = false
    private var input = Data()
    private var inputFailed = false
    private var size: ClairTerminalSize

    public init(
      spec: ClairLocalShellSpec = .loginShell(),
      limits: ClairTerminalLimits = .standard,
      size: ClairTerminalSize = try! ClairTerminalSize(),
      onTermination: @escaping ClairLocalShellTerminationHandler = { _ in }
    ) throws {
      self.spec = spec
      self.limits = limits
      self.size = size
      self.onTermination = onTermination
      self.terminalJournal = try ClairTerminalJournal(capacity: limits.journalBytes)
      let descriptor = Darwin.open(
        spec.workingDirectoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else {
        throw ClairLocalShellError.workingDirectoryUnavailable(spec.workingDirectoryURL)
      }
      self.cwd = descriptor
    }

    deinit { Darwin.close(cwd) }

    public var processID: Int32 { lock.withLock { handle?.provider_pid ?? 0 } }
    public var isRunning: Bool { lock.withLock { running } }
    public var terminalSize: ClairTerminalSize { lock.withLock { size } }

    public func start() throws {
      try lock.withLock {
        guard !started else { throw ClairLocalShellError.alreadyStarted }
        started = true
        let argv = try strings([spec.executableURL.path] + spec.arguments)
        defer { for pointer in argv { free(pointer) } }
        let envp = try strings(
          spec.environment.keys.sorted().map { "\($0)=\(spec.environment[$0]!)" })
        defer { for pointer in envp { free(pointer) } }
        var arguments = argv + [nil]
        var environment = envp + [nil]
        var spawned = clair_pty_handle()
        let result = arguments.withUnsafeMutableBufferPointer { a in
          environment.withUnsafeMutableBufferPointer { e in
            clair_pty_spawn(
              spec.executableURL.path, a.baseAddress, e.baseAddress, cwd, size.rows, size.columns,
              &spawned)
          }
        }
        guard result == 0 else {
          terminalJournal.finish(inputIsUncertain: false)
          throw ClairLocalShellError.launchFailed
        }
        handle = spawned
        running = true
        let owned = spawned
        DispatchQueue.global(qos: .userInitiated).async { [self] in pump(owned) }
      }
    }

    /// Convenience over `enqueueTerminalInput` for surface code that wants a
    /// thrown error instead of inspecting `ClairTerminalCommitOutcome`.
    public func write(_ bytes: Data) throws {
      guard enqueueTerminalInput(bytes) == .queued else {
        throw ClairLocalShellError.inputRejected
      }
    }

    public func enqueueTerminalInput(_ bytes: Data) -> ClairTerminalCommitOutcome {
      lock.withLock {
        guard running, !inputFailed, !requested, !bytes.isEmpty,
          bytes.count <= ClairTerminalFrame.maximumPayloadBytes,
          bytes.count <= limits.inputBytes - input.count
        else { return .rejected }
        input.append(bytes)
        return .queued
      }
    }

    public func commitTerminalSignal(_ signal: Int32) -> ClairTerminalCommitOutcome {
      lock.withLock {
        guard [SIGINT, SIGTERM, SIGHUP, SIGKILL].contains(signal), running,
          let handle, handle.control_fd >= 0
        else { return .rejected }
        var byte = UInt8(signal)
        var result: Int
        repeat {
          result = Darwin.write(handle.control_fd, &byte, 1)
        } while result < 0 && errno == EINTR
        guard result == 1 else { return .rejected }
        if signal == SIGTERM || signal == SIGKILL { requested = true }
        return .queued
      }
    }

    public func resizeTerminal(_ newSize: ClairTerminalSize) throws {
      try lock.withLock {
        guard running, let handle else { throw ClairTerminalError.closed }
        guard clair_pty_resize(handle.master_fd, newSize.rows, newSize.columns) == 0 else {
          throw ClairTerminalError.ioFailure
        }
        size = newSize
      }
    }

    public func terminate() {
      _ = commitTerminalSignal(SIGTERM)
    }

    private func pump(_ owned: clair_pty_handle) {
      var outputFailed = false
      var buffer = [UInt8](repeating: 0, count: 16_384)
      var supervisorStatus: Int32 = 0
      var reaped = false
      while !reaped {
        let wantsWrite = lock.withLock { !input.isEmpty && !inputFailed }
        var pfd = pollfd(
          fd: owned.master_fd, events: Int16(POLLIN | (wantsWrite ? POLLOUT : 0)), revents: 0)
        let polled = Darwin.poll(&pfd, 1, 10)
        if polled < 0 && errno != EINTR {
          outputFailed = true
          _ = commitTerminalSignal(SIGKILL)
        }
        if pfd.revents & Int16(POLLIN | POLLHUP) != 0 {
          outputFailed = drain(owned.master_fd, buffer: &buffer) || outputFailed
        }
        if pfd.revents & Int16(POLLOUT) != 0 {
          lock.withLock {
            guard !input.isEmpty, !inputFailed else { return }
            let count = input.withUnsafeBytes { bytes in
              Darwin.write(owned.master_fd, bytes.baseAddress, min(bytes.count, 16_384))
            }
            if count > 0 {
              input.removeFirst(count)
            } else if count < 0 && errno != EINTR && errno != EAGAIN {
              inputFailed = true
            }
          }
        }
        if outputFailed || lock.withLock({ inputFailed }) { _ = commitTerminalSignal(SIGKILL) }
        let waited = Darwin.waitpid(owned.supervisor_pid, &supervisorStatus, WNOHANG)
        if waited == owned.supervisor_pid {
          reaped = true
        } else if waited < 0 && errno != EINTR {
          finish(owned, report: nil, outputFailed: true)
          return
        }
      }
      outputFailed = drain(owned.master_fd, buffer: &buffer) || outputFailed
      var report = clair_pty_exit()
      let count = Darwin.read(owned.status_fd, &report, MemoryLayout<clair_pty_exit>.size)
      finish(
        owned, report: count == MemoryLayout<clair_pty_exit>.size ? report : nil,
        outputFailed: outputFailed)
    }

    private func finish(_ owned: clair_pty_handle, report: clair_pty_exit?, outputFailed: Bool) {
      let validReport = report?.error == 0
      let status = report?.wait_status ?? 0
      let signal = status & 0x7f
      let exit: ClairLocalShellExit = lock.withLock {
        let value = ClairLocalShellExit(
          status: signal == 0 && validReport ? (status >> 8) & 0xff : nil,
          signal: signal != 0 && validReport ? signal : (validReport ? nil : SIGKILL),
          wasRequestedByClair: requested)
        running = false
        terminalJournal.finish(
          inputIsUncertain: inputFailed || !input.isEmpty,
          outputFailed: outputFailed || !validReport)
        input.removeAll()
        Darwin.close(owned.master_fd)
        Darwin.close(owned.control_fd)
        Darwin.close(owned.status_fd)
        handle?.master_fd = -1
        handle?.control_fd = -1
        handle?.status_fd = -1
        return value
      }
      onTermination(exit)
    }

    private func drain(_ fd: Int32, buffer: inout [UInt8]) -> Bool {
      for _ in 0..<256 {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
          do { try terminalJournal.append(Data(buffer.prefix(count))) } catch { return true }
        } else if count == 0 || (count < 0 && (errno == EAGAIN || errno == EIO)) {
          return false
        } else if errno != EINTR {
          return true
        }
      }
      return false
    }

    private func strings(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
      var result: [UnsafeMutablePointer<CChar>?] = []
      for value in values {
        guard let pointer = strdup(value) else {
          for pointer in result { free(pointer) }
          throw ClairLocalShellError.launchFailed
        }
        result.append(pointer)
      }
      return result
    }
  }
#endif

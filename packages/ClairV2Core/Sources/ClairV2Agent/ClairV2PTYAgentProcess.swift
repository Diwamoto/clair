import ClairV2Shared
import ClairV2Terminal
import Dispatch
import Foundation

#if os(macOS)
  import ClairV2PTY
  import Darwin
#endif

/// Select this factory on a registered provider to launch its unmodified TUI.
/// All three standard descriptors share one controlling terminal; stdout and
/// stderr ordering is the PTY's byte ordering, never a decoded provider event.
public struct ClairV2PTYAgentProcessFactory: ClairV2AgentProcessFactory {
  public let terminalLimits: ClairV2TerminalLimits
  public let initialSize: ClairV2TerminalSize

  public init(
    terminalLimits: ClairV2TerminalLimits = .standard,
    initialSize: ClairV2TerminalSize = try! ClairV2TerminalSize()
  ) {
    self.terminalLimits = terminalLimits
    self.initialSize = initialSize
  }

  public func makeProcess(
    spec: ClairV2AgentLaunchSpec,
    onTermination: @escaping ClairV2AgentTerminationHandler
  ) throws -> any ClairV2AgentProcess {
    #if os(macOS)
      return try ClairV2PTYAgentProcess(
        spec: spec, limits: terminalLimits, size: initialSize, onTermination: onTermination)
    #else
      throw ClairV2AgentError.unsupportedPlatform
    #endif
  }
}

#if os(macOS)
  final class ClairV2PTYAgentProcess: ClairV2AgentProcess, ClairV2TerminalProcess,
    @unchecked Sendable
  {
    let terminalJournal: ClairV2TerminalJournal
    private let lock = NSLock()
    private let spec: ClairV2AgentLaunchSpec
    private let cwd: Int32
    private let device: UInt64
    private let inode: UInt64
    private let limits: ClairV2TerminalLimits
    private let onTermination: ClairV2AgentTerminationHandler
    private var handle: clair_pty_handle?
    private var started = false
    private var running = false
    private var pendingCleanup = false
    private var cleanupWasIssued = false
    private var requested = false
    private var forced = false
    private var input = Data()
    private var inputFailed = false
    private var exitValue: ClairV2AgentProcessExit?
    private var size: ClairV2TerminalSize

    init(
      spec: ClairV2AgentLaunchSpec, limits: ClairV2TerminalLimits, size: ClairV2TerminalSize,
      onTermination: @escaping ClairV2AgentTerminationHandler
    ) throws {
      self.spec = spec
      self.limits = limits
      self.size = size
      self.onTermination = onTermination
      self.terminalJournal = try ClairV2TerminalJournal(capacity: limits.journalBytes)
      let descriptor =
        spec.workingDirectoryDescriptor.map { fcntl($0, F_DUPFD_CLOEXEC, 3) }
        ?? Darwin.open(
          spec.workingDirectoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else {
        throw ClairV2AgentError.workingDirectoryDescriptorUnavailable(spec.workingDirectoryURL)
      }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
        Darwin.close(descriptor)
        throw ClairV2AgentError.workingDirectoryChanged(spec.workingDirectoryURL)
      }
      self.cwd = descriptor
      self.device = spec.workingDirectoryDevice ?? UInt64(info.st_dev)
      self.inode = spec.workingDirectoryInode ?? UInt64(info.st_ino)
    }

    deinit { Darwin.close(cwd) }
    var processID: Int32 { lock.withLock { handle?.provider_pid ?? 0 } }
    var isRunning: Bool { lock.withLock { running } }
    var hasPendingCleanup: Bool { lock.withLock { pendingCleanup } }
    var terminalSize: ClairV2TerminalSize { lock.withLock { size } }

    func start() throws -> ClairV2AgentProcessStartOutcome {
      try lock.withLock {
        guard !started else { throw ClairV2AgentError.processAlreadyStarted }
        started = true
        var held = stat()
        var path = stat()
        guard fstat(cwd, &held) == 0, lstat(spec.workingDirectoryURL.path, &path) == 0,
          held.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          path.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          UInt64(held.st_dev) == device, UInt64(held.st_ino) == inode,
          UInt64(path.st_dev) == device, UInt64(path.st_ino) == inode
        else { throw ClairV2AgentError.workingDirectoryChanged(spec.workingDirectoryURL) }
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
          throw ClairV2AgentError.processLaunchFailed
        }
        handle = spawned
        running = true
        pendingCleanup = false
        let owned = spawned
        DispatchQueue.global(qos: .utility).async { [self] in pump(owned) }
      }
      return .running
    }

    func enqueueTerminalInput(_ bytes: Data) -> ClairV2TerminalCommitOutcome {
      lock.withLock {
        guard running, exitValue == nil, !inputFailed, !requested,
          !bytes.isEmpty, bytes.count <= ClairV2TerminalFrame.maximumPayloadBytes,
          bytes.count <= limits.inputBytes - input.count
        else { return .rejected }
        input.append(bytes)
        return .queued
      }
    }

    func commitTerminalSignal(_ signal: Int32) -> ClairV2TerminalCommitOutcome {
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
        if signal == SIGKILL { forced = true }
        return .queued
      }
    }

    func resizeTerminal(_ newSize: ClairV2TerminalSize) throws {
      try lock.withLock {
        guard running, !requested, let handle else { throw ClairV2TerminalError.closed }
        guard clair_pty_resize(handle.master_fd, newSize.rows, newSize.columns) == 0 else {
          throw ClairV2TerminalError.ioFailure
        }
        size = newSize
      }
    }

    func send(signal: ClairV2AgentSignal) async throws {
      guard commitTerminalSignal(signal.rawValue) == .queued else {
        throw ClairV2AgentError.signalFailed
      }
    }

    func terminate(gracePeriod: TimeInterval) async throws -> ClairV2AgentProcessExit {
      if let completed = completedExit() { return completed }
      _ = commitTerminalSignal(SIGTERM)
      if let value = await awaitExit(seconds: max(0, min(30, gracePeriod))) { return value }
      return try await forceTerminate()
    }

    func forceTerminate() async throws -> ClairV2AgentProcessExit {
      if let completed = completedExit() { return completed }
      _ = commitTerminalSignal(SIGKILL)
      if let value = await awaitExit(seconds: 2) { return value }
      throw ClairV2AgentError.processTerminationFailed
    }

    func rawOutput() async -> ClairV2AgentRawOutput {
      // Compatibility with H04; the live raw path uses the cursor journal.
      let state = terminalJournal.snapshot()
      let cursor = ClairV2TerminalCursor(epoch: state.epoch, offset: state.retainedStart)
      let frame = try? terminalJournal.read(from: cursor)
      return ClairV2AgentRawOutput(
        stdout: frame?.bytes ?? Data(),
        isTruncated: state.historyTruncated || state.endOffset - state.retainedStart > 65_536)
    }

    private func completedExit() -> ClairV2AgentProcessExit? {
      lock.withLock {
        if handle == nil { return ClairV2AgentProcessExit(didLaunch: false) }
        if pendingCleanup, cleanupWasIssued, let handle, exitValue != nil, !running {
          // Never signal a numeric PGID after reaping its owner. A retry only
          // probes disappearance; an ambiguous result retains the fence.
          if Darwin.kill(-handle.supervisor_pid, 0) < 0 && errno == ESRCH { pendingCleanup = false }
        }
        return pendingCleanup ? nil : exitValue
      }
    }

    private func awaitExit(seconds: TimeInterval) async -> ClairV2AgentProcessExit? {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(seconds))
      repeat {
        if let value = completedExit() { return value }
        // Cleanup must still yield and progress if its caller was cancelled.
        await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(10)) {
            continuation.resume()
          }
        }
      } while clock.now < deadline
      return completedExit()
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
          // A stolen/missing wait record cannot establish process ownership.
          finish(owned, supervisorStatus: 0, report: nil, outputFailed: true)
          return
        }
      }
      outputFailed = drain(owned.master_fd, buffer: &buffer) || outputFailed
      var report = clair_pty_exit()
      let count = Darwin.read(owned.status_fd, &report, MemoryLayout<clair_pty_exit>.size)
      finish(
        owned, supervisorStatus: supervisorStatus,
        report: count == MemoryLayout<clair_pty_exit>.size ? report : nil,
        outputFailed: outputFailed)
    }

    private func finish(
      _ owned: clair_pty_handle, supervisorStatus: Int32, report: clair_pty_exit?,
      outputFailed: Bool
    ) {
      let validReport = report?.error == 0
      let status = report?.wait_status ?? 0
      let signal = status & 0x7f
      let exit: ClairV2AgentProcessExit = lock.withLock {
        let value = ClairV2AgentProcessExit(
          status: signal == 0 && validReport ? (status >> 8) & 0xff : nil,
          signal: signal != 0 && validReport ? signal : (validReport ? nil : SIGKILL),
          wasRequestedByClair: requested, wasForceTerminated: forced)
        running = false
        // SIGKILL is the supervisor's normal, deliberate group cleanup exit.
        cleanupWasIssued = validReport && (supervisorStatus & 0x7f) == SIGKILL
        pendingCleanup = !cleanupWasIssued
        if !pendingCleanup {
          pendingCleanup = Darwin.kill(-owned.supervisor_pid, 0) == 0 || errno != ESRCH
        }
        exitValue = value
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
      // A bounded turn prevents an indefinitely noisy provider starving input
      // and reaping. On final EOF the same loop drains the finite kernel buffer.
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
          throw ClairV2AgentError.processCreationFailed
        }
        result.append(pointer)
      }
      return result
    }
  }
#endif

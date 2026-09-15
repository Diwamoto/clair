import Foundation
import Testing

@testable import ClairV2Agent
@testable import ClairV2DaemonKit
@testable import ClairV2Push
@testable import ClairV2Shared
@testable import ClairV2Terminal
@testable import ClairV2Transport
@testable import ClairV2Workspace

#if os(macOS)
  import Darwin
  import ClairV2PTY
#endif

@Suite(.serialized)
struct ClairV2TerminalTests {
  @Test func t02BinaryFramesAndBounds() throws {
    let bytes = Data([0, 255, 27, 91, 1, 128])
    let cursor = ClairV2TerminalCursor(epoch: try SessionEpoch(17), offset: 42)
    let frame = try ClairV2TerminalFrame(cursor: cursor, bytes: bytes)
    #expect(try ClairV2TerminalFrame.decode(frame.encoded()) == frame)
    #expect(try frame.encoded().suffix(bytes.count) == bytes)
    #expect(throws: (any Error).self) {
      try ClairV2TerminalFrame.decode(Data(frame.encoded().dropLast()))
    }
    #expect(throws: (any Error).self) {
      try ClairV2TerminalFrame.decode(frame.encoded() + Data([0]))
    }
    #expect(throws: (any Error).self) {
      try ClairV2TerminalFrame(cursor: cursor, bytes: Data(repeating: 0, count: 65_537))
    }
    #expect(throws: (any Error).self) {
      try ClairV2TerminalFrame(
        cursor: ClairV2TerminalCursor(epoch: cursor.epoch, offset: UInt64.max), bytes: bytes)
    }
    #expect(!String(describing: frame).contains("255"))
  }

  @Test func t02JournalExposesGapsEpochMismatchAndExactByteOffsets() throws {
    let journal = try ClairV2TerminalJournal(capacity: 4, epoch: SessionEpoch(3))
    try journal.append(Data([1, 2, 3]))
    try journal.append(Data([4, 5, 6]))
    let state = journal.snapshot()
    #expect(state.retainedStart == 2 && state.endOffset == 6 && state.historyTruncated)
    #expect(throws: ClairV2TerminalError.gap(availableOffset: 2)) {
      try journal.read(from: ClairV2TerminalCursor(epoch: journal.epoch, offset: 0))
    }
    #expect(throws: ClairV2TerminalError.staleEpoch) {
      try journal.read(from: ClairV2TerminalCursor(epoch: SessionEpoch(4), offset: 2))
    }
    #expect(throws: ClairV2TerminalError.invalidCursor) {
      try journal.read(from: ClairV2TerminalCursor(epoch: journal.epoch, offset: 7))
    }
    let frame = try #require(
      try journal.read(from: ClairV2TerminalCursor(epoch: journal.epoch, offset: 2)))
    #expect(frame.bytes == Data([3, 4, 5, 6]))
    #expect(frame.nextCursor.offset == 6)
    journal.finish(inputIsUncertain: true)
    #expect(journal.snapshot().inputIsUncertain && journal.snapshot().isClosed)
    #expect(throws: ClairV2TerminalError.closed) { try journal.append(Data([7])) }
  }

  #if os(macOS)
    @Test func t02PTYHasControllingTerminalAndRawBinaryInputOutput() async throws {
      let process = try nativeProcess(
        "test -t 0 && test -t 1 && test -t 2 && test -r /dev/tty || exit 91; stty raw -echo; printf READY; dd bs=1 count=4 2>/dev/null; printf '\\377\\000'; printf ERR >&2"
      )
      _ = try process.start()
      let ready = await until { output(process).starts(with: Data("READY".utf8)) }
      #expect(ready)
      let payload = Data([0, 255, 10, 128])
      #expect(process.enqueueTerminalInput(payload) == .queued)
      let exited = await until { !process.isRunning }
      #expect(exited)
      let exit = try await process.forceTerminate()
      #expect(exit.status == 0 && !process.hasPendingCleanup)
      #expect(output(process) == Data("READY".utf8) + payload + Data([255, 0]) + Data("ERR".utf8))
      #expect(process.terminalJournal.snapshot().isClosed)
      #expect(process.enqueueTerminalInput(payload) == .rejected)
    }

    @Test func t02PTYStopEscalatesAndReapsDescendants() async throws {
      let process = try nativeProcess("trap '' TERM; sleep 300 & printf '%s\\n' $!; wait")
      _ = try process.start()
      let ready = await until { output(process).contains(10) }
      #expect(ready)
      let child = try #require(
        Int32(
          String(decoding: output(process), as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)))
      let provider = process.processID
      let exit = try await process.terminate(gracePeriod: 0.05)
      #expect(exit.wasForceTerminated && exit.wasRequestedByClair)
      let cleaned = await until { Darwin.kill(child, 0) < 0 && Darwin.kill(provider, 0) < 0 }
      #expect(cleaned && !process.hasPendingCleanup)
    }

    @Test func t02PTYExecFailureAndAbnormalExitAreTyped() async throws {
      let invalid = try nativeProcess("", executable: "/does-not-exist/clair-t02")
      #expect(throws: ClairV2AgentError.processLaunchFailed) { try invalid.start() }
      let failed = try await invalid.forceTerminate()
      #expect(!failed.didLaunch && !invalid.hasPendingCleanup)
      let process = try nativeProcess("exit 17")
      _ = try process.start()
      let exited = await until { !process.isRunning }
      #expect(exited)
      let exit = try await process.forceTerminate()
      #expect(exit.status == 17 && !exit.wasRequestedByClair)
    }

    @Test func t02PTYInputBackpressureIsBounded() async throws {
      let process = try nativeProcess(
        "sleep 300", limits: ClairV2TerminalLimits(journalBytes: 64, inputBytes: 4))
      _ = try process.start()
      #expect(process.enqueueTerminalInput(Data(repeating: 1, count: 5)) == .rejected)
      _ = try await process.forceTerminate()
      #expect(!process.isRunning && !process.hasPendingCleanup)
    }

    @Test func t02UndrainedInputIsUncertainOnExit() async throws {
      let process = try nativeProcess("stty raw -echo; printf READY; sleep 300")
      _ = try process.start()
      let ready = await until { output(process).starts(with: Data("READY".utf8)) }
      #expect(ready)
      #expect(process.enqueueTerminalInput(Data(repeating: 1, count: 65_536)) == .queued)
      _ = try await process.forceTerminate()
      #expect(process.terminalJournal.snapshot().inputIsUncertain)
    }

    @Test func t02PTYDoesNotInheritOtherDaemonDescriptors() async throws {
      let original = Darwin.open("/dev/null", O_RDONLY)
      let descriptor = Darwin.fcntl(original, F_DUPFD, 500)
      Darwin.close(original)
      defer { Darwin.close(descriptor) }
      #expect(descriptor >= 500)
      let process = try nativeProcess("test ! -e /dev/fd/\(descriptor)")
      _ = try process.start()
      let exited = await until { !process.isRunning }
      #expect(exited)
      #expect(try await process.forceTerminate().status == 0)
    }

    @Test func t02SupervisorControlEOFReapsProviderAfterDaemonDeath() async throws {
      let cwd = Darwin.open("/", O_RDONLY | O_DIRECTORY)
      defer { Darwin.close(cwd) }
      var strings: [UnsafeMutablePointer<CChar>?] = [
        "/bin/sh", "-c", "trap '' HUP TERM; sleep 300 & wait",
      ].map { (value: String) in value.withCString { strdup($0) } }
      defer { for pointer in strings { free(pointer) } }
      strings.append(nil)
      var environment: [UnsafeMutablePointer<CChar>?] = [nil]
      var handle = clair_pty_handle()
      let spawned = strings.withUnsafeMutableBufferPointer { a in
        environment.withUnsafeMutableBufferPointer { e in
          clair_pty_spawn("/bin/sh", a.baseAddress, e.baseAddress, cwd, 24, 80, &handle)
        }
      }
      #expect(spawned == 0)
      guard spawned == 0 else { return }
      Darwin.close(handle.control_fd)
      defer {
        Darwin.close(handle.master_fd)
        Darwin.close(handle.status_fd)
      }
      var status: Int32 = 0
      let exited = await until {
        Darwin.waitpid(handle.supervisor_pid, &status, WNOHANG) == handle.supervisor_pid
      }
      #expect(exited && (status & 0x7f) == SIGKILL)
      var report = clair_pty_exit()
      #expect(
        Darwin.read(handle.status_fd, &report, MemoryLayout<clair_pty_exit>.size)
          == MemoryLayout<clair_pty_exit>.size)
      #expect(report.error == 0)
      let cleaned = await until {
        Darwin.kill(handle.provider_pid, 0) < 0 && Darwin.kill(-handle.supervisor_pid, 0) < 0
      }
      #expect(cleaned)
    }

    @Test func t02SupervisorFailureRemainsCleanupPending() async throws {
      let process = try nativeProcess("trap '' HUP TERM; printf READY; sleep 300 & wait")
      _ = try process.start()
      let ready = await until { output(process).starts(with: Data("READY".utf8)) }
      #expect(ready)
      let provider = process.processID
      let supervisor = Darwin.getpgid(provider)
      #expect(supervisor > 0 && supervisor != provider)
      // Inject supervisor failure, then clean this test's known live group.
      // The production handle must not claim that this external cleanup was
      // its own proven reaping result, even after the group disappears.
      Darwin.kill(supervisor, SIGKILL)
      let observed = await until { !process.isRunning }
      #expect(observed && process.hasPendingCleanup)
      Darwin.kill(-supervisor, SIGKILL)
      let cleaned = await until { Darwin.kill(provider, 0) < 0 }
      #expect(cleaned)
      await #expect(throws: ClairV2AgentError.processTerminationFailed) {
        try await process.forceTerminate()
      }
      #expect(process.hasPendingCleanup && process.terminalJournal.snapshot().outputFailed)
    }

    private func nativeProcess(
      _ command: String, executable: String = "/bin/sh",
      limits: ClairV2TerminalLimits = .standard
    ) throws -> ClairV2PTYAgentProcess {
      let spec = try ClairV2AgentLaunchSpec(
        executableURL: URL(fileURLWithPath: executable),
        arguments: ["-c", command],
        environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
        workingDirectoryURL: URL(fileURLWithPath: "/"))
      return try #require(
        ClairV2PTYAgentProcessFactory(terminalLimits: limits).makeProcess(
          spec: spec, onTermination: { _ in }) as? ClairV2PTYAgentProcess)
    }

    private func output(_ process: ClairV2PTYAgentProcess) -> Data {
      let state = process.terminalJournal.snapshot()
      return
        (try? process.terminalJournal.read(
          from: ClairV2TerminalCursor(epoch: state.epoch, offset: state.retainedStart)))?.bytes
        ?? Data()
    }
  #endif
}

private func until(_ predicate: () async throws -> Bool) async rethrows -> Bool {
  for _ in 0..<300 {
    if try await predicate() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return false
}

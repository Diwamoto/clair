import Foundation
import Testing

@testable import ClairAppKit
@testable import ClairTerminal

#if os(macOS)
  @Suite(.serialized)
  struct ClairLocalShellSessionTests {
    @Test func t03LocalShellRunsARealPTYAndReportsPromptedOutput() async throws {
      let (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
      let session = try ClairLocalShellSession(
        spec: ClairLocalShellSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "stty raw -echo; printf READY; read -r line; printf '<%s>' \"$line\""],
          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
          workingDirectoryURL: FileManager.default.temporaryDirectory
        ),
        size: try ClairTerminalSize(rows: 24, columns: 80),
        onTermination: { _ in exitContinuation.finish() }
      )
      try session.start()
      #expect(try await waitForJournal(session, until: "READY"))
      try session.write(Data("hello\n".utf8))
      #expect(try await waitForJournal(session, until: "<hello>"))
      session.terminate()
      var iterator = exitStream.makeAsyncIterator()
      _ = await iterator.next()
      #expect(!session.isRunning)
    }

    @Test func t03LocalShellResizeReachesTheRealPTYGeometry() async throws {
      let session = try ClairLocalShellSession(
        spec: ClairLocalShellSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "stty raw -echo; printf READY; read -r line; stty size"],
          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
          workingDirectoryURL: FileManager.default.temporaryDirectory
        ),
        size: try ClairTerminalSize(rows: 24, columns: 80)
      )
      try session.start()
      #expect(try await waitForJournal(session, until: "READY"))
      try session.resizeTerminal(ClairTerminalSize(rows: 40, columns: 120))
      #expect(session.terminalSize == (try ClairTerminalSize(rows: 40, columns: 120)))
      try session.write(Data("go\n".utf8))
      #expect(try await waitForJournal(session, until: "40 120"))
      session.terminate()
    }

    @Test func t03LocalShellRejectsInputAfterExit() async throws {
      let (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
      let session = try ClairLocalShellSession(
        spec: ClairLocalShellSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "exit 0"],
          environment: ["PATH": "/usr/bin:/bin"],
          workingDirectoryURL: FileManager.default.temporaryDirectory
        ),
        onTermination: { _ in exitContinuation.finish() }
      )
      try session.start()
      var iterator = exitStream.makeAsyncIterator()
      _ = await iterator.next()
      #expect(!session.isRunning)
      #expect(session.enqueueTerminalInput(Data("x".utf8)) == .rejected)
      #expect(session.terminalJournal.snapshot().isClosed)
    }

    @Test func t03LoginShellSpecResolvesFromEnvironmentAndFallsBackToZsh() {
      let withShell = ClairLocalShellSpec.loginShell()
      #expect(!withShell.executableURL.path.isEmpty)
      #expect(withShell.environment["TERM"] != nil)
    }

    private func waitForJournal(
      _ session: ClairLocalShellSession, until needle: String
    ) async throws -> Bool {
      var cursor = ClairTerminalCursor(
        epoch: session.terminalJournal.epoch,
        offset: session.terminalJournal.snapshot().retainedStart)
      var collected = Data()
      for _ in 0..<500 {
        if let frame = try session.terminalJournal.read(from: cursor) {
          collected.append(frame.bytes)
          cursor = frame.nextCursor
          if collected.range(of: Data(needle.utf8)) != nil { return true }
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      return false
    }
  }
#endif

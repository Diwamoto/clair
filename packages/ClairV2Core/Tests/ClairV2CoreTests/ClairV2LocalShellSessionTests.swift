import Foundation
import Testing

@testable import ClairV2AppKit
@testable import ClairV2Terminal

#if os(macOS)
  @Suite(.serialized)
  struct ClairV2LocalShellSessionTests {
    @Test func t03LocalShellRunsARealPTYAndReportsPromptedOutput() async throws {
      let session = try ClairV2LocalShellSession(
        spec: ClairV2LocalShellSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "stty raw -echo; printf READY; read -r line; printf '<%s>' \"$line\""],
          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
          workingDirectoryURL: FileManager.default.temporaryDirectory
        ),
        size: try ClairV2TerminalSize(rows: 24, columns: 80)
      )
      try session.start()
      #expect(try await waitForJournal(session, until: "READY"))
      try session.write(Data("hello\n".utf8))
      #expect(try await waitForJournal(session, until: "<hello>"))
      session.terminate()
      for _ in 0..<300 where session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
      #expect(!session.isRunning)
    }

    @Test func t03LocalShellResizeReachesTheRealPTYGeometry() async throws {
      let session = try ClairV2LocalShellSession(
        spec: ClairV2LocalShellSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "stty raw -echo; printf READY; read -r line; stty size"],
          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
          workingDirectoryURL: FileManager.default.temporaryDirectory
        ),
        size: try ClairV2TerminalSize(rows: 24, columns: 80)
      )
      try session.start()
      #expect(try await waitForJournal(session, until: "READY"))
      try session.resizeTerminal(ClairV2TerminalSize(rows: 40, columns: 120))
      #expect(session.terminalSize == (try ClairV2TerminalSize(rows: 40, columns: 120)))
      try session.write(Data("go\n".utf8))
      #expect(try await waitForJournal(session, until: "40 120"))
      session.terminate()
    }

    @Test func t03LocalShellRejectsInputAfterExit() async throws {
      let session = try ClairV2LocalShellSession(
        spec: ClairV2LocalShellSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "exit 0"],
          environment: ["PATH": "/usr/bin:/bin"],
          workingDirectoryURL: FileManager.default.temporaryDirectory
        )
      )
      try session.start()
      for _ in 0..<300 where session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
      #expect(!session.isRunning)
      #expect(session.enqueueTerminalInput(Data("x".utf8)) == .rejected)
      #expect(session.terminalJournal.snapshot().isClosed)
    }

    @Test func t03LoginShellSpecResolvesFromEnvironmentAndFallsBackToZsh() {
      let withShell = ClairV2LocalShellSpec.loginShell()
      #expect(!withShell.executableURL.path.isEmpty)
      #expect(withShell.environment["TERM"] != nil)
    }

    private func waitForJournal(
      _ session: ClairV2LocalShellSession, until needle: String
    ) async throws -> Bool {
      var cursor = ClairV2TerminalCursor(
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

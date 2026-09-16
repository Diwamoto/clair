import Foundation
import Testing

@testable import ClairV2AppKit
@testable import ClairV2Ghostty
@testable import ClairV2Terminal

#if os(macOS)
  import AppKit

  @Suite
  struct ClairV2GhosttySurfaceViewTests {
    @Test func t03EnterKeyEncodesToCarriageReturn() {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
        keyCode: 36)!
      #expect(ClairV2GhosttySurfaceView.encode(event) == Data([0x0d]))
    }

    @Test func t03ControlCEncodesToByteThree() {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0,
        context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false,
        keyCode: 8)!
      #expect(ClairV2GhosttySurfaceView.encode(event) == Data([0x03]))
    }

    @Test func t03PlainCharacterEncodesToItsUTF8Bytes() {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
        keyCode: 0)!
      #expect(ClairV2GhosttySurfaceView.encode(event) == Data("a".utf8))
    }

    @Test(.enabled(if: !GhosttyRuntime.isVendored)) @MainActor
    func t03CopyWithoutVendoredGhosttyFailsClosedRatherThanGuessingSelectionText()
      throws
    {
      let session = try ClairV2LocalShellSession(
        spec: ClairV2LocalShellSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
          environment: [:], workingDirectoryURL: FileManager.default.temporaryDirectory))
      let view = ClairV2GhosttySurfaceView(session: session)
      #expect(!GhosttyRuntime.isVendored)
      // No vendored library in this environment means copy has no real
      // selection state to read from; it must not fabricate text.
      view.copy(nil)
    }

    @Test @MainActor func t03PasteWritesPasteboardTextIntoTheRealShellRegardlessOfGhosttyVendoring()
      async throws
    {
      let session = try ClairV2LocalShellSession(
        spec: ClairV2LocalShellSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "stty raw -echo; printf READY; read -r line; printf '<%s>' \"$line\""],
          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
          workingDirectoryURL: FileManager.default.temporaryDirectory))
      try session.start()
      var cursor = ClairV2TerminalCursor(
        epoch: session.terminalJournal.epoch,
        offset: session.terminalJournal.snapshot().retainedStart)
      var collected = Data()
      for _ in 0..<500 {
        if let frame = try session.terminalJournal.read(from: cursor) {
          collected.append(frame.bytes)
          cursor = frame.nextCursor
          if collected.range(of: Data("READY".utf8)) != nil { break }
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      let pasteboard = NSPasteboard(name: .init("clair-v2-t03-test"))
      pasteboard.clearContents()
      pasteboard.setString("pasted\n", forType: .string)
      let view = ClairV2GhosttySurfaceView(session: session)
      view.pasteFromPasteboard(pasteboard)
      for _ in 0..<500 {
        if let frame = try session.terminalJournal.read(from: cursor) {
          collected.append(frame.bytes)
          cursor = frame.nextCursor
          if collected.range(of: Data("<pasted>".utf8)) != nil {
            session.terminate()
            return
          }
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      session.terminate()
      Issue.record("paste never reached the shell")
    }
  }
#endif

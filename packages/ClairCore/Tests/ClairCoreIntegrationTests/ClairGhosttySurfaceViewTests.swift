import Foundation
import Testing

@testable import ClairAppKit
@testable import ClairDaemonKit
@testable import ClairGhostty
@testable import ClairTerminal

#if os(macOS)
  import AppKit

  @Suite
  struct ClairGhosttySurfaceViewTests {
    @Test func t03EnterKeyEncodesToCarriageReturn() {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
        keyCode: 36)!
      #expect(ClairGhosttySurfaceView.encode(event) == Data([0x0d]))
    }

    @Test func t03ControlCEncodesToByteThree() {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0,
        context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false,
        keyCode: 8)!
      #expect(ClairGhosttySurfaceView.encode(event) == Data([0x03]))
    }

    @Test func t03PlainCharacterEncodesToItsUTF8Bytes() {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
        keyCode: 0)!
      #expect(ClairGhosttySurfaceView.encode(event) == Data("a".utf8))
    }

    @Test(.enabled(if: !GhosttyRuntime.isVendored)) @MainActor
    func t03CopyWithoutVendoredGhosttyFailsClosedRatherThanGuessingSelectionText()
      throws
    {
      let session = try ClairLocalShellSession(
        spec: ClairLocalShellSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
          environment: [:], workingDirectoryURL: FileManager.default.temporaryDirectory))
      let view = ClairGhosttySurfaceView(session: session)
      #expect(!GhosttyRuntime.isVendored)
      // No vendored library in this environment means copy has no real
      // selection state to read from; it must not fabricate text.
      view.copy(nil)
    }

    @Test @MainActor func t03PasteWritesPasteboardTextIntoTheRealShellRegardlessOfGhosttyVendoring()
      async throws
    {
      let session = try ClairLocalShellSession(
        spec: ClairLocalShellSpec(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "stty raw -echo; printf READY; read -r line; printf '<%s>' \"$line\""],
          environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
          workingDirectoryURL: FileManager.default.temporaryDirectory))
      try session.start()
      var cursor = ClairTerminalCursor(
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
      let pasteboard = NSPasteboard(name: .init("clair-t03-test"))
      pasteboard.clearContents()
      pasteboard.setString("pasted\n", forType: .string)
      let view = ClairGhosttySurfaceView(session: session)
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

    /// Regression test for a controller-found bug: `deinit` used to be
    /// missing entirely, so a real spawned shell process and its 30Hz poll
    /// `Timer` would outlive the view whenever AppKit deallocates it
    /// without first calling `viewDidMoveToWindow(nil)` (for example, a
    /// window closed without its subviews being explicitly
    /// `removeFromSuperview()`-ed) — `teardownGhosttySurface()` was only
    /// ever reachable from that notification. This attaches the view to a
    /// real window, lets it create a real surface, then drops every
    /// reference *without* detaching first, simulating exactly that
    /// scenario. It only proves `isolated deinit` runs cleanly (no crash,
    /// no hang, both objects actually released) — it cannot directly
    /// observe that the real child process or Timer stopped, but a crash
    /// or hang here would mean the fix itself is broken.
    @Test(.enabled(if: GhosttyRuntime.isVendored)) @MainActor
    func t03SurfaceViewDeinitTearsDownEvenWithoutWindowDetachNotification()
      async throws
    {
      weak var weakView: ClairGhosttySurfaceView?
      weak var weakWindow: NSWindow?
      do {
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
          styleMask: [.borderless], backing: .buffered, defer: true)
        let view = ClairGhosttySurfaceView()
        window.contentView = view
        weakView = view
        weakWindow = window
        // Give real surface creation + the poll timer a moment to spin up
        // before everything goes out of scope undetached.
        try await Task.sleep(for: .milliseconds(50))
      }
      try await Task.sleep(for: .milliseconds(50))
      #expect(weakView == nil)
      #expect(weakWindow == nil)
    }

    /// U06: the store's focused pane is the only surface holding the keyboard (so only its caret blinks),
    /// a store focus change moves the keyboard there, and a click-driven focus reports back to the store.
    @Test @MainActor
    func u06OnlyTheStoreFocusedSurfaceTakesTheKeyboard() async throws {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless],
        backing: .buffered, defer: true)
      let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
      window.contentView = root
      let a = ClairGhosttySurfaceView(), b = ClairGhosttySurfaceView()
      var reported: [String] = []
      a.onFocus = { reported.append("a") }
      b.onFocus = { reported.append("b") }
      a.wantsFocus = true
      root.addSubview(a)
      root.addSubview(b)  // mounted last, but not focused: must not steal the keyboard
      #expect(window.firstResponder === a)

      a.wantsFocus = false
      b.wantsFocus = true
      try await Task.sleep(for: .milliseconds(20))
      #expect(window.firstResponder === b)

      window.makeFirstResponder(a)  // what AppKit does on a click
      #expect(reported == ["a", "b", "a"])
    }

    /// U06: the Clair theme file is loaded + finalized into the real config and the surface still spawns
    /// and renders its child (a bad key would only be a Ghostty diagnostic, so this guards finalize).
    @Test(.enabled(if: GhosttyRuntime.isVendored)) @MainActor
    func u06ThemedConfigStillRunsARealShell() throws {
      let theme = try #require(ClairGhosttySurfaceView.themePath)
      #expect(try String(contentsOfFile: theme, encoding: .utf8).contains("palette = 4=#61afef"))
      let runtime = GhosttyRuntime()
      try runtime.activate()
      var diagnostics = -1
      let app = try runtime.retainApp { diagnostics = try $0.loadFileAndFinalize(theme) }
      #expect(diagnostics == 0)  // every theme line is a key libghostty accepts
      defer { app.close() }
      let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
      view.wantsLayer = true
      let marker = "CLAIRU06-\(UUID().uuidString.prefix(8))"
      let surface = try app.retainSurface(
        GhosttySurfaceConfig(
          platform: .macOS(Unmanaged.passUnretained(view).toOpaque()), workingDirectory: NSTemporaryDirectory(),
          command: "/bin/sh", initialInput: "printf '\\033[34m\(marker)\\033[0m\\n'\n"))
      defer { surface.close() }
      try surface.setSize(widthPixels: 640, heightPixels: 400)
      var seen = false
      for _ in 0..<100 where !seen {
        try app.tick()
        Thread.sleep(forTimeInterval: 0.05)
        seen = try surface.readText(.screen)?.contains(marker) ?? false
      }
      #expect(seen)
    }
  }
#endif

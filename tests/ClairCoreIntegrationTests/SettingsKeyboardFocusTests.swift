#if os(macOS)
  import AppKit
  import SwiftUI
  import XCTest
  import ClairEditorView
  import ClairWorkspace

  @testable import ClairAppKit

  /// Settings only covers the workbench. Its editor kept first responder, so Esc never reached the ✕ button's
  /// cancelAction (and typing went into the hidden file). Renders the real shell, so it lives with the slow tests.
  @MainActor final class SettingsKeyboardFocusTests: XCTestCase {
    func testEscClosesSettingsAndTheEditorGetsTheKeyboardBack() throws {
      setenv("CLAIR_CHANNEL", "dev", 1)
      let base = FileManager.default.temporaryDirectory.appendingPathComponent("settings-esc-\(UUID())/clair").path
      try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(atPath: (base as NSString).deletingLastPathComponent) }
      try "let a = 1\n".write(toFile: base + "/a.swift", atomically: true, encoding: .utf8)
      let store = ClairWorkbenchStore(persistAt: nil)
      store.run("project.open", ["path": .string(base)])
      RunLoop.current.run(until: Date().addingTimeInterval(1.5))  // the file scan is async
      XCTAssertNoThrow(try store.run("tab.open", ["path": .string("a.swift")]).get())
      let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
      win.contentView = NSHostingView(rootView: ClairAppShell(store: store).frame(width: 1440, height: 900))
      win.orderBack(nil)
      defer { win.orderOut(nil) }
      RunLoop.current.run(until: Date().addingTimeInterval(2))
      XCTAssertTrue(win.firstResponder is ClairEditorView)

      // A settings change rebuilds the editor (new font); the rebuilt one must not take the keyboard back either.
      for change in [{}, { store.run("settings.choose", ["key": .string("editorFontSize"), "value": .string("14")]) }] as [() -> Void] {
        store.run("settings.open", ["section": .string("エディタ")])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        change()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          win.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(store.state.settingsOpen, "Esc closes settings")
        XCTAssertTrue(win.firstResponder is ClairEditorView, "the focused pane gets the keyboard back")
      }
    }
  }
#endif

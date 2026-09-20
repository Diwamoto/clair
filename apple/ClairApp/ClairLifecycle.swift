import AppKit
import Foundation

enum ClairTerminationReason: Equatable, Sendable {
  case userQuit
  case updateRestart
}

enum ClairKeyboardShortcutAction: String, Sendable {
  case quickOpen
  case commandPalette
  case find
  case replace
  case goToLine
  case toggleSidebar
  case toggleTerminal
  case splitEditor
  case previousTab
  case nextTab
  case focusGroup
  case showExplorer
  case showSearch
  case showSourceControl
  case toggleWordWrap
  case saveAll
  case zoomIn
  case zoomOut
  case resetZoom
  case openSettings
  case copyActiveFilePath
  case revealActiveFile
}

@MainActor
final class ClairApplicationDelegate: NSObject, NSApplicationDelegate {
  private(set) var terminationReason: ClairTerminationReason = .userQuit
  var onNormalTermination: (() -> Void)?
  private var keyboardEventMonitor: Any?

  /// Detect whether the app was launched as an XCTest host. When running under
  /// `xcodebuild test`, Xcode sets this environment variable to the generated
  /// test configuration file.
  private var isRunningTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  func prepareForUpdateRestart() {
    terminationReason = .updateRestart
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    installKeyboardEventMonitor()

    guard isRunningTests else { return }
    // Hide the app from Dock and menu bar while acting as a test host. The
    // tests run in-process and do not need a visible main window.
    NSApp.setActivationPolicy(.prohibited)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    disableWindowCloseShortcut()
    DispatchQueue.main.async { [weak self] in
      self?.disableWindowCloseShortcut()
    }

    guard isRunningTests else { return }
    // SwiftUI may have created an initial window before the activation policy
    // change took effect; remove it from the screen without terminating.
    for window in NSApp.windows {
      window.orderOut(nil)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Closing the workspace window must not stop the local mobile host or
    // terminate agent-backed PTYs. A user-initiated Quit still flows through
    // applicationShouldTerminate and performs the normal cleanup.
    false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationReason == .userQuit {
      onNormalTermination?()
    }
    return .terminateNow
  }

  func disableWindowCloseShortcut() {
    guard let mainMenu = NSApp.mainMenu else { return }

    let closeWindowSelector = #selector(NSWindow.performClose(_:))
    func visit(_ menu: NSMenu) {
      for item in menu.items {
        let actionName = item.action.map { NSStringFromSelector($0) }
        if item.action == closeWindowSelector || actionName == "performClose:" {
          item.keyEquivalent = ""
          item.keyEquivalentModifierMask = []
        }
        if let submenu = item.submenu {
          visit(submenu)
        }
      }
    }

    visit(mainMenu)
  }

  private func installKeyboardEventMonitor() {
    guard keyboardEventMonitor == nil else { return }

    keyboardEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      let key = event.charactersIgnoringModifiers?.lowercased()

      if modifiers == [.command], key == "w" {
        NotificationCenter.default.post(
          name: .clairRequestCloseActiveTab,
          object: nil
        )
        return nil
      }

      // Keep the workspace window from acquiring another close shortcut. The
      // app-level Quit command remains available through the standard ⌘Q.
      if modifiers == [.command, .shift], key == "w" {
        return nil
      }

      guard
        let action = Self.keyboardShortcutAction(
          for: event,
          modifiers: modifiers,
          key: key
        )
      else {
        return event
      }

      var userInfo: [String: String] = [
        "action": action.rawValue
      ]
      if action == .focusGroup, let key {
        userInfo["value"] = key
      }
      NotificationCenter.default.post(
        name: .clairKeyboardShortcut,
        object: nil,
        userInfo: userInfo
      )
      return nil
    }
  }

  private static func keyboardShortcutAction(
    for event: NSEvent,
    modifiers: NSEvent.ModifierFlags,
    key: String?
  ) -> ClairKeyboardShortcutAction? {
    if modifiers == [.control, .shift], event.keyCode == 48 {
      return .previousTab
    }
    if modifiers == [.control], event.keyCode == 48 {
      return .nextTab
    }
    if modifiers == [.control, .shift], event.keyCode == 116 {
      return .previousTab
    }
    if modifiers == [.control], event.keyCode == 121 {
      return .nextTab
    }

    switch (modifiers, key) {
    case ([.command], "p"):
      return .quickOpen
    case ([.command, .shift], "p"):
      return .commandPalette
    case ([.command], "f"):
      return .find
    case ([.command, .option], "f"):
      return .replace
    case ([.control], "g"):
      return .goToLine
    case ([.command], "b"):
      return .toggleSidebar
    case ([.control], "`"):
      return .toggleTerminal
    case ([.command], "\\"):
      return .splitEditor
    case ([.command, .shift], "["):
      return .previousTab
    case ([.command, .shift], "]"):
      return .nextTab
    case ([.command, .shift], "e"):
      return .showExplorer
    case ([.command, .shift], "f"):
      return .showSearch
    case ([.control, .shift], "g"):
      return .showSourceControl
    case ([.option], "z"):
      return .toggleWordWrap
    case ([.command, .option], "s"):
      return .saveAll
    case ([.command], "="):
      return .zoomIn
    case ([.command], "-"):
      return .zoomOut
    case ([.command], "0"):
      return .resetZoom
    case ([.command], ","):
      return .openSettings
    case ([.command, .option], "p"):
      return .copyActiveFilePath
    case ([.command, .option], "r"):
      return .revealActiveFile
    case ([.command], "1"), ([.command], "2"), ([.command], "3"),
      ([.command], "4"), ([.command], "5"), ([.command], "6"),
      ([.command], "7"), ([.command], "8"), ([.command], "9"):
      return .focusGroup
    default:
      return nil
    }
  }
}

extension Notification.Name {
  static let clairRequestCloseActiveTab = Notification.Name(
    "Clair.requestCloseActiveTab"
  )
  static let clairKeyboardShortcut = Notification.Name(
    "Clair.keyboardShortcut"
  )
}

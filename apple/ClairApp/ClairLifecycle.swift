import AppKit
import Foundation

enum ClairTerminationReason: Equatable, Sendable {
  case userQuit
  case updateRestart
}

@MainActor
final class ClairApplicationDelegate: NSObject, NSApplicationDelegate {
  private(set) var terminationReason: ClairTerminationReason = .userQuit
  var onNormalTermination: (() -> Void)?

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
    guard isRunningTests else { return }
    // Hide the app from Dock and menu bar while acting as a test host. The
    // tests run in-process and do not need a visible main window.
    NSApp.setActivationPolicy(.prohibited)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
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
}

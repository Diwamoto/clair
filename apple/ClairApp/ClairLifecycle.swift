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

  func prepareForUpdateRestart() {
    terminationReason = .updateRestart
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationReason == .userQuit {
      onNormalTermination?()
    }
    return .terminateNow
  }
}

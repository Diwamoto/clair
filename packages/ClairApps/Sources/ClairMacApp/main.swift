import AppKit
import ClairAppKit
import SwiftUI

/// A bare executable (`make dev`, `swift run`) is not a bundled app, so macOS starts it as a background process:
/// no Dock icon, no key window, and clicks never bring the window forward. Opt in to being a regular app.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}

@main
struct ClairMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup("Clair") {
      ClairAppShell()
    }
    .commands { ClairCommandMenu() }
    WindowGroup("Pair a device", id: "clair-pairing") {
      ClairPairingBootstrapView()
    }
  }
}

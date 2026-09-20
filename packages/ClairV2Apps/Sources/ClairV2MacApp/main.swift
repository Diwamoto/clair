import AppKit
import ClairV2AppKit
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
struct ClairV2MacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup("Clair v2") {
      ClairV2AppShell()
    }
    .commands { ClairV2CommandMenu() }
    WindowGroup("Pair a device", id: "clair-v2-pairing") {
      ClairV2PairingBootstrapView()
    }
  }
}

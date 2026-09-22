import AppKit
import ClairAppKit
import ClairDesignSystem
import SwiftUI

/// A bare executable (`make dev`, `swift run`) is not a bundled app, so macOS starts it as a background process:
/// no Dock icon, no key window, and clicks never bring the window forward. Opt in to being a regular app.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    ClairStartupTrace.armIfRequested()  // BUDGET-START-HALFBOUNCE; no-op without CLAIR_STARTUP_TRACE
    // Daemon health uses IPC and can wait on a stale socket. The first window never depends on it;
    // terminal attachment already waits for the daemon when a terminal is actually opened.
    Task.detached(priority: .utility) { ClairDaemonLauncher.ensureRunning() }
    // The native lights are laid out for a 28pt bar; centre them in our ChromeBudget.titlebar-tall chrome.
    // Re-applied because AppKit resets their frames on resize / full screen.
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(layoutWindow(_:)), name: name, object: nil)
    }
  }

  private var lightsX: [CGFloat]?

  @objc private func layoutWindow(_ notification: Notification) {
    guard let w = notification.object as? NSWindow, let close = w.standardWindowButton(.closeButton), let bar = close.superview?.superview else { return }
    let h = ChromeBudget.titlebar
    bar.setFrameSize(NSSize(width: bar.frame.width, height: h))
    bar.setFrameOrigin(NSPoint(x: 0, y: w.frame.height - h))
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
    if lightsX == nil { lightsX = buttons.map { $0.frame.origin.x + 5 } }  // AppKit's own x, inset 5pt; absolute so re-layout never accumulates
    for (b, x) in zip(buttons, lightsX ?? []) {
      b.setFrameOrigin(NSPoint(x: x, y: (h - b.frame.height) / 2))
    }
  }

  /// Spec §7: closing a window keeps the daemon; an explicit Clair quit stops it and its shells.
  func applicationWillTerminate(_ notification: Notification) {
    ClairDaemonLauncher.shutdown()
  }
}

@main
struct ClairMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup("Clair") {
      ClairAppShell().ignoresSafeArea(.container, edges: .top)  // content runs under the (hidden) titlebar; no second band above ours
    }
    .windowStyle(.hiddenTitleBar)  // U04: one chrome — the app titlebar hosts the real traffic lights
    .commands { ClairCommandMenu() }
    WindowGroup("Pair a device", id: "clair-pairing") {
      ClairPairingBootstrapView()
    }
  }
}

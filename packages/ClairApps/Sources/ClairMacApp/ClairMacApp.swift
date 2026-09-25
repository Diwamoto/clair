import AppKit
import ClairAppKit
import ClairDesignSystem
import ClairWorkspace
import SwiftUI

/// A bare executable (`make dev`, `swift run`) is not a bundled app, so macOS starts it as a background process:
/// no Dock icon, no key window, and clicks never bring the window forward. Opt in to being a regular app.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.applicationIconImage = Self.appIcon()
    NSApp.activate(ignoringOtherApps: true)
    ClairStartupTrace.armIfRequested()  // BUDGET-START-HALFBOUNCE; no-op without CLAIR_STARTUP_TRACE
    // Daemon health uses IPC and can wait on a stale socket. The first window never depends on it;
    // terminal attachment already waits for the daemon when a terminal is actually opened.
    Task.detached(priority: .utility) { ClairDaemonLauncher.ensureRunning() }
    // Past chats scan every provider file; warm the shared store so the Agents pane opens instantly.
    Task.detached(priority: .utility) { _ = await AgentHistoryStore.shared.load(.recent) }
    // Handle ⌘W before either the system Close menu or the terminal view consumes it.
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if event.charactersIgnoringModifiers?.lowercased() == "w", modifiers == .command {
        guard (event.window ?? NSApp.keyWindow)?.title != "Pair a device" else { return event }
        NotificationCenter.default.post(name: Notification.Name("ClairCloseFocusedPaneShortcut"), object: nil)
        return nil
      }
      return event
    }
    // The native lights are laid out for a 28pt bar; centre them in our ChromeBudget.titlebar-tall chrome.
    // Re-applied because AppKit resets their frames on resize / full screen.
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(layoutWindow(_:)), name: name, object: nil)
    }
  }

  /// U10: the v1 AppIcon / AppIconDev art (1024px, full bleed), masked to the macOS icon grid (824pt body,
  /// ~185pt corners) because a runtime Dock icon is drawn as-is.
  /// ponytail: runtime icon only; an installed `.app` also needs an `.icns` + `CFBundleIconFile` for Finder (V09 packaging).
  private static func appIcon() -> NSImage? {
    let name = ClairChannel.current == .dev ? "AppIconDev" : "AppIcon"
    guard let url = Bundle.module.url(forResource: name, withExtension: "png"), let art = NSImage(contentsOf: url) else { return nil }
    return NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
      NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185).addClip()
      art.draw(in: rect.insetBy(dx: 100, dy: 100))
      return true
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

  /// ⌘Q asks first: quitting also stops the daemon's shells. An update relaunch is already confirmed.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // The startup benchmark quits itself unattended (CLAIR_STARTUP_TRACE=exit).
    if ClairDaemonLauncher.keepsSessionsOnQuit || ProcessInfo.processInfo.environment["CLAIR_STARTUP_TRACE"] != nil { return .terminateNow }
    let alert = NSAlert()
    alert.messageText = "Clair を終了しますか？"
    alert.informativeText = "実行中のターミナルとエージェントも終了します。"
    alert.addButton(withTitle: "終了")
    alert.addButton(withTitle: "キャンセル")
    return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
    .commands {
      CommandGroup(replacing: .saveItem) {}  // drops File ▸ Close (⌘W); ⌘W closes the focused pane instead
      ClairCommandMenu()
    }
    WindowGroup("Pair a device", id: "clair-pairing") {
      ClairPairingBootstrapView()
    }
  }
}

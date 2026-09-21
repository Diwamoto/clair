import Foundation
import Testing

@testable import ClairV2AppKit
@testable import ClairV2Ghostty

#if os(macOS)
  import AppKit

  /// U06: terminal flood must not starve the main thread, with or without a
  /// UI overlay above the surface. Measures the worst main-runloop stall.
  @Suite(.serialized)
  struct ClairV2GhosttyFloodPerfTests {
    @MainActor
    private func worstStall(overlay: Bool) async -> (stall: Double, ticks: Int) {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
        backing: .buffered, defer: false)
      let surface = ClairV2GhosttySurfaceView(
        launch: (command: "yes 'flood line ▓▒░ 0123456789' | head -n 400000", cwd: "/private/tmp"))
      surface.frame = window.contentView!.bounds
      window.contentView!.addSubview(surface)
      let label = NSTextField(labelWithString: "")
      if overlay {
        label.frame = NSRect(x: 600, y: 20, width: 280, height: 40)
        label.wantsLayer = true
        window.contentView!.addSubview(label)
      }
      window.orderFrontRegardless()
      var worst = 0.0
      var ticks = 0
      var last = ProcessInfo.processInfo.systemUptime
      let end = last + 3
      while last < end {
        try? await Task.sleep(for: .milliseconds(10))
        let now = ProcessInfo.processInfo.systemUptime
        worst = max(worst, now - last - 0.010)
        last = now
        ticks += 1
        if overlay { label.stringValue = "approval \(ticks) · \(Date())" }
      }
      surface.removeFromSuperview()
      window.close()
      return (worst, ticks)
    }

    @Test(.enabled(if: GhosttyRuntime.isVendored)) @MainActor
    func u06FloodDoesNotStarveMainThreadWithOverlay() async {
      let base = await worstStall(overlay: false)
      let over = await worstStall(overlay: true)
      print("U06 perf: baseline worst stall \(base.stall * 1000)ms/\(base.ticks) ticks; overlay \(over.stall * 1000)ms/\(over.ticks) ticks")
      #expect(over.stall < 0.25)
      #expect(over.ticks * 10 > base.ticks * 8)
    }
  }
#endif

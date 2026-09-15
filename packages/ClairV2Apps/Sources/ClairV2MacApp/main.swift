import ClairV2AppKit
import SwiftUI

@main
struct ClairV2MacApp: App {
  var body: some Scene {
    WindowGroup("Clair v2") {
      ClairV2MacTerminalWindow()
    }
  }
}

/// T03: the macOS window hosting the local-shell Ghostty surface. This
/// replaces the earlier 24-line foundation placeholder now that the
/// terminal surface has a real screen to attach to.
private struct ClairV2MacTerminalWindow: View {
  var body: some View {
    ClairV2GhosttySurface()
      .frame(minWidth: 480, minHeight: 320)
  }
}

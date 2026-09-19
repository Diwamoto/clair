import ClairV2AppKit
import SwiftUI

@main
struct ClairV2MacApp: App {
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

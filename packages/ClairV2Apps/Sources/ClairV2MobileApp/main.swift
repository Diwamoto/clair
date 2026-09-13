import ClairV2MobileKit
import SwiftUI

@main
struct ClairV2MobileApp: App {
  var body: some Scene {
    WindowGroup("Clair v2 Mobile") {
      VStack(spacing: 8) {
        Text("Clair v2 iPhone / iPad foundation")
        Text(ClairV2MobileModule.name)
          .foregroundStyle(.secondary)
      }
      .padding()
    }
  }
}

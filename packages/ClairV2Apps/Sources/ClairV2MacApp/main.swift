import ClairV2AppKit
import SwiftUI

@main
struct ClairV2MacApp: App {
  var body: some Scene {
    WindowGroup("Clair v2") {
      FoundationPlaceholderView(title: "Clair v2 macOS foundation")
    }
  }
}

private struct FoundationPlaceholderView: View {
  let title: String

  var body: some View {
    VStack(spacing: 8) {
      Text(title)
      Text(ClairV2AppComposition.packageName)
        .foregroundStyle(.secondary)
    }
    .padding()
  }
}

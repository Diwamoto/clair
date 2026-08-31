import SwiftUI

@main
struct ClairApplication: App {
  private let bootstrapState = BootstrapState.load()

  var body: some Scene {
    WindowGroup {
      ContentView(state: bootstrapState)
    }
    .defaultSize(width: 720, height: 480)
  }
}

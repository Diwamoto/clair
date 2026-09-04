import SwiftUI

@main
struct ClairMobileApp: App {
  @StateObject private var model = MobileControlAppModel()

  var body: some Scene {
    WindowGroup {
      MobileControlAppView(model: model)
    }
  }
}

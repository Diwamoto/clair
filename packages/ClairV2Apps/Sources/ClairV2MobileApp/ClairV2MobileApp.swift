import ClairV2MobileKit
import SwiftUI

@main
struct ClairV2MobileApp: App {
  private let environment: ClairV2MobileEnvironment

  init() {
    #if DEBUG
      environment = .development
    #else
      environment = .testFlight
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ClairV2MobileRootView()
        .environment(\.clairV2Mobile, environment)
    }
  }
}

import ClairMobileKit
import SwiftUI

@main
struct ClairMobileApp: App {
  private let environment: ClairMobileEnvironment
  // One actor owns the protected client, pinned adapter, and transport-backed
  // feature controllers shared by the root view and native push callbacks.
  private let composition = ClairMobileConnectionComposition()

  #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(ClairMobilePushDelegate.self) private var pushDelegate
  #endif

  init() {
    #if DEBUG
      environment = .development
    #else
      environment = .testFlight
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ClairMobileRootView()
        .environment(\.clairMobile, environment)
        .environment(\.clairMobileComposition, composition)
        .onAppear {
          #if canImport(UIKit)
            pushDelegate.composition = composition
          #endif
        }
    }
  }
}

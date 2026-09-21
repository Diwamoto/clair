import ClairMobileKit
import SwiftUI

@main
struct ClairMobileApp: App {
  private let environment: ClairMobileEnvironment
  // Owned once here (the composition root) so the same instance receives
  // both native push-delegate callbacks (device token, remote notification
  // payloads) and the root view's scene-lifecycle/deep-link events -- never
  // two independently-drifting copies of reconnect state.
  private let reconnect = ClairMobileReconnectController()

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
        .environment(\.clairMobileReconnect, reconnect)
        .onAppear {
          #if canImport(UIKit)
            pushDelegate.reconnect = reconnect
          #endif
        }
    }
  }
}

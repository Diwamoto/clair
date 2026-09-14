import ClairV2MobileKit
import SwiftUI

@main
struct ClairV2MobileApp: App {
  private let environment: ClairV2MobileEnvironment
  // Owned once here (the composition root) so the same instance receives
  // both native push-delegate callbacks (device token, remote notification
  // payloads) and the root view's scene-lifecycle/deep-link events -- never
  // two independently-drifting copies of reconnect state.
  private let reconnect = ClairV2MobileReconnectController()

  #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(ClairV2MobilePushDelegate.self) private var pushDelegate
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
      ClairV2MobileRootView()
        .environment(\.clairV2Mobile, environment)
        .environment(\.clairV2MobileReconnect, reconnect)
        .onAppear {
          #if canImport(UIKit)
            pushDelegate.reconnect = reconnect
          #endif
        }
    }
  }
}

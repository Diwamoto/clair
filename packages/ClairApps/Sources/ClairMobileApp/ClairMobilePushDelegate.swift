import ClairMobileKit
import Foundation

#if canImport(UIKit)
  import UIKit
#endif
#if canImport(UserNotifications)
  import UserNotifications
#endif

#if canImport(UIKit)
  /// Thin native glue between UIKit/UserNotifications callbacks and
  /// `ClairMobileReconnectController`. All product logic -- the typed
  /// verify-before-trust scene-lifecycle state machine, the push
  /// registration transport seam, and the category/`ClairPushEventKind`
  /// mapping -- lives in `ClairMobileKit` and is covered by
  /// `ClairCoreTests`. This type only forwards raw platform callbacks into
  /// that already-tested actor, so it stays as small as possible.
  ///
  /// iOS/iPadOS is the only companion-app platform APNs registration targets
  /// (ADR-0015); this file compiles to nothing wherever `UIKit` is
  /// unavailable (for example a macOS host build of this same executable
  /// target), which never registers for or receives push.
  final class ClairMobilePushDelegate: NSObject, UIApplicationDelegate {
    /// Set by `ClairMobileApp` immediately after both this delegate and
    /// the shared reconnect controller exist, so every callback below
    /// forwards into the single instance the rest of the app also observes
    /// through `EnvironmentValues.clairMobileReconnect`.
    var reconnect: ClairMobileReconnectController?

    func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      registerNotificationCategories()
      application.registerForRemoteNotifications()
      return true
    }

    func application(
      _ application: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
      guard let reconnect else { return }
      Task { await reconnect.recordDeviceToken(deviceToken) }
    }

    func application(
      _ application: UIApplication,
      didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
      // APNs registration is best-effort (H09/ADR-0015): a failure here only
      // means no background wake will arrive. It must never be treated as
      // evidence the current session/host/revision is wrong -- the reconnect
      // controller's foreground/deep-link verification remains authoritative
      // regardless of push availability.
    }

    func application(
      _ application: UIApplication,
      didReceiveRemoteNotification userInfo: [AnyHashable: Any],
      fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
      guard let reconnect,
        JSONSerialization.isValidJSONObject(userInfo),
        let payload = try? JSONSerialization.data(withJSONObject: userInfo, options: [])
      else {
        completionHandler(.noData)
        return
      }
      Task {
        let before = await reconnect.state
        let after = await reconnect.handleRemoteNotificationPayload(payload)
        completionHandler(after == before ? .noData : .newData)
      }
    }

    /// Registers the fixed category set mirroring `ClairPushEventKind`
    /// (`ClairMobileNotificationCategory`) so a delivered notification's
    /// category can never silently drift from what H09 actually sends. No
    /// interactive actions are registered here: acting on an attention or
    /// completion event still always goes through
    /// `ClairMobileReconnectController`'s verify-before-trust path, not a
    /// notification action shortcut.
    private func registerNotificationCategories() {
      #if canImport(UserNotifications)
        let categories = Set(
          ClairMobileNotificationCategory.allCases.map { category in
            UNNotificationCategory(
              identifier: category.rawValue,
              actions: [],
              intentIdentifiers: [],
              options: []
            )
          }
        )
        UNUserNotificationCenter.current().setNotificationCategories(categories)
      #endif
    }
  }
#endif

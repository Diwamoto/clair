import ClairV2Push
import ClairV2Shared
import Foundation

/// Build-time values owned by the native mobile composition root.
///
/// The environment deliberately contains no credentials or transport objects.
/// Later mobile tasks can add those dependencies at the composition boundary
/// without changing the state and navigation contract.
public struct ClairV2MobileEnvironment: Equatable, Sendable {
  public enum Distribution: String, CaseIterable, Equatable, Sendable {
    case development
    case testFlight
  }

  public static let defaultBundleIdentifier = "com.diwamoto.clair.mobile"

  public let bundleIdentifier: String
  public let clientVersion: String
  public let distribution: Distribution

  /// The APNs environment matching this build's code-signing distribution.
  /// A development-signed (Xcode debug) build only ever has a `sandbox`
  /// APNs credential; a TestFlight/App Store build always carries a
  /// `production` one. This mapping is fixed by Apple's own signing rules,
  /// not a product decision this task can invent differently.
  public var pushEnvironment: ClairPushEnvironment {
    switch distribution {
    case .development:
      .sandbox
    case .testFlight:
      .production
    }
  }

  public init(
    bundleIdentifier: String = Self.defaultBundleIdentifier,
    clientVersion: String = ClairV2Foundation.version,
    distribution: Distribution = .development
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.clientVersion = clientVersion
    self.distribution = distribution
  }

  public static let development = Self()
  public static let testFlight = Self(distribution: .testFlight)
}

public enum ClairV2MobileLifecycle: String, Equatable, Sendable {
  case inactive
  case active
  case background
}

public enum ClairV2MobileConnectionState: String, Equatable, Sendable {
  case disconnected
  case connecting
  case connected
  case failed
}

public enum ClairV2MobileDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
  case overview
  case sessions
  case activity
  case settings

  public var id: Self { self }

  public var title: String {
    switch self {
    case .overview:
      "Overview"
    case .sessions:
      "Sessions"
    case .activity:
      "Activity"
    case .settings:
      "Settings"
    }
  }
}

/// User intent and lifecycle events handled by the mobile composition root.
///
/// These commands are local UI state transitions. They are not wire commands;
/// transport and authorization commands belong to later client tasks.
public enum ClairV2MobileCommand: Equatable, Sendable {
  case sceneBecameActive
  case sceneBecameInactive
  case sceneEnteredBackground
  case selectDestination(ClairV2MobileDestination)
  case connectRequested
  case connectionEstablished
  case connectionFailed
  case disconnectRequested
}

public struct ClairV2MobileAppState: Equatable, Sendable {
  public private(set) var lifecycle: ClairV2MobileLifecycle
  public private(set) var connection: ClairV2MobileConnectionState
  public private(set) var destination: ClairV2MobileDestination

  public init(
    lifecycle: ClairV2MobileLifecycle = .inactive,
    connection: ClairV2MobileConnectionState = .disconnected,
    destination: ClairV2MobileDestination = .overview
  ) {
    self.lifecycle = lifecycle
    self.connection = connection
    self.destination = destination
  }

  public mutating func apply(_ command: ClairV2MobileCommand) {
    switch command {
    case .sceneBecameActive:
      lifecycle = .active
    case .sceneBecameInactive:
      lifecycle = .inactive
    case .sceneEnteredBackground:
      lifecycle = .background
    case .selectDestination(let destination):
      self.destination = destination
    case .connectRequested:
      if connection != .connected {
        connection = .connecting
      }
    case .connectionEstablished:
      connection = .connected
    case .connectionFailed:
      connection = .failed
    case .disconnectRequested:
      connection = .disconnected
    }
  }
}

/// Small value-type store used by SwiftUI until the real mobile client exists.
public struct ClairV2MobileStore: Equatable, Sendable {
  public private(set) var state: ClairV2MobileAppState

  public init(state: ClairV2MobileAppState = .init()) {
    self.state = state
  }

  public mutating func send(_ command: ClairV2MobileCommand) {
    state.apply(command)
  }
}

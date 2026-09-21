import ClairPush
import ClairShared
import Foundation

/// Build-time values owned by the native mobile composition root.
///
/// The environment deliberately contains no credentials or transport objects.
/// Later mobile tasks can add those dependencies at the composition boundary
/// without changing the state and navigation contract.
public struct ClairMobileEnvironment: Equatable, Sendable {
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
    clientVersion: String = ClairFoundation.version,
    distribution: Distribution = .development
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.clientVersion = clientVersion
    self.distribution = distribution
  }

  public static let development = Self()
  public static let testFlight = Self(distribution: .testFlight)
}

public enum ClairMobileLifecycle: String, Equatable, Sendable {
  case inactive
  case active
  case background
}

public enum ClairMobileConnectionState: String, Equatable, Sendable {
  case disconnected
  case connecting
  case connected
  case failed
}

public enum ClairMobileDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
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
public enum ClairMobileCommand: Equatable, Sendable {
  case sceneBecameActive
  case sceneBecameInactive
  case sceneEnteredBackground
  case selectDestination(ClairMobileDestination)
  case connectRequested
  case connectionEstablished
  case connectionFailed
  case disconnectRequested
}

public struct ClairMobileAppState: Equatable, Sendable {
  public private(set) var lifecycle: ClairMobileLifecycle
  public private(set) var connection: ClairMobileConnectionState
  public private(set) var destination: ClairMobileDestination

  public init(
    lifecycle: ClairMobileLifecycle = .inactive,
    connection: ClairMobileConnectionState = .disconnected,
    destination: ClairMobileDestination = .overview
  ) {
    self.lifecycle = lifecycle
    self.connection = connection
    self.destination = destination
  }

  public mutating func apply(_ command: ClairMobileCommand) {
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
public struct ClairMobileStore: Equatable, Sendable {
  public private(set) var state: ClairMobileAppState

  public init(state: ClairMobileAppState = .init()) {
    self.state = state
  }

  public mutating func send(_ command: ClairMobileCommand) {
    state.apply(command)
  }
}

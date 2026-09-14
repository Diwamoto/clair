import ClairV2Push
import ClairV2Shared
import ClairV2Transport
import Foundation

/// Errors surfaced by the native scene-lifecycle/deep-link/push-reconnect
/// surface. Every case is typed so a caller (SwiftUI view or future
/// AppDelegate glue) can distinguish "nothing to do yet" from "something is
/// actively wrong" without inspecting a string.
public enum ClairV2MobileReconnectError: Error, Equatable, LocalizedError, Sendable {
  case notPaired
  case invalidDeepLink
  case hostMismatch
  case unknownDestination(ResourceScope)
  case transportFailed
  case invalidPushEvent

  public var errorDescription: String? {
    switch self {
    case .notPaired:
      "No paired host connection is available to verify this destination."
    case .invalidDeepLink:
      "The link is not a valid Clair session destination."
    case .hostMismatch:
      "The link targets a different host than the currently paired one."
    case .unknownDestination(let scope):
      "The host could not confirm the requested destination: \(scope)."
    case .transportFailed:
      "The destination could not be verified against the host."
    case .invalidPushEvent:
      "The notification payload was malformed or expired."
    }
  }
}

/// A typed deep-link target parsed from the app's own `clair://` URL scheme
/// (registered in `apple/ClairV2MobileApp/Info.plist`). Parsing only ever
/// produces `ResourceScope`/`ClairHostID` -- the same typed identity model
/// N03/N04/N05/N06 already use -- never a stringly-typed ad hoc route.
///
/// Only a session-scoped target is accepted. N04 already models Project and
/// Worktree browsing without a deep link, so a link naming only a Project or
/// Worktree has no defined destination here; accepting it would mean
/// inventing native-only navigation the mock/canvas has not established.
/// Rejecting it is the same typed-error path as any other malformed link.
///
/// A successfully parsed value is still untrusted: it is a claim, not a
/// fact. Only `ClairV2MobileReconnectController.handle(.launched(deepLink:))`
/// independently verifying it against the host's authoritative state may
/// promote it to something the app navigates to.
public struct ClairV2MobileDeepLink: Equatable, Sendable {
  public let host: ClairHostID?
  public let scope: ResourceScope

  public init(host: ClairHostID? = nil, scope: ResourceScope) throws {
    guard scope.isSessionScope else {
      throw ClairV2MobileReconnectError.invalidDeepLink
    }
    self.host = host
    self.scope = scope
  }

  /// Parses `clair://open?project=<id>&session=<id>[&worktree=<id>][&host=<id>]`.
  /// `project` and `session` are required; an absent or malformed required
  /// field, an unparsable optional field, or a scope B03 itself rejects
  /// (for example a worktree that does not belong to the given project) all
  /// fail the same way: a typed `invalidDeepLink`, never a partial guess.
  public init(url: URL) throws {
    guard let scheme = url.scheme, scheme.caseInsensitiveCompare("clair") == .orderedSame,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      throw ClairV2MobileReconnectError.invalidDeepLink
    }
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? {
      items.first(where: { $0.name == name })?.value
    }

    guard let projectRaw = value("project"), let projectID = ProjectID(rawValue: projectRaw)
    else {
      throw ClairV2MobileReconnectError.invalidDeepLink
    }
    guard let sessionRaw = value("session"), let sessionID = SessionID(rawValue: sessionRaw)
    else {
      throw ClairV2MobileReconnectError.invalidDeepLink
    }
    let worktreeRaw = value("worktree")
    let worktreeID = worktreeRaw.flatMap { WorktreeID(rawValue: $0) }
    guard worktreeRaw == nil || worktreeID != nil else {
      throw ClairV2MobileReconnectError.invalidDeepLink
    }
    let hostRaw = value("host")
    let host = hostRaw.flatMap { ClairHostID(rawValue: $0) }
    guard hostRaw == nil || host != nil else {
      throw ClairV2MobileReconnectError.invalidDeepLink
    }

    do {
      try self.init(
        host: host,
        scope: ResourceScope(projectID: projectID, worktreeID: worktreeID, sessionID: sessionID)
      )
    } catch is ClairV2MobileReconnectError {
      throw ClairV2MobileReconnectError.invalidDeepLink
    }
  }
}

/// One observed lifecycle transition, exactly as the app can actually know
/// it. iOS never calls back into a terminated app, so a relaunch after
/// termination is always observed as `.launched` (with a deep link if the OS
/// handed the process one), never as a distinct "terminated" case the app
/// could inspect.
public enum ClairV2MobileSceneEvent: Equatable, Sendable {
  case launched(deepLink: ClairV2MobileDeepLink?)
  case foregrounded
  case backgrounded
  case pushWake(ClairPushEvent)
}

/// The typed, deterministic outcome of one scene-lifecycle/deep-link/push
/// transition. Exactly one of these holds after `handle` returns: either a
/// position the host has just confirmed as current, or an explicit
/// "must reconnect" state. There is no third, silently-stale possibility,
/// and `.verified` is only ever reached through `ClairV2MobileSessionVerifying`
/// -- never adopted directly from a cache or an unverified push/deep-link
/// payload.
public enum ClairV2MobileReconnectState: Equatable, Sendable {
  case idle
  case verifying(ResourceScope)
  case verified(ReplayCursor)
  case mustReconnect(ResourceScope?, ClairV2MobileReconnectError)
}

/// Transport-neutral seam for confirming a (possibly stale) cached
/// `ReplayCursor` against the host's authoritative H08 session journal, or
/// resolving a bare scope (a fresh deep link, or the first launch with no
/// cache yet) to its current cursor. This mirrors
/// `ClairV2MobileAgentTransport`/`ClairV2MobileWorkspaceReading`'s role for
/// N05/N06: the production Network.framework/TLS adapter backed by H08's
/// `ClairV2SessionJournal.subscribe`/`snapshot` is a later integration
/// boundary, and this protocol deliberately depends only on
/// `ClairV2Shared`/`ClairV2Transport` types so the mobile app can never link
/// host-only `ClairV2DaemonKit` code.
public protocol ClairV2MobileSessionVerifying: Sendable {
  func verify(
    scope: ResourceScope,
    cachedCursor: ReplayCursor?,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ReplayCursor
}

/// Explicit "not yet wired" boundary, mirroring
/// `ClairV2MobileUnavailableAgentTransport`/`ClairV2MobileUnavailableWorkspaceReading`.
/// The native app can construct a reconnect controller before the real
/// transport exists; every verification fails closed instead of silently
/// trusting the cache.
public struct ClairV2MobileUnavailableSessionVerifying: ClairV2MobileSessionVerifying {
  public init() {}

  public func verify(
    scope: ResourceScope,
    cachedCursor: ReplayCursor?,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ReplayCursor {
    throw ClairMobileTransportBoundaryError.unavailable
  }
}

/// A redacted, display-safe snapshot of one push registration, mirroring the
/// shape (but not the daemon-only type) of
/// `ClairDaemonPushRegistry`'s `ClairPushRegistrationSnapshot`. This is a
/// deliberate mobile-local mirror rather than an import of
/// `ClairV2DaemonKit`: the mobile app must never link host-only daemon code.
public struct ClairV2MobilePushRegistrationSnapshot: Equatable, Sendable {
  public let scope: ResourceScope
  public let environment: ClairPushEnvironment
  public let expiresAt: Date
  public let requiresRegistration: Bool

  public init(
    scope: ResourceScope, environment: ClairPushEnvironment, expiresAt: Date,
    requiresRegistration: Bool
  ) {
    self.scope = scope
    self.environment = environment
    self.expiresAt = expiresAt
    self.requiresRegistration = requiresRegistration
  }
}

/// Transport-neutral seam for registering/unregistering this device's APNs
/// token with the host's `ClairDaemonPushRegistry` (H09) for one scope. Like
/// `ClairV2MobileSessionVerifying`, the concrete Network.framework/TLS
/// adapter is a later integration boundary.
public protocol ClairV2MobilePushRegistering: Sendable {
  func register(
    token: ClairPushDeviceToken,
    environment: ClairPushEnvironment,
    scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2MobilePushRegistrationSnapshot

  func unregister(
    environment: ClairPushEnvironment,
    on connection: ClairAuthenticatedConnection
  ) async throws
}

/// Explicit "not yet wired" boundary for push registration.
public struct ClairV2MobileUnavailablePushRegistering: ClairV2MobilePushRegistering {
  public init() {}

  public func register(
    token: ClairPushDeviceToken,
    environment: ClairPushEnvironment,
    scope: ResourceScope,
    on connection: ClairAuthenticatedConnection
  ) async throws -> ClairV2MobilePushRegistrationSnapshot {
    throw ClairMobileTransportBoundaryError.unavailable
  }

  public func unregister(
    environment: ClairPushEnvironment,
    on connection: ClairAuthenticatedConnection
  ) async throws {
    throw ClairMobileTransportBoundaryError.unavailable
  }
}

public enum ClairV2MobilePushRegistrationState: Equatable, Sendable {
  case notRegistered
  case registering
  case registered(ClairV2MobilePushRegistrationSnapshot)
  case failed(ClairV2MobileReconnectError)
}

/// The two notification categories mirroring H09's `ClairPushEventKind`. The
/// app's `UNUserNotificationCenter` category registration derives its native
/// `UNNotificationCategory` identifiers from these raw values so the mapping
/// from a decoded `ClairPushEventKind` to a registered category can never
/// silently drift out of sync with what H09 actually sends.
public enum ClairV2MobileNotificationCategory: String, CaseIterable, Equatable, Sendable {
  case attention = "com.diwamoto.clair.mobile.attention"
  case completion = "com.diwamoto.clair.mobile.completion"

  public init(kind: ClairPushEventKind) {
    switch kind {
    case .attention:
      self = .attention
    case .completion:
      self = .completion
    }
  }
}

/// Actor-owned client-side scene-lifecycle/deep-link/push-reconnect surface.
///
/// This is the single place the native app asks "what is my correct current
/// host/session/revision right now?" It never answers that question from a
/// local cache alone: every transition that could act on a destination --
/// launch (optionally with a deep link), foreground, or a push wake -- is
/// routed through `ClairV2MobileSessionVerifying`, so the result is always
/// either a host-confirmed `ReplayCursor` or an explicit `.mustReconnect`.
/// Backgrounding itself never invalidates the last confirmed position (nothing
/// to verify against while suspended); the very next foreground or push wake
/// re-verifies before that position is used again.
public actor ClairV2MobileReconnectController {
  private let verifier: any ClairV2MobileSessionVerifying
  private let pushRegistry: any ClairV2MobilePushRegistering
  private var connection: ClairAuthenticatedConnection?
  private var cachedCursor: ReplayCursor?
  private var stateValue: ClairV2MobileReconnectState = .idle
  private var pushRegistrationStateValue: ClairV2MobilePushRegistrationState = .notRegistered
  /// The most recently observed raw APNs device token, recorded independently
  /// of whether a destination is selected yet. Native `UIApplicationDelegate`
  /// callbacks (a later, platform-specific integration in the app target)
  /// have no notion of "currently selected scope"; this lets that glue code
  /// stay a pure forwarder while the scope-aware registration decision stays
  /// here, in the already-tested actor.
  private var pendingDeviceTokenBytes: Data?

  public init(
    verifier: any ClairV2MobileSessionVerifying = ClairV2MobileUnavailableSessionVerifying(),
    pushRegistry: any ClairV2MobilePushRegistering = ClairV2MobileUnavailablePushRegistering()
  ) {
    self.verifier = verifier
    self.pushRegistry = pushRegistry
  }

  public var state: ClairV2MobileReconnectState { stateValue }
  public var pushRegistrationState: ClairV2MobilePushRegistrationState {
    pushRegistrationStateValue
  }
  public var isConnected: Bool { connection != nil }

  /// Supplies (or clears) the live authenticated connection used for
  /// verification and push registration. Without one, every transition fails
  /// closed into `.mustReconnect` instead of silently trusting the cache.
  public func attach(connection: ClairAuthenticatedConnection?) {
    self.connection = connection
  }

  /// Fully detaches: clears the connection, the cached cursor, and any
  /// pending state. Used on explicit sign-out/clear-pairing so no stale
  /// destination survives into a fresh pairing.
  public func detach() {
    connection = nil
    cachedCursor = nil
    stateValue = .idle
    pushRegistrationStateValue = .notRegistered
    pendingDeviceTokenBytes = nil
  }

  /// Seeds the last known good cursor (for example restored from N04's
  /// `ClairMobileRecentDestination` plus N05's last-observed epoch/revision).
  /// This is a cache, never a trusted value on its own: every `handle` call
  /// re-verifies it before treating it as current.
  public func seedCache(_ cursor: ReplayCursor?) {
    cachedCursor = cursor
  }

  public var currentCachedCursor: ReplayCursor? { cachedCursor }

  /// Processes one lifecycle transition and returns the resulting typed
  /// state. Safe to call from any scene phase, including while backgrounded
  /// (a push wake is expected to be handled there for background reconnect).
  @discardableResult
  public func handle(_ event: ClairV2MobileSceneEvent) async -> ClairV2MobileReconnectState {
    switch event {
    case .launched(let deepLink):
      if let deepLink {
        return await resolve(deepLink)
      }
      return await revalidateCache()

    case .foregrounded:
      return await revalidateCache()

    case .backgrounded:
      // Nothing to verify against while suspended; the state is left exactly
      // as it was. The next foreground or push wake re-verifies before this
      // is used again, so a stale value is never silently acted upon.
      return stateValue

    case .pushWake(let pushEvent):
      return await handlePushWake(pushEvent)
    }
  }

  /// Decodes a raw APNs payload and folds it as a push wake event. APNs is
  /// best-effort and its payload is a pure opaque wake signal (H09): a
  /// malformed or expired payload is silently ignored -- it can never itself
  /// corrupt or discard an already-verified state -- rather than surfaced as
  /// a hard failure for something the app never asked for.
  @discardableResult
  public func handleRemoteNotificationPayload(_ data: Data) async -> ClairV2MobileReconnectState {
    guard let event = try? ClairPushEvent.decode(data) else {
      return stateValue
    }
    return await handle(.pushWake(event))
  }

  /// Registers this device's APNs token for the given scope. A push wake for
  /// a scope this device never registered for is still handled the same
  /// fail-closed way by `handle`, so a registration failure here degrades to
  /// "no background wake," never to a silently wrong session.
  @discardableResult
  public func registerForPush(
    tokenBytes: Data,
    environment: ClairPushEnvironment,
    scope: ResourceScope
  ) async -> ClairV2MobilePushRegistrationState {
    guard let connection else {
      pushRegistrationStateValue = .failed(.notPaired)
      return pushRegistrationStateValue
    }
    pushRegistrationStateValue = .registering
    do {
      let token = try ClairPushDeviceToken(tokenBytes)
      let snapshot = try await pushRegistry.register(
        token: token, environment: environment, scope: scope, on: connection
      )
      pushRegistrationStateValue = .registered(snapshot)
    } catch is ClairMobileTransportBoundaryError {
      pushRegistrationStateValue = .failed(.transportFailed)
    } catch {
      pushRegistrationStateValue = .failed(.unknownDestination(scope))
    }
    return pushRegistrationStateValue
  }

  /// Records a raw APNs device token as it becomes known, independent of any
  /// destination selection. Call `registerPendingPushTokenIfNeeded` once a
  /// session scope is selected (and again whenever it changes) to actually
  /// register it.
  public func recordDeviceToken(_ bytes: Data) {
    pendingDeviceTokenBytes = bytes
  }

  /// Registers the most recently recorded device token for `scope`, if one
  /// has been observed. A safe no-op (returns the unchanged current push
  /// registration state) when no token has arrived yet -- for example the OS
  /// callback simply has not fired, which must never be treated as a
  /// registration failure.
  @discardableResult
  public func registerPendingPushTokenIfNeeded(
    environment: ClairPushEnvironment,
    scope: ResourceScope
  ) async -> ClairV2MobilePushRegistrationState {
    guard let pendingDeviceTokenBytes else { return pushRegistrationStateValue }
    return await registerForPush(
      tokenBytes: pendingDeviceTokenBytes, environment: environment, scope: scope
    )
  }

  public func unregisterFromPush(environment: ClairPushEnvironment) async {
    guard let connection else {
      pushRegistrationStateValue = .notRegistered
      return
    }
    do {
      try await pushRegistry.unregister(environment: environment, on: connection)
    } catch {
      // An unregister failure must not resurrect a stale "registered" state:
      // the local intent is still "stop," so drop it locally regardless.
    }
    pushRegistrationStateValue = .notRegistered
  }

  // MARK: - Private

  private func revalidateCache() async -> ClairV2MobileReconnectState {
    guard let cachedCursor else {
      stateValue = .mustReconnect(nil, .notPaired)
      return stateValue
    }
    return await verify(scope: cachedCursor.scope, cachedCursor: cachedCursor)
  }

  /// A deep-link payload is never trusted on its own, even when it parses
  /// cleanly: this is what prevents a stale or spoofed link (an unknown or
  /// revoked session/host) from silently navigating anywhere or crashing.
  /// It is always independently confirmed against the host before the app
  /// can act on it.
  private func resolve(_ deepLink: ClairV2MobileDeepLink) async -> ClairV2MobileReconnectState {
    guard let connection else {
      stateValue = .mustReconnect(deepLink.scope, .notPaired)
      return stateValue
    }
    if let host = deepLink.host, host != connection.hostID {
      stateValue = .mustReconnect(deepLink.scope, .hostMismatch)
      return stateValue
    }
    return await verify(scope: deepLink.scope, cachedCursor: nil)
  }

  /// An opaque push wake (H09) carries no session content, only a hint that
  /// something changed. Its only actionable content here is well-formedness:
  /// a malformed or expired wake is ignored and the current state is left
  /// untouched; a valid wake always forces a fresh verification against the
  /// host rather than letting the cached cursor stand unexamined, whether or
  /// not the scene is currently foregrounded. This is what makes background
  /// reconnect real: the resync happens the moment the wake arrives, not only
  /// when the user later opens the app.
  private func handlePushWake(_ pushEvent: ClairPushEvent) async -> ClairV2MobileReconnectState {
    do {
      try pushEvent.validate(at: ClairPushBounds.timestamp(Date()))
    } catch {
      return stateValue
    }
    guard let cachedCursor else {
      stateValue = .mustReconnect(nil, .notPaired)
      return stateValue
    }
    return await verify(scope: cachedCursor.scope, cachedCursor: cachedCursor)
  }

  private func verify(
    scope: ResourceScope,
    cachedCursor: ReplayCursor?
  ) async -> ClairV2MobileReconnectState {
    guard let connection else {
      stateValue = .mustReconnect(scope, .notPaired)
      return stateValue
    }
    stateValue = .verifying(scope)
    do {
      let cursor = try await verifier.verify(
        scope: scope, cachedCursor: cachedCursor, on: connection
      )
      guard cursor.scope == scope else {
        // The verifier must answer for the exact scope it was asked about.
        // A mismatched answer is untrustworthy, never silently adopted.
        stateValue = .mustReconnect(scope, .unknownDestination(scope))
        return stateValue
      }
      self.cachedCursor = cursor
      stateValue = .verified(cursor)
      return stateValue
    } catch is ClairMobileTransportBoundaryError {
      stateValue = .mustReconnect(scope, .transportFailed)
      return stateValue
    } catch {
      stateValue = .mustReconnect(scope, .unknownDestination(scope))
      return stateValue
    }
  }
}

#if CLAIR_GHOSTTY_VENDORED
import ClairGhosttyABI
#endif

/// The build mode libghostty reports itself as, mirroring
/// `clair_ghostty_build_mode_e`.
public enum GhosttyBuildMode: Sendable, Equatable {
  case debug
  case releaseSafe
  case releaseFast
  case releaseSmall
  case unknown
}

/// The result of `GhosttyRuntime.info()`.
public struct GhosttyBuildInfo: Sendable, Equatable {
  public let mode: GhosttyBuildMode
  public let version: String
}

/// The Swift-concurrency boundary around libghostty.
///
/// libghostty is not thread-safe: its app/surface/config objects are owned
/// by the thread that created them. This type is the entire boundary
/// between that C world and the rest of Clair, and it is deliberately
/// narrow:
///
/// - `@MainActor`-isolated: every method here only runs on the main actor,
///   so no background task can reach a raw C handle.
/// - No C handle is `Sendable` and none escapes the scope that created it
///   (see `GhosttyConfigHandle`); ownership is scope-based, via `with…`
///   closures, so every allocation has exactly one matching free.
/// - `ghostty_init` runs at most once per process and must succeed before
///   any other call; a failed or missing initialization fail-closes every
///   later call with a typed `GhosttyError`, never a half-initialized
///   state.
/// - Absence of the vendored artifact (`CLAIR_GHOSTTY_VENDORED` not
///   defined) is itself a typed, fail-closed `.runtimeUnavailable`
///   condition — not a fallback to any non-Ghostty terminal engine.
@MainActor
public final class GhosttyRuntime {
  public static let shared = GhosttyRuntime()

  private var isActivated = false
  private var activationFailure: GhosttyError?

  /// Creates an isolated runtime. Most callers should use `.shared`; this
  /// initializer exists mainly so tests can exercise activation-order and
  /// failure-state behavior without depending on process-global state left
  /// over from another test.
  public init() {}

  /// Whether this build was compiled against the vendored library at all.
  /// `false` means every method below always throws `.runtimeUnavailable`;
  /// this is the default, expected state before `scripts/ghostty.sh
  /// vendor` has run.
  ///
  /// `nonisolated` because this is a pure compile-time-conditional read
  /// (no C handle, no shared mutable state) and callers need it outside
  /// actor isolation, e.g. in a Swift Testing `.enabled(if:)` trait, which
  /// evaluates its condition before any test body runs on the main actor.
  public nonisolated static var isVendored: Bool {
    #if CLAIR_GHOSTTY_VENDORED
    return clair_ghostty_abi_is_vendored() != 0
    #else
    return false
    #endif
  }

  /// Runs `ghostty_init` at most once per process. Must succeed before any
  /// other call on this instance. Calling `activate()` again after a
  /// successful activation is a no-op success (upstream requires
  /// `ghostty_init` to run at most once). Calling it again after a failure
  /// re-throws the same failure without attempting `ghostty_init` again.
  public func activate() throws {
    if let failure = activationFailure { throw failure }
    if isActivated { return }

    guard Self.isVendored else {
      let failure = GhosttyError.runtimeUnavailable
      activationFailure = failure
      throw failure
    }

    #if CLAIR_GHOSTTY_VENDORED
    let result = clair_ghostty_init(0, nil)
    guard result == CLAIR_GHOSTTY_SUCCESS else {
      let failure = GhosttyError.initializationFailed(
        "ghostty_init returned \(result)"
      )
      activationFailure = failure
      throw failure
    }
    isActivated = true
    #endif
  }

  /// Returns libghostty's build mode and version string. Requires a prior
  /// successful `activate()`.
  public func info() throws -> GhosttyBuildInfo {
    try requireActivated()
    #if CLAIR_GHOSTTY_VENDORED
    let raw = clair_ghostty_info()
    let version: String
    if let pointer = raw.version {
      version = String(
        decoding: UnsafeRawBufferPointer(
          start: UnsafeRawPointer(pointer),
          count: Int(raw.version_len)
        ),
        as: UTF8.self
      )
    } else {
      version = ""
    }
    return GhosttyBuildInfo(mode: GhosttyBuildMode(raw.build_mode), version: version)
    #else
    throw GhosttyError.runtimeUnavailable
    #endif
  }

  /// Allocates a `ghostty_config_t` for the duration of `body` and frees it
  /// exactly once when `body` returns or throws — the round trip this
  /// task's minimal-surface smoke test exercises. The handle is invalidated
  /// before the free runs, so any reference `body` leaked out of its own
  /// scope throws `.handleExpired` on next use instead of touching freed
  /// memory.
  public func withConfig<T>(
    _ body: (GhosttyConfigHandle) throws -> T
  ) throws -> T {
    try requireActivated()
    #if CLAIR_GHOSTTY_VENDORED
    guard let raw = clair_ghostty_config_new() else {
      throw GhosttyError.initializationFailed("ghostty_config_new returned NULL")
    }
    let handle = GhosttyConfigHandle(raw: raw)
    defer {
      handle.invalidate()
      clair_ghostty_config_free(raw)
    }
    return try body(handle)
    #else
    throw GhosttyError.runtimeUnavailable
    #endif
  }

  private func requireActivated() throws {
    if let failure = activationFailure { throw failure }
    guard isActivated else { throw GhosttyError.notActivated }
  }
}

#if CLAIR_GHOSTTY_VENDORED
extension GhosttyBuildMode {
  init(_ raw: clair_ghostty_build_mode_e) {
    switch raw {
    case CLAIR_GHOSTTY_BUILD_MODE_DEBUG: self = .debug
    case CLAIR_GHOSTTY_BUILD_MODE_RELEASE_SAFE: self = .releaseSafe
    case CLAIR_GHOSTTY_BUILD_MODE_RELEASE_FAST: self = .releaseFast
    case CLAIR_GHOSTTY_BUILD_MODE_RELEASE_SMALL: self = .releaseSmall
    default: self = .unknown
    }
  }
}
#endif

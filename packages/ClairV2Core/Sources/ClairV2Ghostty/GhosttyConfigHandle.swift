#if CLAIR_GHOSTTY_VENDORED
import ClairV2GhosttyABI
#endif

/// A scope-bound handle to a `ghostty_config_t`.
///
/// libghostty's config object is owned by the thread that created it and is
/// not safe to share. This handle is deliberately not `Sendable`: it is only
/// ever created inside `GhosttyRuntime.withConfig` (which is itself
/// `@MainActor`-isolated) and only valid for the lifetime of that closure.
/// Ownership is scope-based, so exactly one `ghostty_config_free` call
/// matches the one `ghostty_config_new` call that produced this handle. Any
/// attempt to use the handle after the closure returns throws
/// `.handleExpired` before touching the (already freed) C pointer.
@MainActor
public final class GhosttyConfigHandle {
  #if CLAIR_GHOSTTY_VENDORED
  private let raw: clair_ghostty_config_t
  #endif
  private var isValid = true

  #if CLAIR_GHOSTTY_VENDORED
  init(raw: clair_ghostty_config_t) {
    self.raw = raw
  }
  #endif

  /// Invalidates the handle. Called exactly once, by
  /// `GhosttyRuntime.withConfig`'s `defer`, right before the matching free.
  func invalidate() {
    isValid = false
  }

  /// Runs `body` if the owning scope has not exited yet; otherwise throws
  /// `.handleExpired` without calling `body`.
  @discardableResult
  public func withValidHandle<T>(_ body: () throws -> T) throws -> T {
    guard isValid else { throw GhosttyError.handleExpired }
    return try body()
  }

  #if CLAIR_GHOSTTY_VENDORED
    /// Module-internal escape hatch for `GhosttyRuntime.withApp`, which
    /// needs the raw `clair_ghostty_config_t` to call `ghostty_app_new`.
    /// Not `public`: nothing outside `ClairV2Ghostty` touches the raw C
    /// handle directly.
    func withRawConfig<T>(_ body: (clair_ghostty_config_t) -> T) -> T {
      body(raw)
    }
  #endif
}

/// Typed, fail-closed errors for the libghostty boundary. There is no
/// fallback terminal engine: every failure mode here is a distinct, reported
/// state, never a silent substitution (no libvterm path, no emulated
/// terminal, no host-system resource in place of a missing vendored one).
public enum GhosttyError: Error, Equatable, Sendable {
  /// The vendored library was never linked into this build
  /// (`scripts/v2-ghostty.sh vendor` has not run, or produced no artifact).
  /// This is the default, expected state on a machine that has never
  /// vendored libghostty; it is not a bug.
  case runtimeUnavailable

  /// A call was made before `GhosttyRuntime.activate()` succeeded.
  case notActivated

  /// `ghostty_init` (or an earlier `activate()` call) failed. Once set,
  /// every later call on this runtime keeps failing with this error; the
  /// boundary never proceeds from a half-initialized state.
  case initializationFailed(String)

  /// A scoped handle (for example `GhosttyConfigHandle`) was used after the
  /// closure that owns it returned. The handle was already invalidated and
  /// freed at scope exit; this is reported instead of touching a dangling
  /// C pointer.
  case handleExpired

  /// A runtime resource (terminfo database, shell-integration script) is not
  /// staged. Never substituted from the host system.
  case resourceMissing(String)
}

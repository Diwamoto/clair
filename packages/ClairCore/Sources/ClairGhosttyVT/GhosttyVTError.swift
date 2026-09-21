/// Typed, fail-closed errors for the libghostty-vt boundary. Mirrors
/// `GhosttyError` (`ClairGhostty`): there is no fallback terminal engine
/// here either -- no independent ANSI/VT interpreter, no libvterm path. A
/// build that never vendored `GhosttyVT.xcframework` (`scripts/ghostty.sh
/// vendor-vt`) reports `.runtimeUnavailable` for every call instead of
/// silently degrading to some other rendering path.
public enum GhosttyVTError: Error, Equatable, Sendable {
  /// The vendored library was never linked into this build, or this build
  /// is not iOS (the only platform `GhosttyVT.xcframework` has slices for
  /// -- see `Package.swift`'s `ghosttyVTVendored` gating). Expected, not a
  /// bug, until `vendor-vt` has run for an iOS build.
  case runtimeUnavailable

  /// `ghostty_terminal_new` or another allocation returned
  /// `GHOSTTY_OUT_OF_MEMORY`.
  case outOfMemory

  /// An argument was rejected by libghostty-vt (`GHOSTTY_INVALID_VALUE`) --
  /// for example a zero column/row count, or a point outside the grid.
  case invalidValue

  /// The point did not resolve to selectable content, or there was no
  /// selection to format (`GHOSTTY_NO_VALUE`).
  case noValue

  /// An unexpected result code not covered by the cases above. Carries the
  /// raw code for diagnostics; libghostty-vt's own error surface is small
  /// (`GHOSTTY_OUT_OF_SPACE`/`GHOSTTY_IO_ERROR`/`GHOSTTY_LIMIT_EXCEEDED`
  /// are possible from the alloc/format calls this wrapper makes but are
  /// not expected in practice for the bounded terminal sizes Clair uses).
  case unexpected(Int32)
}

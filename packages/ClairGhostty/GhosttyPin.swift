/// Swift mirror of `config/ghostty-pin.json`, the single tracked source of
/// truth for the pinned libghostty/GhosttyKit dependency.
///
/// These constants exist so the pin is visible from Swift without parsing
/// JSON at runtime. They must never drift from the manifest: the drift
/// itself is exactly the failure mode this task's invariants call out
/// ("manifest and Swift constants drift apart"). A test in
/// `ClairCoreTests` reads `config/ghostty-pin.json` from disk and asserts
/// every field below is byte-for-byte equal to it; a hand-edit of one side
/// without the other fails that test, not silently.
public enum GhosttyPin {
  public static let upstreamRepository = "https://github.com/ghostty-org/ghostty"
  public static let pinnedCommit = "0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec"
  public static let pinnedCommitDescription = "vt-1.0.0 (libghostty-vt 1.0 tag)"

  public static let licenseSPDXIdentifier = "MIT"
  public static let licenseCopyright =
    "Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors"

  public static let toolchainName = "zig"
  public static let toolchainVersion = "0.17.0"

  public static let buildMode = "ReleaseFast"
  public static let xcframeworkName = "GhosttyKit.xcframework"
}

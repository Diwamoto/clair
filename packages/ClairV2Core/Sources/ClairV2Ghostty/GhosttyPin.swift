/// Swift mirror of `Config/ghostty-pin.json`, the single tracked source of
/// truth for the pinned libghostty/GhosttyKit dependency.
///
/// These constants exist so the pin is visible from Swift without parsing
/// JSON at runtime. They must never drift from the manifest: the drift
/// itself is exactly the failure mode this task's invariants call out
/// ("manifest and Swift constants drift apart"). A test in
/// `ClairV2CoreTests` reads `Config/ghostty-pin.json` from disk and asserts
/// every field below is byte-for-byte equal to it; a hand-edit of one side
/// without the other fails that test, not silently.
public enum GhosttyPin {
  public static let upstreamRepository = "https://github.com/ghostty-org/ghostty"
  public static let pinnedCommit = "d4c88d8069912b653d707191388ca98e24751f12"
  public static let pinnedCommitDescription = "1.3.2-dev (post-v1.3.1 main)"

  public static let licenseSPDXIdentifier = "MIT"
  public static let licenseCopyright =
    "Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors"

  public static let toolchainName = "zig"
  public static let toolchainVersion = "0.16.0"

  public static let buildMode = "ReleaseFast"
  public static let xcframeworkName = "GhosttyKit.xcframework"
}

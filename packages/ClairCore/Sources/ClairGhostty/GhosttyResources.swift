import Foundation

/// Runtime resources (terminfo database, shell-integration scripts) staged
/// by `scripts/ghostty.sh vendor` from the same pinned build as the
/// library (see `Config/ghostty-pin.json`'s `resources` section for the
/// upstream install-tree paths these are copied from).
///
/// Lookups go through this API rather than a hardcoded absolute developer
/// path, and report `.resourceMissing` when a resource was never staged —
/// they never fall back to a same-named file the host machine happens to
/// have installed (a system terminfo database, a shell's own rc file,
/// etc.).
public enum GhosttyResources {
  public enum Shell: String, CaseIterable, Sendable {
    case bash
    case zsh
    case fish
    case elvish
    case nushell
  }

  /// `packages/ClairCore/Vendor/ghostty/resources`, resolved relative to
  /// this source file rather than the process's current working directory
  /// (which build tools may set to anything).
  static var vendorResourcesDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // ClairGhostty
      .deletingLastPathComponent() // Sources
      .deletingLastPathComponent() // ClairCore
      .appendingPathComponent("Vendor/ghostty/resources", isDirectory: true)
  }

  /// The Ghostty terminfo database (`ghostty.terminfo`), compiled at vendor
  /// time from upstream `src/terminfo`.
  public static func terminfoDatabaseURL() throws -> URL {
    let url = vendorResourcesDirectory
      .appendingPathComponent("terminfo/ghostty.terminfo", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw GhosttyError.resourceMissing("terminfo database")
    }
    return url
  }

  /// The shell-integration script directory for one shell.
  public static func shellIntegrationDirectoryURL(for shell: Shell) throws -> URL {
    let url = vendorResourcesDirectory
      .appendingPathComponent("shell-integration", isDirectory: true)
      .appendingPathComponent(shell.rawValue, isDirectory: true)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw GhosttyError.resourceMissing("shell-integration/\(shell.rawValue)")
    }
    return url
  }
}

import ClairDaemonKit
import ClairWorkspace
import Foundation

#if os(macOS)
  /// T09: the Mac GUI does not own a PTY. It makes sure this channel's daemon is running and points
  /// each terminal surface at `clair attach`, which binds the surface to a daemon-owned shell.
  public enum ClairDaemonLauncher {
    public static var paths: ClairDaemonPaths {
      ClairDaemonPaths(directoryURL: ClairChannel.current.dataURL)
    }
    private static var client: ClairDaemonControlClient { ClairDaemonControlClient(paths: paths) }

    /// `ClairDaemon` and `clair` sit next to the app executable (`swift build` output or
    /// `Contents/MacOS`); `CLAIR_BIN_DIR` overrides for unusual layouts.
    static func binary(_ name: String) -> URL? {
      let dir =
        ProcessInfo.processInfo.environment["CLAIR_BIN_DIR"].map { URL(fileURLWithPath: $0) }
        ?? Bundle.main.executableURL?.deletingLastPathComponent()
      guard let url = dir?.appending(path: name),
        FileManager.default.isExecutableFile(atPath: url.path)
      else { return nil }
      return url
    }

    /// Starts the daemon unless one already answers. The daemon's own lock keeps it single-instance,
    /// so a race between two GUIs is harmless. Returns immediately; `clair attach` waits for it.
    @discardableResult
    public static func ensureRunning() -> Bool {
      if (try? client.health()) != nil { return true }
      guard let daemon = binary("ClairDaemon") else { return false }
      let process = Process()
      process.executableURL = daemon
      process.arguments = ["--directory", paths.directoryURL.path]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      return (try? process.run()) != nil
    }

    /// The command a Ghostty surface runs for one pane. Fails closed with a visible message when
    /// the daemon binaries are missing, instead of silently falling back to a GUI-owned shell.
    public static func attachCommand(key: String, cwd: String, command: String?) -> String {
      guard let clair = binary("clair") else {
        return "echo 'Clair: the clair executable was not found next to the app (set CLAIR_BIN_DIR).'; exit 1"
      }
      var parts = [
        clair.path, "attach", "--key", key, "--cwd", cwd, "--directory", paths.directoryURL.path,
      ]
      if let command, !command.isEmpty { parts += ["--command", command] }
      return parts.map(shellQuote).joined(separator: " ")
    }

    /// The user closed the pane: end that shell. Best effort; the daemon may already be gone.
    public static func closeSession(key: String) {
      _ = try? client.terminal(.close(key: key))
    }

    /// Explicit Clair quit ends the daemon and its shells (spec §7).
    public static func shutdown() {
      try? client.shutdown()
    }

    static func shellQuote(_ s: String) -> String {
      "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
  }
#endif

import Foundation

/// Makes Clair the editor for Claude Code's Ctrl+G: `env.VISUAL` in `~/.claude/settings.json` (Claude only, not the shell).
// ponytail: JSONSerialization rewrites the file with sorted keys; keep the user's key order if anyone minds.
public enum ClairClaudeEditor {
  public static let command = "clair open --wait"

  public static func settings(home: URL = .homeDirectory) -> URL { home.appendingPathComponent(".claude/settings.json") }

  public static func isInstalled(home: URL = .homeDirectory) -> Bool {
    ((try? read(home))?["env"] as? [String: Any])?["VISUAL"] as? String == command
  }

  public static func install(home: URL = .homeDirectory) throws {
    var json = try read(home), env = json["env"] as? [String: Any] ?? [:]
    if let other = env["VISUAL"] as? String, other != command {
      throw NSError(domain: "ClairClaudeEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "VISUAL は既に設定されています: \(other)"])
    }
    env["VISUAL"] = command; json["env"] = env
    try write(json, home)
  }

  public static func uninstall(home: URL = .homeDirectory) throws {
    var json = try read(home)
    guard var env = json["env"] as? [String: Any], env["VISUAL"] as? String == command else { return }
    env["VISUAL"] = nil; json["env"] = env.isEmpty ? nil : env
    try write(json, home)
  }

  /// A missing file is `{}`; an unreadable one throws so it is never overwritten.
  private static func read(_ home: URL) throws -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: settings(home: home).path) else { return [:] }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NSError(domain: "ClairClaudeEditor", code: 2, userInfo: [NSLocalizedDescriptionKey: "settings.json を読めません"])
    }
    return json
  }

  private static func write(_ json: [String: Any], _ home: URL) throws {
    let url = settings(home: home)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url, options: .atomic)
  }
}

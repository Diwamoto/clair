import Foundation

/// Claude Code's official hooks report an agent's state to Clair (`agent.report`): working on a prompt or
/// after a tool ran, blocked on a permission or question dialog, done when a turn ends. Installed into
/// `~/.claude/settings.json` next to the user's own hooks; outside a Clair terminal the command does nothing.
public enum ClairClaudeHooks {
  static let marker = "clair agent.report"
  /// The hook's stdin is Claude Code's JSON; its `session_id` lets Clair reopen the conversation after a restart.
  static func command(_ state: String) -> String {
    let session = #"$(sed -n 's/.*"session_id" *: *"\([A-Za-z0-9_-]*\)".*/\1/p' | head -n 1)"#
    return "[ -n \"$CLAIR_TERMINAL_KEY\" ] && command -v clair >/dev/null && \(marker) state=\(state) session=\"\(session)\" >/dev/null 2>&1; true"
  }
  /// event → (matcher, state). `Notification` fires for other reasons too (idle, auth); only dialogs block.
  static let events: [(event: String, matcher: String?, state: String)] = [
    ("UserPromptSubmit", nil, "working"),
    ("PostToolUse", nil, "working"),
    ("Notification", "permission_prompt|elicitation_dialog", "blocked"),
    ("Stop", nil, "done"),
  ]

  public static func isInstalled(home: URL = .homeDirectory) -> Bool {
    guard let hooks = (try? ClairClaudeEditor.read(home))?["hooks"] as? [String: Any] else { return false }
    return events.allSatisfy { e in ((hooks[e.event] as? [[String: Any]]) ?? []).contains(where: ours) }
  }

  /// Replaces Clair's entries (so a reinstall picks up new ones) and keeps every other hook.
  public static func install(home: URL = .homeDirectory) throws {
    var json = try ClairClaudeEditor.read(home)
    var hooks = removingOurs(json["hooks"] as? [String: Any] ?? [:])
    for e in events {
      var entry: [String: Any] = ["hooks": [["type": "command", "command": command(e.state)]]]
      if let m = e.matcher { entry["matcher"] = m }
      hooks[e.event] = ((hooks[e.event] as? [[String: Any]]) ?? []) + [entry]
    }
    json["hooks"] = hooks
    try ClairClaudeEditor.write(json, home)
  }

  public static func uninstall(home: URL = .homeDirectory) throws {
    var json = try ClairClaudeEditor.read(home)
    guard let hooks = json["hooks"] as? [String: Any] else { return }
    let kept = removingOurs(hooks)
    json["hooks"] = kept.isEmpty ? nil : kept
    try ClairClaudeEditor.write(json, home)
  }

  private static func ours(_ entry: [String: Any]) -> Bool {
    ((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
  }

  private static func removingOurs(_ hooks: [String: Any]) -> [String: Any] {
    var out = hooks
    for (event, value) in hooks {
      guard let entries = value as? [[String: Any]] else { continue }
      let kept = entries.filter { !ours($0) }
      out[event] = kept.isEmpty ? nil : kept
    }
    return out
  }
}

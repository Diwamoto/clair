import Foundation

/// The installable HTML artifact preview skill. Keep this text identical to `.agents/skills/clair-preview/SKILL.md`.
public enum ClairPreviewSkill {
  public static let name = "clair-preview"
  public static let markdown = #"""
---
name: clair-preview
description: Open locally generated HTML artifacts in Clair's interactive preview when running inside a Clair terminal. Use when an agent has made an HTML artifact for the user to view.
---

# Clair HTML preview

When `CLAIR_TERMINAL_KEY` is set and `clair` is on PATH, show a generated `.html` or `.htm` artifact with:

```bash
clair preview "/absolute/path/to/artifact.html"
```

Clair opens the file and its JavaScript-enabled preview pane. An approval card may appear in Clair; if the user denies it, stop. The preview supports self-contained HTML; relative local assets do not load. JavaScript and remote resources can use the network.

Use the requested browser when the user explicitly asks for one, or when a running web app needs browser testing. If Clair or its CLI is unavailable, tell the user where the HTML file is instead of claiming it opened.
"""# + "\n"

  public static func targets(home: URL = .homeDirectory) -> [URL] {
    [".claude/skills", ".agents/skills"].map { home.appending(path: $0).appending(path: name).appending(path: "SKILL.md") }
  }

  public static func isInstalled(home: URL = .homeDirectory) -> Bool {
    targets(home: home).allSatisfy { (try? String(contentsOf: $0, encoding: .utf8)) == markdown }
  }

  public static func install(home: URL = .homeDirectory) throws {
    for url in targets(home: home) {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try markdown.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  public static func uninstall(home: URL = .homeDirectory) throws {
    for url in targets(home: home) where (try? String(contentsOf: url, encoding: .utf8)) == markdown {
      try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
  }
}

public enum ClairSkills {
  /// The skills that are one plain `SKILL.md`: the TODO skill and the card agent's skill.
  static let plain: [(name: String, markdown: String)] = [(ClairTodoSkill.name, ClairTodoSkill.markdown), (ClairCardSkill.name, ClairCardSkill.markdown)]

  public static func isInstalled(home: URL = .homeDirectory) -> Bool {
    ClairAgentSkill.isInstalled(home: home) && ClairPreviewSkill.isInstalled(home: home)
      && plain.allSatisfy { s in targets(home, s.name).allSatisfy { (try? String(contentsOf: $0, encoding: .utf8)) == s.markdown } }
  }

  static func targets(_ home: URL, _ name: String) -> [URL] {
    [".claude/skills", ".agents/skills"].map { home.appending(path: $0).appending(path: name).appending(path: "SKILL.md") }
  }

  static func todoTargets(_ home: URL) -> [URL] { targets(home, ClairTodoSkill.name) }

  public static func install(home: URL = .homeDirectory) throws {
    for (skill, targets) in [(ClairAgentSkill.markdown, ClairAgentSkill.targets(home: home)),
                             (ClairPreviewSkill.markdown, ClairPreviewSkill.targets(home: home))]
                            + plain.map({ ($0.markdown, targets(home, $0.name)) }) {
      // An older shipped version and a user edit look the same, so keep any differing file as SKILL.md.bak and update.
      for url in targets where FileManager.default.fileExists(atPath: url.path) && (try? String(contentsOf: url, encoding: .utf8)) != skill {
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: url, to: backup)
      }
    }
    try ClairAgentSkill.install(home: home)
    try ClairPreviewSkill.install(home: home)
    for s in plain {
      for url in targets(home, s.name) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.markdown.write(to: url, atomically: true, encoding: .utf8)
      }
    }
  }

  public static func uninstall(home: URL = .homeDirectory) throws {
    try ClairAgentSkill.uninstall(home: home)
    try ClairPreviewSkill.uninstall(home: home)
    for s in plain {
      for url in targets(home, s.name) where (try? String(contentsOf: url, encoding: .utf8)) == s.markdown {
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
      }
    }
  }
}

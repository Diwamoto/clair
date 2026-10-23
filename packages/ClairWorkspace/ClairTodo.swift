import Foundation

/// A Clair TODO: one Markdown file under `~/.clair/todo`, front matter + free-form context.
public struct ClairTodo: Equatable, Sendable {
  public var path: String
  public var title: String
  public var priority: Int
  public var due: String?
  public var done: Bool

  public static func dir(home: URL = .homeDirectory) -> URL { home.appending(path: ".clair/todo") }

  /// Parses the `---` front matter; a file without one is an open priority-2 TODO named after the file.
  public static func parse(path: String, text: String) -> ClairTodo {
    var t = ClairTodo(path: path, title: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, priority: 2, due: nil, done: false)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return t }
    for line in lines.dropFirst() {
      if line.trimmingCharacters(in: .whitespaces) == "---" { break }
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if let hash = value.range(of: " #") { value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces) }
      value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      switch key {
      case "title" where !value.isEmpty: t.title = value
      case "priority": t.priority = Int(value) ?? 2
      case "due": t.due = value.isEmpty ? nil : value
      case "done": t.done = value == "true"
      default: break
      }
    }
    return t
  }

  /// Open TODOs first, then priority, then due date (undated last).
  public static func list(home: URL = .homeDirectory) -> [ClairTodo] {
    let dir = dir(home: home)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".md") }.compactMap { name in
      let url = dir.appending(path: name)
      return (try? String(contentsOf: url, encoding: .utf8)).map { parse(path: url.path, text: $0) }
    }.sorted { ($0.done ? 1 : 0, $0.priority, $0.due ?? "~", $0.title) < ($1.done ? 1 : 0, $1.priority, $1.due ?? "~", $1.title) }
  }
}

/// The installable TODO skill. Keep this text identical to `.agents/skills/clair-todo/SKILL.md`.
public enum ClairTodoSkill {
  public static let name = "clair-todo"
  public static let markdown = #"""
---
name: clair-todo
description: Clair's TODO list — one Markdown file per TODO in ~/.clair/todo, shown in Clair's sidebar. Use whenever the user asks to remember, defer, or add something as a TODO ("あとで", "todoに追加", "やること"), asks what is left to do, or asks to work on / finish a TODO.
---

# Clair TODO

Each TODO is one file `~/.clair/todo/<slug>.md` (slug: short, lowercase, `-`-joined). Clair's sidebar lists them.

```markdown
---
title: Fix login redirect
priority: 1          # 1 high, 2 normal, 3 low
due: 2026-10-30      # optional, YYYY-MM-DD
done: false
---

Free-form context: why, links, the project path, what was tried, next step.
```

## Add

When the user asks for a TODO, create the file right away — do not ask for confirmation. Default `priority: 2`, omit `due` unless a date was given (resolve "明日", "金曜" to a date). Put everything a later session needs into the body: the current project path, related files, the request in the user's words.

## List

Read the front matter of every file in `~/.clair/todo`, show open ones sorted by priority, then due date.

## Work on one

When asked to do a TODO (or "次のtodo"), pick the requested one or the open one with the best priority / earliest due, read its body for context, `cd` to the project it names, and do the work. Append progress notes to the body as you go. When finished, set `done: true` and add a short result line. Do not delete files unless the user asks.
"""# + "\n"
}

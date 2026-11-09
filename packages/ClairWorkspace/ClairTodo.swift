import Foundation

/// A Clair TODO: one Markdown file under `~/.clair/todo`, front matter + free-form context.
public struct ClairTodo: Equatable, Sendable {
  public var path: String
  public var title: String
  public var priority: Int
  public var due: String?
  public var done: Bool
  /// Front-matter keys Clair does not own (`kr:` …), as read; `render(onto:)` keeps them in the file.
  public var extra: [String: String] = [:]
  /// #74 workflow keys, written by the concierge and its children; Clair only shows them.
  public var stage: String?
  public var lane: String?
  public var retry: Int?
  public var branch: String?
  public var pr: String?
  /// The terminal key (`root#pane`) of the agent working on this stage.
  public var agent: String?

  public static let stages = ["plan", "impl", "check-A", "check-B", "submit", "done"]
  public static let lanes = ["code", "research"]

  public init(path: String, title: String, priority: Int = 2, due: String? = nil, done: Bool = false) {
    self.path = path; self.title = title; self.priority = priority; self.due = due; self.done = done
  }

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
      if value.hasPrefix("\""), value.count > 1, value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
      else if let hash = value.range(of: " #") { value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces) }
      switch key {
      case "title" where !value.isEmpty: t.title = value
      case "priority": t.priority = Int(value) ?? 2
      case "due": t.due = value.isEmpty ? nil : value
      case "done": t.done = value == "true"
      case "title": break
      case "stage": t.stage = value.isEmpty ? nil : value
      case "lane": t.lane = value.isEmpty ? nil : value
      case "retry": t.retry = Int(value)
      case "branch": t.branch = value.isEmpty ? nil : value
      case "pr": t.pr = value.isEmpty ? nil : value
      case "agent": t.agent = value.isEmpty ? nil : value
      default: t.extra[key] = value
      }
    }
    return t
  }

  public func with(_ change: (inout ClairTodo) -> Void) -> ClairTodo { var c = self; change(&c); return c }

  static let keys: Set<String> = ["title", "priority", "due", "done", "stage", "lane", "retry", "branch", "pr", "agent"]

  /// The workflow keys present, in file order.
  var workflow: [(String, String)] {
    [("stage", stage), ("lane", lane), ("retry", retry.map(String.init)), ("branch", branch), ("pr", pr), ("agent", agent)]
      .compactMap { k, v in v.map { (k, $0) } }
  }

  /// Front-matter lines (without the `---` fences) and the body after them.
  static func split(_ text: String) -> (meta: [Substring], body: Substring) {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
          let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([], Substring(text)) }
    return (Array(lines[1..<end]), Substring(lines[(end + 1)...].joined(separator: "\n")))
  }

  /// `text` with its front matter rewritten from this TODO; the body and unknown keys are kept.
  public func render(onto text: String) -> String {
    let (meta, body) = Self.split(text)
    // One line: a newline in the title would end the front matter early and drop the keys after it (#70).
    let line = title.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "\"", with: "'")
    var out = ["---", "title: \"\(line)\"", "priority: \(priority)"]
    if let due { out.append("due: \(due)") }
    out.append("done: \(done)")
    // Quoted: a branch or PR URL can hold ` #`, which parse would read as a comment.
    out += workflow.map { k, v in "\(k): \"\(v.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "\"", with: "'"))\"" }
    out += meta.filter { line in !Self.keys.contains(line.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") }.map(String.init)
    out.append("---")
    return out.joined(separator: "\n") + "\n" + body
  }

  /// Writes this TODO's front matter into its file, keeping the body; `appendBody` goes on a new line at the end.
  public func save(appendBody: String? = nil) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    var text = render(onto: old)
    if let appendBody, !appendBody.isEmpty { text += (text.hasSuffix("\n") ? "" : "\n") + appendBody + "\n" }
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Why `priority` / `due` cannot be written, or nil when they can.
  public static func invalid(priority: Int?, due: String?, stage: String? = nil, lane: String? = nil, retry: Int? = nil) -> String? {
    if let stage, !stage.isEmpty, !stages.contains(stage) { return "stage must be one of \(stages.joined(separator: ", "))" }
    if let lane, !lane.isEmpty, !lanes.contains(lane) { return "lane must be code or research" }
    if let retry, retry < 0 { return "retry must be 0 or more" }
    if let priority, !(1...3).contains(priority) { return "priority must be 1, 2 or 3" }
    if let due, !due.isEmpty {
      let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
      if due.count != 10 || f.date(from: due) == nil { return "due must be YYYY-MM-DD" }
    }
    return nil
  }

  /// `path` names an existing TODO file directly in `~/.clair/todo` (no `..`, no other folder).
  public static func isTodoFile(_ path: String, home: URL = .homeDirectory) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return url.pathExtension == "md" && url.deletingLastPathComponent().path == dir(home: home).standardizedFileURL.path
      && FileManager.default.fileExists(atPath: url.path)
  }

  /// The `todo.*` command reply: Clair's fields plus the file's own keys.
  public var json: [String: Any] {
    var o: [String: Any] = extra
    o["path"] = path; o["title"] = title; o["priority"] = priority; o["due"] = due ?? NSNull(); o["done"] = done
    for (k, v) in workflow { o[k] = k == "retry" ? retry! as Any : v }
    return o
  }

  /// A new file path for `title`: the title without `/` or `:`, numbered when taken.
  public static func newPath(title: String, home: URL = .homeDirectory) -> String {
    var base = title.components(separatedBy: CharacterSet(charactersIn: "/:\n")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    if base.isEmpty || base.hasPrefix(".") { base = "todo" }
    base = String(base.prefix(80))
    let dir = dir(home: home)
    return (1...).lazy.map { dir.appending(path: $0 == 1 ? "\(base).md" : "\(base)-\($0).md").path }
      .first { !FileManager.default.fileExists(atPath: $0) }!
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

Use the commands (`clair todo.list` … or the `mcp__clair__todo_*` tools) rather than writing the files; they check the values and keep extra keys such as `kr:`. Edit a file by hand only when Clair is not running.

```sh
clair todo.list done=false                     # JSON: path, title, priority, due, done, extra keys; priority → due order
clair todo.add title="Fix login" priority=1 due=2026-10-30 body="context"
clair todo.update path=<path> done=true appendBody="result: shipped"   # also title / priority / due ("" clears)
clair todo.update path=<path> stage=impl lane=code agent=<terminal key>          # workflow keys: stage, lane, retry, branch, pr, agent
```

## Add

When the user asks for a TODO, add it right away — do not ask for confirmation. Default `priority: 2`, omit `due` unless a date was given (resolve "明日", "金曜" to a date). Put everything a later session needs into the body: the current project path, related files, the request in the user's words.

## List

`todo.list done=false` gives the open ones, sorted by priority, then due date.

## Work on one

When asked to do a TODO (or "次のtodo"), pick the requested one or the open one with the best priority / earliest due, read its file for context, `cd` to the project it names, and do the work. Add progress notes with `appendBody` as you go. When finished, `todo.update path=… done=true appendBody="<short result>"`. Do not delete files unless the user asks.
"""# + "\n"
}

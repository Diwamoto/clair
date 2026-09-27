import Foundation
import SQLite3

/// Read-only projections of provider-owned chat history. Clair never stores message bodies.
public struct AgentHistory: Sendable, Identifiable {
  public enum Provider: String, Sendable, CaseIterable {
    case codex = "Codex", claude = "Claude Code", opencode = "OpenCode"
  }

  public struct Message: Sendable, Identifiable {
    public let id: String
    public let role: String
    public let text: String
    public let date: Date
  }

  public let id: String
  public let provider: Provider
  public let title: String
  public let date: Date
  public let messages: [Message]
  /// Provider-reported or token-priced API-equivalent cost, when available. It is not a bill.
  public let estimatedUSD: Double?
  /// Working directory the provider recorded, when available.
  public var project: String? = nil
  /// Provider file to re-read for the full transcript; nil when `messages` is already complete.
  public var source: URL? = nil

  public var promptCount: Int { messages.filter { $0.role == "user" }.count }
}

/// ccedit's project list: one group per project (repo folder name), most recently active first.
public struct AgentHistoryGroup: Sendable, Identifiable {
  public let project: String
  public let histories: [AgentHistory]
  public var id: String { project }
  public var date: Date { histories[0].date }
  public var estimatedUSD: Double { histories.compactMap(\.estimatedUSD).reduce(0, +) }

  public static func group(_ histories: [AgentHistory]) -> [AgentHistoryGroup] {
    Dictionary(grouping: histories.sorted { $0.date > $1.date }) { $0.project.map { URL(filePath: $0).lastPathComponent } ?? "不明" }
      .map { AgentHistoryGroup(project: $0.key, histories: $0.value) }
      .sorted { $0.date > $1.date }
  }
}

public struct AgentUsageDay: Sendable, Identifiable {
  public let date: Date
  public let prompts: Int
  public let providerPrompts: [AgentHistory.Provider: Int]
  public var id: Date { date }
}

public struct AgentProviderUsage: Sendable, Identifiable {
  public let provider: AgentHistory.Provider
  public let prompts: Int
  public let estimatedUSD: Double
  public let sessionsWithoutCost: Int
  public var id: AgentHistory.Provider { provider }
}

public struct AgentUsageSummary: Sendable {
  public let days: [AgentUsageDay]
  public let providers: [AgentProviderUsage]
  public let estimatedUSD: Double
  public let sessionsWithoutCost: Int

  public init(histories: [AgentHistory], calendar: Calendar = .current) {
    var counts: [Date: Int] = [:]
    var providerCounts: [Date: [AgentHistory.Provider: Int]] = [:]
    for history in histories {
      for message in history.messages where message.role == "user" {
        let day = calendar.startOfDay(for: message.date)
        counts[day, default: 0] += 1
        providerCounts[day, default: [:]][history.provider, default: 0] += 1
      }
    }
    days = counts.map { AgentUsageDay(date: $0.key, prompts: $0.value, providerPrompts: providerCounts[$0.key] ?? [:]) }
      .sorted { $0.date < $1.date }
    estimatedUSD = histories.compactMap(\.estimatedUSD).reduce(0, +)
    sessionsWithoutCost = histories.filter { $0.estimatedUSD == nil }.count
    providers = AgentHistory.Provider.allCases.map { provider in
      let subset = histories.filter { $0.provider == provider }
      return AgentProviderUsage(provider: provider, prompts: subset.map(\.promptCount).reduce(0, +),
                                estimatedUSD: subset.compactMap(\.estimatedUSD).reduce(0, +),
                                sessionsWithoutCost: subset.filter { $0.estimatedUSD == nil }.count)
    }
  }

  public func prompts(on day: Date, calendar: Calendar = .current) -> Int {
    days.first { calendar.isDate($0.date, inSameDayAs: day) }?.prompts ?? 0
  }

  public func usage(on day: Date, calendar: Calendar = .current) -> AgentUsageDay? {
    days.first { calendar.isDate($0.date, inSameDayAs: day) }
  }
}

public enum AgentHistoryReader {
  /// Reads provider-owned files on a background task. Provider failures are isolated.
  /// `period` filters by last-modified time before any file is parsed, so an unopened archive costs nothing.
  /// List-only by default: `messages` then holds the user turns and the last message (tool results skipped unparsed), and
  /// `transcript(of:)` reads one file in full when a chat is opened.
  public static func load(home: URL = .homeDirectory, period: DateInterval? = nil, full: Bool = false) -> [AgentHistory] {
    var result = readJSONL(root: home.appending(path: ".codex/sessions"), provider: .codex, period: period, full: full)
    result += readJSONL(root: home.appending(path: ".claude/projects"), provider: .claude, period: period, full: full)
    result += readOpenCode(home.appending(path: ".local/share/opencode/opencode.db"), period: period)
    return result.sorted { $0.date > $1.date }
  }

  public static func transcript(of history: AgentHistory) -> [AgentHistory.Message] {
    guard let file = history.source else { return history.messages }
    return readFile(file, provider: history.provider, full: true)?.messages ?? history.messages
  }

  private static func readJSONL(root: URL, provider: AgentHistory.Provider, period: DateInterval?, full: Bool) -> [AgentHistory] {
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { return [] }
    let paths = (files.allObjects as? [URL] ?? []).filter { file in
      guard file.pathExtension == "jsonl" else { return false }
      guard let period else { return true }
      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      return modified >= period.start && modified < period.end
    }
    // Files are independent; parse them on every core.
    let slots = UnsafeMutableBufferPointer<AgentHistory?>.allocate(capacity: paths.count)
    slots.initialize(repeating: nil)
    defer { slots.deinitialize(); slots.deallocate() }
    DispatchQueue.concurrentPerform(iterations: paths.count) { slots[$0] = readFile(paths[$0], provider: provider, full: full) }
    return slots.compactMap { $0 }
  }

  private static func readFile(_ file: URL, provider: AgentHistory.Provider, full: Bool) -> AgentHistory? {
      var messages: [AgentHistory.Message] = []
      var cost: Double?
      var codexModel: String?
      var codexUsage: [String: Any]?
      var claudeMessageCosts: [String: Double] = [:]
      var claudeUnknownModel = false
      var sessionID = file.deletingPathExtension().lastPathComponent
      var cwd: String?
      var seen: Set<String> = []
      var claudeMessageIndex: [String: Int] = [:]
      let fractionalDate = ISO8601DateFormatter()
      fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let plainDate = ISO8601DateFormatter()
      let relevant = (provider == .codex
        ? ["\"type\":\"session_meta\"", "\"type\":\"turn_context\"", "\"type\":\"token_usage_record\"", "\"type\":\"response_item\""]
        : ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"cost-state\""])
        .map { Data($0.utf8) }
      eachLine(file) { data in
        guard relevant.contains(where: { data.range(of: $0) != nil }) else { return }
        // Tool results ride on "user" rows, can be huge, and never carry prompt text.
        if !full, data.range(of: Data(#""tool_use_id""#.utf8)) != nil { return }
        guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let type = row["type"] as? String ?? ""
        let payload = row["payload"] as? [String: Any] ?? [:]
        let timestamp = row["timestamp"] as? String ?? ""
        let date = fractionalDate.date(from: timestamp) ?? plainDate.date(from: timestamp) ?? .distantPast
        if provider == .codex {
          if type == "session_meta", let id = payload["id"] as? String { sessionID = id; cwd = payload["cwd"] as? String ?? cwd }
          if type == "turn_context" { codexModel = payload["model"] as? String ?? codexModel }
          if type == "token_usage_record" { codexUsage = payload["thread_token_usage"] as? [String: Any] ?? codexUsage }
          guard type == "response_item", let role = payload["role"] as? String,
                role == "user" || role == "assistant" else { return }
          let parts = payload["content"] as? [[String: Any]] ?? []
          let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
          let id = payload["id"] as? String ?? "\(file.path):\(messages.count)"
          guard seen.insert(id).inserted else { return }
          messages.append(.init(id: id, role: role, text: text, date: date))
        } else {
          if type == "cost-state" { cost = row["totalCostUSD"] as? Double; return }
          guard type == "user" || type == "assistant", row["isSidechain"] as? Bool != true else { return }
          if let id = row["sessionId"] as? String { sessionID = id }
          cwd = cwd ?? row["cwd"] as? String
          let message = row["message"] as? [String: Any] ?? [:]
          if type == "assistant", let usage = message["usage"] as? [String: Any] {
            if let estimated = claudeEstimatedCost(model: message["model"] as? String ?? "", usage: usage) {
              let key = message["id"] as? String ?? row["uuid"] as? String ?? "\(file.path):\(claudeMessageCosts.count)"
              claudeMessageCosts[key] = max(estimated, claudeMessageCosts[key] ?? 0)
            } else if ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
              .contains(where: { ((usage[$0] as? NSNumber)?.doubleValue ?? 0) > 0 }) {
              claudeUnknownModel = true
            }
          }
          let content = message["content"]
          var text: String
          if let value = content as? String { text = value }
          else if let parts = content as? [[String: Any]] {
            text = parts.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
          } else { text = "" }
          if type == "user" { text = formatUserText(text) ?? "" }
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
          let id = row["uuid"] as? String ?? "\(file.path):\(messages.count)"
          let item = AgentHistory.Message(id: id, role: type, text: text, date: date)
          if let index = claudeMessageIndex[id] {
            if text.count > messages[index].text.count { messages[index] = item }
          } else {
            claudeMessageIndex[id] = messages.count
            messages.append(item)
          }
        }
      }
      guard !messages.isEmpty else { return nil }
      if !full, let last = messages.last {
        // The list keeps user turns (title, prompt counts) and the last message (preview); bodies load on open.
        messages = messages.filter { $0.role == "user" } + (last.role == "user" ? [] : [last])
      }
      if provider == .codex, let model = codexModel, let usage = codexUsage {
        cost = codexEstimatedCost(model: model, usage: usage)
      } else if provider == .claude, cost == nil, !claudeMessageCosts.isEmpty, !claudeUnknownModel {
        cost = claudeMessageCosts.values.reduce(0, +)
      }
      let title = messages.first { $0.role == "user" && !$0.text.hasPrefix("[Skill loaded") }?.text
        .split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? "チャット"
      return AgentHistory(id: "\(provider.rawValue):\(sessionID)", provider: provider,
                          title: String(title.prefix(100)), date: messages.last?.date ?? .distantPast,
                          messages: messages, estimatedUSD: cost, project: cwd, source: full ? nil : file)
  }

  /// Port of ccedit's `format_command_text` + `is_clear_artifact`: Claude Code wraps slash commands,
  /// skill bodies, and `!` shell turns in tags. Returns nil for `/clear` noise and caveat-only turns.
  static func formatUserText(_ text: String) -> String? {
    func tag(_ name: String) -> String? {
      guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
      return String(text[open.upperBound..<close.lowerBound]).replacing(/\x1b\[[0-9;]*[a-zA-Z]/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("Base directory for this skill:") {
      let name = trimmed.firstMatch(of: /skills\/([^\/\s]+)/)?.1
      return name.map { "[Skill loaded: \($0)]" } ?? "[Skill loaded]"
    }
    if let command = tag("bash-input") { return "```bash\n$ \(command)\n```" }
    if trimmed.hasPrefix("<bash-stdout>") {
      let output = [tag("bash-stdout"), tag("bash-stderr")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
      return output.isEmpty ? nil : "```\n\(output)\n```"
    }
    var parts: [String] = []
    if let name = tag("command-name") {
      if name == "/clear" { return nil }
      parts.append([name, tag("command-args") ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
    }
    if let output = tag("local-command-stdout"), !output.isEmpty { parts.append(output) }
    let rest = trimmed.replacing(/<(local-command-caveat|local-command-stdout|command-name|command-message|command-args|system-reminder)>[\s\S]*?<\/\1>/, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !rest.isEmpty { parts.append(rest) }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
  }

  /// Standard, short-context API-equivalent rates per million tokens (2026-09-24).
  /// Unknown models stay unknown instead of silently using another model's price.
  /// https://developers.openai.com/api/docs/pricing
  private static func codexEstimatedCost(model: String, usage: [String: Any]) -> Double? {
    let rates: (Double, Double, Double, Double)
    switch model {
    case "gpt-6-astra": rates = (5, 0.5, 6.25, 25)
    case "gpt-6-sol": rates = (1, 0.1, 1.25, 5)
    case "gpt-6-luna": rates = (0.05, 0.005, 0.0625, 0.25)
    case "gpt-5.6-sol": rates = (4, 0.4, 5, 20)
    default: return nil
    }
    func count(_ key: String) -> Double { (usage[key] as? NSNumber)?.doubleValue ?? 0 }
    let input = count("input_tokens")
    let cached = count("cached_input_tokens")
    let written = count("cache_write_input_tokens")
    let output = count("output_tokens")
    guard input >= cached + written else { return nil }
    return ((input - cached - written) * rates.0 + cached * rates.1 + written * rates.2 + output * rates.3) / 1_000_000
  }

  /// Claude standard API-equivalent rates per million tokens (2026-09-24).
  /// https://platform.claude.com/docs/en/about-claude/pricing
  private static func claudeEstimatedCost(model: String, usage: [String: Any]) -> Double? {
    let rates: (Double, Double, Double, Double, Double)
    switch model {
    case "claude-sonnet-5": rates = (2, 10, 2.5, 4, 0.2)
    case "claude-opus-5-5": rates = (4, 20, 5, 8, 0.2)
    case "claude-opus-5": rates = (5, 25, 6.25, 10, 0.5)
    case "claude-fable-5-1": rates = (10, 50, 12.5, 20, 0.25)
    default: return nil
    }
    func count(_ key: String) -> Double { (usage[key] as? NSNumber)?.doubleValue ?? 0 }
    let cache = usage["cache_creation"] as? [String: Any] ?? [:]
    let write5 = (cache["ephemeral_5m_input_tokens"] as? NSNumber)?.doubleValue ?? count("cache_creation_input_tokens")
    let write1h = (cache["ephemeral_1h_input_tokens"] as? NSNumber)?.doubleValue ?? 0
    return (count("input_tokens") * rates.0 + count("output_tokens") * rates.1
            + write5 * rates.2 + write1h * rates.3 + count("cache_read_input_tokens") * rates.4) / 1_000_000
  }

  /// Bounds memory per line while allowing large histories to stream from disk.
  private static func eachLine(_ file: URL, visit: (Data) -> Void) {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return }
    defer { try? handle.close() }
    var pending = Data()
    while let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      pending.append(chunk)
      var start = pending.startIndex
      while let newline = pending[start...].firstIndex(of: 10) {
        if newline - start <= 4 * 1024 * 1024 { visit(pending[start..<newline]) }
        start = newline + 1
      }
      pending = Data(pending[start...])
      if pending.count > 4 * 1024 * 1024 { pending.removeAll(keepingCapacity: true) }
    }
    if !pending.isEmpty { visit(pending) }
  }

  private static func readOpenCode(_ database: URL, period: DateInterval?) -> [AgentHistory] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
      if db != nil { sqlite3_close(db) }
      return []
    }
    defer { sqlite3_close(db) }
    let sql = """
      SELECT s.id, s.title, s.time_updated, s.cost, m.id, m.time_created,
             json_extract(m.data, '$.role'), group_concat(json_extract(p.data, '$.text'), char(10)), s.directory
      FROM session s JOIN message m ON m.session_id = s.id
      JOIN part p ON p.message_id = m.id
      WHERE json_extract(p.data, '$.type') = 'text'
        AND s.time_updated >= \(Int64((period?.start ?? .distantPast).timeIntervalSince1970 * 1000))
        AND s.time_updated < \(Int64((period?.end ?? .distantFuture).timeIntervalSince1970 * 1000))
      GROUP BY m.id
      ORDER BY s.time_updated DESC, m.time_created, p.id
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
    defer { sqlite3_finalize(statement) }
    var sessions: [String: (String, Date, Double, [AgentHistory.Message], String?)] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let sid = sqlite3_column_text(statement, 0), let mid = sqlite3_column_text(statement, 4),
            let role = sqlite3_column_text(statement, 6), let body = sqlite3_column_text(statement, 7) else { continue }
      let id = String(cString: sid)
      let text = String(cString: body)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "チャット"
      let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2)) / 1000)
      let cost = sqlite3_column_double(statement, 3)
      let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5)) / 1000)
      let message = AgentHistory.Message(id: String(cString: mid), role: String(cString: role), text: text, date: created)
      let directory = sqlite3_column_text(statement, 8).map { String(cString: $0) }
      if sessions[id] == nil { sessions[id] = (title, updated, cost, [], directory) }
      sessions[id]!.3.append(message)
    }
    return sessions.map { id, item in
      AgentHistory(id: "OpenCode:\(id)", provider: .opencode, title: item.0,
                   date: item.1, messages: item.3, estimatedUSD: item.2, project: item.4)
    }
  }
}

/// Shares the expensive provider scan between Agents and Usage. Chats untouched for 30 days are an
/// archive that is only read when asked for. Each part reloads after five minutes.
public actor AgentHistoryStore {
  public enum Part: Sendable { case recent, archive }
  public static let shared = AgentHistoryStore()
  private var cached: [Part: (at: Date, items: [AgentHistory])] = [:]
  private var loading: [Part: Task<[AgentHistory], Never>] = [:]

  public static func period(_ part: Part, now: Date = .now) -> DateInterval {
    let cutoff = now.addingTimeInterval(-30 * 86_400)
    return part == .recent ? DateInterval(start: cutoff, end: .distantFuture) : DateInterval(start: .distantPast, end: cutoff)
  }

  public func load(_ part: Part) async -> [AgentHistory] {
    if let hit = cached[part], Date().timeIntervalSince(hit.at) < 300 { return hit.items }
    if let task = loading[part] { return await task.value }
    let period = Self.period(part)
    let task = Task.detached(priority: .utility) { AgentHistoryReader.load(period: period) }
    loading[part] = task
    let result = await task.value
    cached[part] = (.now, result)
    loading[part] = nil
    return result
  }

  public func refresh(_ part: Part) async -> [AgentHistory] {
    cached[part] = nil
    return await load(part)
  }

  public func transcript(_ history: AgentHistory) async -> [AgentHistory.Message] {
    await Task.detached(priority: .userInitiated) { AgentHistoryReader.transcript(of: history) }.value
  }

  /// Everything, for usage totals.
  public func all() async -> [AgentHistory] {
    (await load(.recent) + load(.archive)).sorted { $0.date > $1.date }
  }

  public func refresh() async -> [AgentHistory] {
    cached.removeAll()
    return await all()
  }
}

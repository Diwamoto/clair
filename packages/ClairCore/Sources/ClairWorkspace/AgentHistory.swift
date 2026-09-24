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

  public var promptCount: Int { messages.filter { $0.role == "user" }.count }
}

/// ccedit-style grouping: relative-day sections, then one group per project inside each.
public struct AgentHistorySection: Sendable, Identifiable {
  public struct Group: Sendable, Identifiable {
    public let id: String
    public let project: String
    public let histories: [AgentHistory]
    public var estimatedUSD: Double { histories.compactMap(\.estimatedUSD).reduce(0, +) }
  }

  public let label: String
  public let groups: [Group]
  public var id: String { label }

  public static func group(_ histories: [AgentHistory], now: Date = .now, calendar: Calendar = .current) -> [AgentHistorySection] {
    let labels = ["今日", "昨日", "先週", "それ以前"]
    let today = calendar.startOfDay(for: now)
    func label(_ date: Date) -> String {
      let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? .max
      return days <= 0 ? labels[0] : days == 1 ? labels[1] : days <= 7 ? labels[2] : labels[3]
    }
    let byLabel = Dictionary(grouping: histories.sorted { $0.date > $1.date }) { label($0.date) }
    return labels.compactMap { label in
      guard let items = byLabel[label] else { return nil }
      let byProject = Dictionary(grouping: items) { $0.project.map { URL(filePath: $0).lastPathComponent } ?? "不明" }
      let groups = byProject.map { Group(id: "\(label)::\($0.key)", project: $0.key, histories: $0.value) }
        .sorted { $0.histories[0].date > $1.histories[0].date }
      return AgentHistorySection(label: label, groups: groups)
    }
  }
}

public struct AgentUsageDay: Sendable, Identifiable {
  public let date: Date
  public let prompts: Int
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
    for history in histories {
      for message in history.messages where message.role == "user" {
        counts[calendar.startOfDay(for: message.date), default: 0] += 1
      }
    }
    days = counts.map { AgentUsageDay(date: $0.key, prompts: $0.value) }.sorted { $0.date < $1.date }
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
}

public enum AgentHistoryReader {
  /// Reads provider-owned files on a background task. Provider failures are isolated.
  public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentHistory] {
    var result = readJSONL(root: home.appending(path: ".codex/sessions"), provider: .codex)
    result += readJSONL(root: home.appending(path: ".claude/projects"), provider: .claude)
    result += readOpenCode(home.appending(path: ".local/share/opencode/opencode.db"))
    return result.sorted { $0.date > $1.date }
  }

  private static func readJSONL(root: URL, provider: AgentHistory.Provider) -> [AgentHistory] {
    guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var histories: [AgentHistory] = []
    for case let file as URL in files where file.pathExtension == "jsonl" {
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
          let text: String
          if let value = content as? String { text = value }
          else if let parts = content as? [[String: Any]] {
            text = parts.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
          } else { text = "" }
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
      guard !messages.isEmpty else { continue }
      if provider == .codex, let model = codexModel, let usage = codexUsage {
        cost = codexEstimatedCost(model: model, usage: usage)
      } else if provider == .claude, cost == nil, !claudeMessageCosts.isEmpty, !claudeUnknownModel {
        cost = claudeMessageCosts.values.reduce(0, +)
      }
      let title = messages.first(where: { $0.role == "user" })?.text.prefix(100) ?? "チャット"
      histories.append(.init(id: "\(provider.rawValue):\(sessionID)", provider: provider,
                             title: String(title), date: messages.last?.date ?? .distantPast,
                             messages: messages, estimatedUSD: cost, project: cwd))
    }
    return histories
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
    while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      pending.append(chunk)
      while let newline = pending.firstIndex(of: 10) {
        if newline <= 4 * 1024 * 1024 { visit(pending.prefix(upTo: newline)) }
        pending.removeSubrange(...newline)
      }
      if pending.count > 4 * 1024 * 1024 { pending.removeAll(keepingCapacity: true) }
    }
    if !pending.isEmpty { visit(pending) }
  }

  private static func readOpenCode(_ database: URL) -> [AgentHistory] {
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

/// Shares the expensive provider scan between Agents and Usage. Reloads after five minutes.
public actor AgentHistoryStore {
  public static let shared = AgentHistoryStore()
  private var cached: [AgentHistory]?
  private var loadedAt: Date = .distantPast
  private var loading: Task<[AgentHistory], Never>?

  public func all() async -> [AgentHistory] {
    if let cached, Date().timeIntervalSince(loadedAt) < 300 { return cached }
    if let loading { return await loading.value }
    let task = Task.detached(priority: .utility) { AgentHistoryReader.load() }
    loading = task
    let result = await task.value
    cached = result
    loadedAt = .now
    loading = nil
    return result
  }

  public func refresh() async -> [AgentHistory] {
    cached = nil
    return await all()
  }
}

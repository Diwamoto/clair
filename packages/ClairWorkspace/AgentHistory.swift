import ClairShared
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
  /// Each answered prompt, from the prompt to the last reply before the next one (usage: wait time, concurrency).
  public var turns: [DateInterval] = []
  /// API-equivalent cost per model; `usd` is nil for a model with no known price.
  public var models: [ModelCost] = []

  public struct ModelCost: Sendable, Equatable {
    public let name: String
    public let usd: Double?
  }

  /// Provider-native session id, the argument of the provider's resume command.
  public var sessionID: String { String(id.dropFirst(provider.rawValue.count + 1)) }

  /// Shell line that resumes this chat from its recorded directory, for pasting into any terminal; nil if not resumable.
  public var resumeCommand: String? {
    guard let profile = AgentProfile.all.first(where: { $0.title == provider.rawValue }) else { return nil }
    let resume = AgentLaunch(profile: profile.id, cwd: project ?? "", resume: sessionID).command
    guard resume != profile.command else { return nil }
    return project.map { "cd \(AgentRun.quote($0)) && \(resume)" } ?? resume
  }

  public var promptCount: Int { messages.filter { $0.role == "user" }.count }

  /// One row of the chat: a message, or the progress (narration and thinking) an agent run made before its reply.
  public enum ChatItem: Sendable, Identifiable {
    case message(Message)
    case progress([Message])

    public var id: String {
      switch self { case .message(let m): m.id; case .progress(let steps): "progress:" + steps[0].id }
    }
    /// The message that dates and places the row.
    public var anchor: Message {
      switch self { case .message(let m): m; case .progress(let steps): steps[0] }
    }
  }

  /// Providers record progress and the final reply the same way, so position decides: in each agent run
  /// between user turns the last text is the reply and everything before it folds into one progress row.
  public static func chatItems(_ messages: [Message]) -> [ChatItem] {
    var items: [ChatItem] = [], run: [Message] = []
    func flush() {
      if let last = run.lastIndex(where: { $0.role != "thinking" }) {
        var steps = run
        let reply = steps.remove(at: last)
        if !steps.isEmpty { items.append(.progress(steps)) }
        items.append(.message(reply))
      } else if !run.isEmpty { items.append(.progress(run)) }
      run = []
    }
    for message in messages {
      if message.role == "user" { flush(); items.append(.message(message)) } else { run.append(message) }
    }
    flush()
    return items
  }
}

/// ccedit's project list: one group per project (repo folder name), most recently active first.
public struct AgentHistoryGroup: Sendable, Identifiable {
  public let project: String
  public let histories: [AgentHistory]
  public var id: String { project }
  public var date: Date { histories[0].date }
  public var estimatedUSD: Double { histories.compactMap(\.estimatedUSD).reduce(0, +) }

  public static func group(_ histories: [AgentHistory]) -> [AgentHistoryGroup] {
    Dictionary(grouping: histories.sorted { $0.date > $1.date }) { $0.project.map { URL(filePath: $0).lastPathComponent } ?? tr("不明") }
      .map { AgentHistoryGroup(project: $0.key, histories: $0.value) }
      .sorted { $0.date > $1.date }
  }
}

/// One calendar day of past chats, split into projects — ccedit's DateView: a chat sits under the day
/// it was last updated, days newest first, projects by name, chats newest first.
public struct AgentHistoryDay: Sendable, Identifiable {
  public let date: Date
  public let groups: [AgentHistoryGroup]
  public var id: Date { date }

  public static func group(_ histories: [AgentHistory], calendar: Calendar = .current) -> [AgentHistoryDay] {
    Dictionary(grouping: histories) { calendar.startOfDay(for: $0.date) }
      .map { AgentHistoryDay(date: $0.key, groups: AgentHistoryGroup.group($0.value).sorted { $0.project < $1.project }) }
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
  public let histories: [AgentHistory]

  public init(histories: [AgentHistory], calendar: Calendar = .current) {
    self.histories = histories
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

  /// Days in a row with a prompt, ending today — or yesterday while today has none yet.
  public func streak(now: Date = .now, calendar: Calendar = .current) -> Int {
    let active = Set(days.map(\.date))
    var day = calendar.startOfDay(for: now)
    if !active.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
    var count = 0
    while active.contains(day) {
      count += 1
      guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
      day = previous
    }
    return count
  }

  public func longestStreak(calendar: Calendar = .current) -> Int {
    var best = 0
    var run = 0
    var previous: Date?
    for day in days {
      run = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day.date ? run + 1 : 1
      best = max(best, run)
      previous = day.date
    }
    return best
  }

  /// Prompts since `start` by weekday (0 = Sunday) and hour, in the calendar's time zone.
  public func weekdayHours(since start: Date, calendar: Calendar = .current) -> [[Int]] {
    var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    for history in histories {
      for message in history.messages where message.role == "user" && message.date >= start {
        let parts = calendar.dateComponents([.weekday, .hour], from: message.date)
        guard let weekday = parts.weekday, let hour = parts.hour else { continue }
        grid[weekday - 1][hour] += 1
      }
    }
    return grid
  }

  /// Hours of the day ordered by prompt count, busiest first; hours with no prompt are left out.
  public func busiestHours(since start: Date, calendar: Calendar = .current) -> [Int] {
    let grid = weekdayHours(since: start, calendar: calendar)
    let totals = (0..<24).map { hour in grid.reduce(0) { $0 + $1[hour] } }
    return (0..<24).filter { totals[$0] > 0 }.sorted { totals[$0] > totals[$1] }
  }

  // MARK: Waiting and concurrency

  /// Longer waits are counted as this long: the prompt was probably left while the user stepped away.
  public static let waitCap: TimeInterval = 30 * 60
  /// Exclusive upper bounds of the wait histogram bins, in seconds; the last bin holds the rest, capped waits included.
  public static let waitBins: [TimeInterval] = [10, 30, 60, 120, 300, 600, 1800]

  public struct Wait: Sendable, Equatable {
    public let provider: AgentHistory.Provider
    public let seconds: TimeInterval
  }

  /// Answered prompts sent within `interval`, each capped at `waitCap`.
  public func waits(in interval: DateInterval) -> [Wait] {
    histories.flatMap { history in
      history.turns.filter { interval.contains($0.start) }
        .map { Wait(provider: history.provider, seconds: min($0.duration, Self.waitCap)) }
    }
  }

  public static func median(_ values: [TimeInterval]) -> TimeInterval? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }

  /// Counts per bin of `waitBins` (plus one overflow bin).
  public static func histogram(_ waits: [Wait]) -> [Int] {
    var bins = Array(repeating: 0, count: waitBins.count + 1)
    for wait in waits { bins[waitBins.firstIndex { wait.seconds < $0 } ?? waitBins.count] += 1 }
    return bins
  }

  public struct Step: Sendable, Equatable {
    public let date: Date
    public let running: Int
  }

  /// How many agents were between a prompt and its last reply, as steps across `interval`.
  public func concurrency(in interval: DateInterval) -> [Step] {
    var deltas: [(Date, Int)] = []
    for turn in histories.flatMap(\.turns) {
      guard let clipped = turn.intersection(with: interval), clipped.duration > 0 else { continue }
      deltas.append((clipped.start, 1))
      deltas.append((clipped.end, -1))
    }
    // An end and a start at the same instant do not overlap.
    deltas.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    var steps = [Step(date: interval.start, running: 0)]
    var running = 0
    for (date, delta) in deltas {
      running += delta
      if steps.last?.date == date { steps.removeLast() }
      steps.append(Step(date: date, running: running))
    }
    return steps
  }

  /// Seconds within the steps during which at least `count` agents ran.
  public static func seconds(_ steps: [Step], atLeast count: Int, until end: Date) -> TimeInterval {
    zip(steps, steps.dropFirst().map(\.date) + [end]).reduce(0) { total, pair in
      pair.0.running >= count ? total + max(0, pair.1.timeIntervalSince(pair.0.date)) : total
    }
  }

  /// Average number of running agents per hour of the day over the `dayCount` days ending at `now`.
  public func averageConcurrencyByHour(dayCount: Int, now: Date = .now, calendar: Calendar = .current) -> [Double] {
    var seconds = Array(repeating: 0.0, count: 24)
    let today = calendar.startOfDay(for: now)
    for offset in 0..<dayCount {
      guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
      for hour in 0..<24 {
        guard let start = calendar.date(byAdding: .hour, value: hour, to: day), start < now,
              let end = calendar.date(byAdding: .hour, value: 1, to: start) else { continue }
        let window = DateInterval(start: start, end: min(end, now))
        for turn in histories.flatMap(\.turns) {
          if let overlap = turn.intersection(with: window) { seconds[hour] += overlap.duration }
        }
      }
    }
    return seconds.map { $0 / 3600 / Double(max(dayCount, 1)) }
  }

  // MARK: Months and rankings

  /// Running total for each day of the month containing `month`, up to `now` for the current month.
  /// `cost` totals estimated USD by each chat's last day; chats without a cost are left out.
  public func cumulative(month: Date, cost: Bool, now: Date = .now, calendar: Calendar = .current) -> [Double] {
    guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
    var perDay: [Date: Double] = [:]
    if cost {
      for history in histories where interval.contains(history.date) {
        if let usd = history.estimatedUSD { perDay[calendar.startOfDay(for: history.date), default: 0] += usd }
      }
    } else {
      for day in days where interval.contains(day.date) { perDay[day.date] = Double(day.prompts) }
    }
    var result: [Double] = []
    var total = 0.0
    var day = interval.start
    while day < interval.end && day <= now {
      total += perDay[day] ?? 0
      result.append(total)
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return result
  }

  public func sessionsWithoutCost(month: Date, calendar: Calendar = .current) -> Int {
    guard let interval = calendar.dateInterval(of: .month, for: month) else { return 0 }
    return histories.filter { interval.contains($0.date) && $0.estimatedUSD == nil }.count
  }

  public struct ModelUsage: Sendable, Equatable, Identifiable {
    public let name: String
    public let provider: AgentHistory.Provider
    public let sessions: Int
    /// nil when no session using the model had a known price.
    public let usd: Double?
    public var id: String { "\(provider.rawValue):\(name)" }
  }

  /// Models used by chats active since `start` (all time when nil): priced ones by cost, then unpriced by sessions.
  public func models(since start: Date?) -> [ModelUsage] {
    var rows: [String: (provider: AgentHistory.Provider, name: String, sessions: Int, usd: Double?)] = [:]
    for history in histories where start.map({ history.date >= $0 }) ?? true {
      for model in history.models {
        let key = "\(history.provider.rawValue):\(model.name)"
        var row = rows[key] ?? (provider: history.provider, name: model.name, sessions: 0, usd: nil)
        row.sessions += 1
        if let usd = model.usd { row.usd = (row.usd ?? 0) + usd }
        rows[key] = row
      }
    }
    return rows.values.map { ModelUsage(name: $0.name, provider: $0.provider, sessions: $0.sessions, usd: $0.usd) }
      .sorted { lhs, rhs in
        switch (lhs.usd, rhs.usd) {
        case let (a?, b?): return a != b ? a > b : lhs.name < rhs.name
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs.sessions != rhs.sessions ? lhs.sessions > rhs.sessions : lhs.name < rhs.name
        }
      }
  }

  /// Chats active since `start` with the highest known cost.
  public func costliestSessions(since start: Date, limit: Int) -> [AgentHistory] {
    Array(histories.filter { $0.date >= start && $0.estimatedUSD != nil }
      .sorted { ($0.estimatedUSD ?? 0) > ($1.estimatedUSD ?? 0) }
      .prefix(limit))
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

  /// ADR-0020: one session file read in full, for a live chat whose file is already known.
  public static func transcript(file: URL, provider: AgentHistory.Provider) -> [AgentHistory.Message] {
    readFile(file, provider: provider, full: true)?.messages ?? []
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
      var claudeMessageModels: [String: String] = [:]
      var claudeUnpricedModels: Set<String> = []
      var turnEvents: [(user: Bool, date: Date)] = []
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
          if type == "response_item", payload["role"] as? String != "user" { turnEvents.append((false, date)) }
          if type == "session_meta", let id = payload["id"] as? String { sessionID = id; cwd = payload["cwd"] as? String ?? cwd }
          if type == "turn_context" { codexModel = payload["model"] as? String ?? codexModel }
          if type == "token_usage_record" { codexUsage = payload["thread_token_usage"] as? [String: Any] ?? codexUsage }
          // Reasoning summaries are the only readable part of Codex thinking; the chat shows them folded.
          if full, type == "response_item", payload["type"] as? String == "reasoning" {
            let text = (payload["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            let id = payload["id"] as? String ?? "\(file.path):\(messages.count)"
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seen.insert(id).inserted else { return }
            messages.append(.init(id: id, role: "thinking", text: text, date: date))
            return
          }
          guard type == "response_item", let role = payload["role"] as? String,
                role == "user" || role == "assistant" else { return }
          let parts = payload["content"] as? [[String: Any]] ?? []
          let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
          let id = payload["id"] as? String ?? "\(file.path):\(messages.count)"
          guard seen.insert(id).inserted else { return }
          messages.append(.init(id: id, role: role, text: text, date: date))
          if role == "user" { turnEvents.append((true, date)) }
        } else {
          if type == "cost-state" { cost = row["totalCostUSD"] as? Double; return }
          guard type == "user" || type == "assistant", row["isSidechain"] as? Bool != true else { return }
          if type == "assistant" { turnEvents.append((false, date)) }
          if let id = row["sessionId"] as? String { sessionID = id }
          cwd = cwd ?? row["cwd"] as? String
          let message = row["message"] as? [String: Any] ?? [:]
          if type == "assistant", let usage = message["usage"] as? [String: Any] {
            let model = message["model"] as? String ?? ""
            if let estimated = claudeEstimatedCost(model: model, usage: usage) {
              let key = message["id"] as? String ?? row["uuid"] as? String ?? "\(file.path):\(claudeMessageCosts.count)"
              claudeMessageCosts[key] = max(estimated, claudeMessageCosts[key] ?? 0)
              claudeMessageModels[key] = model
            } else if ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
              .contains(where: { ((usage[$0] as? NSNumber)?.doubleValue ?? 0) > 0 }) {
              claudeUnknownModel = true
              claudeUnpricedModels.insert(model.isEmpty ? "?" : model)
            }
          }
          let content = message["content"]
          var text: String
          var thinking = ""
          if let value = content as? String { text = value }
          else if let parts = content as? [[String: Any]] {
            text = parts.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            // Claude Code often stores thinking redacted (empty); only readable thinking reaches the chat.
            if full { thinking = parts.filter { ($0["type"] as? String) == "thinking" }.compactMap { $0["thinking"] as? String }.joined(separator: "\n\n") }
          } else { text = "" }
          if type == "user" { text = formatUserText(text) ?? "" }
          let id = row["uuid"] as? String ?? "\(file.path):\(messages.count)"
          for item in [AgentHistory.Message(id: id + "#thinking", role: "thinking", text: thinking, date: date),
                       AgentHistory.Message(id: id, role: type, text: text, date: date)]
          where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let index = claudeMessageIndex[item.id] {
              if item.text.count > messages[index].text.count { messages[index] = item }
            } else {
              claudeMessageIndex[item.id] = messages.count
              messages.append(item)
              if item.role == "user" { turnEvents.append((true, date)) }
            }
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
      var models: [AgentHistory.ModelCost] = []
      if provider == .codex, let model = codexModel {
        models = [AgentHistory.ModelCost(name: model, usd: cost)]
      } else if provider == .claude {
        var byModel: [String: Double] = [:]
        for (key, usd) in claudeMessageCosts { byModel[claudeMessageModels[key] ?? "?", default: 0] += usd }
        models = byModel.map { AgentHistory.ModelCost(name: $0.key, usd: $0.value) }
          + claudeUnpricedModels.subtracting(byModel.keys).map { AgentHistory.ModelCost(name: $0, usd: nil) }
      }
      let title = messages.first { $0.role == "user" && !$0.text.hasPrefix("[Skill loaded") }?.text
        .split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? tr("チャット")
      return AgentHistory(id: "\(provider.rawValue):\(sessionID)", provider: provider,
                          title: String(title.prefix(100)), date: messages.last?.date ?? .distantPast,
                          messages: messages, estimatedUSD: cost, project: cwd, source: full ? nil : file,
                          turns: turns(turnEvents), models: models)
  }

  /// Pairs each prompt with the last provider activity before the next prompt. Unanswered prompts are dropped.
  static func turns(_ events: [(user: Bool, date: Date)]) -> [DateInterval] {
    var result: [DateInterval] = []
    var start: Date?
    var end: Date?
    func close() {
      if let start, let end, end > start { result.append(DateInterval(start: start, end: end)) }
    }
    for event in events where event.date != .distantPast {
      if event.user {
        close()
        start = event.date
        end = nil
      } else if let start, event.date >= start {
        end = event.date
      }
    }
    close()
    return result
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
             json_extract(m.data, '$.role'), group_concat(json_extract(p.data, '$.text'), char(10)), s.directory,
             json_extract(p.data, '$.type') AS kind, json_extract(m.data, '$.modelID')
      FROM session s JOIN message m ON m.session_id = s.id
      JOIN part p ON p.message_id = m.id
      WHERE kind IN ('text', 'reasoning')
        AND s.time_updated >= \(Int64((period?.start ?? .distantPast).timeIntervalSince1970 * 1000))
        AND s.time_updated < \(Int64((period?.end ?? .distantFuture).timeIntervalSince1970 * 1000))
      GROUP BY m.id, kind
      ORDER BY s.time_updated DESC, m.time_created, MIN(p.id)
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
    defer { sqlite3_finalize(statement) }
    var sessions: [String: (String, Date, Double, [AgentHistory.Message], String?)] = [:]
    var sessionModels: [String: String] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let sid = sqlite3_column_text(statement, 0), let mid = sqlite3_column_text(statement, 4),
            let role = sqlite3_column_text(statement, 6), let body = sqlite3_column_text(statement, 7) else { continue }
      let id = String(cString: sid)
      let text = String(cString: body)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? tr("チャット")
      let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2)) / 1000)
      let cost = sqlite3_column_double(statement, 3)
      let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5)) / 1000)
      let reasoning = sqlite3_column_text(statement, 9).map { String(cString: $0) } == "reasoning"
      let message = AgentHistory.Message(id: String(cString: mid) + (reasoning ? "#thinking" : ""),
                                         role: reasoning ? "thinking" : String(cString: role), text: text, date: created)
      let directory = sqlite3_column_text(statement, 8).map { String(cString: $0) }
      if sessions[id] == nil { sessions[id] = (title, updated, cost, [], directory) }
      if let model = sqlite3_column_text(statement, 10) { sessionModels[id] = String(cString: model) }
      sessions[id]!.3.append(message)
    }
    return sessions.map { id, item in
      // ponytail: OpenCode reports one cost per session, so it all goes to the session's last model.
      AgentHistory(id: "OpenCode:\(id)", provider: .opencode, title: item.0,
                   date: item.1, messages: item.3, estimatedUSD: item.2, project: item.4,
                   turns: AgentHistoryReader.turns(item.3.map { (user: $0.role == "user", date: $0.date) }),
                   models: [.init(name: sessionModels[id] ?? "OpenCode", usd: item.2)])
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

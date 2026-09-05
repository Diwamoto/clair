import Darwin
import Foundation

enum AgentRateLimitProvider: String, CaseIterable, Identifiable, Sendable {
  case codex
  case claudeCode = "claude-code"
  case openCode = "opencode"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    case .openCode: "OpenCode"
    }
  }

  var shortName: String {
    switch self {
    case .claudeCode: "Claude"
    default: displayName
    }
  }

  var systemImage: String {
    switch self {
    case .codex: "sparkles"
    case .claudeCode: "brain.head.profile"
    case .openCode: "chevron.left.forwardslash.chevron.right"
    }
  }
}

struct AgentRateLimitWindow: Equatable, Identifiable, Sendable {
  let usedPercent: Double
  let durationMinutes: Int
  let resetsAt: Date

  var id: Int { durationMinutes }

  var remainingPercent: Int {
    Int((100 - usedPercent).rounded()).clamped(to: 0...100)
  }

  var displayName: String {
    switch durationMinutes {
    case 300:
      "5時間"
    case 10_080:
      "7日間"
    case let minutes where minutes.isMultiple(of: 1_440):
      "\(minutes / 1_440)日間"
    case let minutes where minutes.isMultiple(of: 60):
      "\(minutes / 60)時間"
    default:
      "\(durationMinutes)分間"
    }
  }

  func resetDescription(relativeTo now: Date = Date()) -> String {
    let remainingSeconds = max(0, Int(resetsAt.timeIntervalSince(now)))
    if remainingSeconds == 0 {
      return "まもなくリセット"
    }

    let days = remainingSeconds / 86_400
    let hours = (remainingSeconds % 86_400) / 3_600
    let minutes = max(1, (remainingSeconds % 3_600) / 60)
    if days > 0 {
      return "リセットまで \(days)日\(hours)時間"
    }
    if hours > 0 {
      return "リセットまで \(hours)時間\(minutes)分"
    }
    return "リセットまで \(minutes)分"
  }
}

struct AgentRateLimitSnapshot: Equatable, Identifiable, Sendable {
  let id: String
  let displayName: String
  let planType: String?
  let windows: [AgentRateLimitWindow]
  let fetchedAt: Date
  var detail: String? = nil

  var primaryWindow: AgentRateLimitWindow? { windows.first }
}

enum AgentRateLimitError: Error, Equatable, LocalizedError, Sendable {
  case codexUnavailable
  case timedOut
  case processFailed(String)
  case invalidResponse
  case requestFailed(String)
  case noRateLimits

  var errorDescription: String? {
    switch self {
    case .codexUnavailable:
      "Codex CLIが見つかりません。"
    case .timedOut:
      "Codexの使用量取得がタイムアウトしました。"
    case .processFailed(let message):
      message.isEmpty ? "Codex app-serverを起動できませんでした。" : message
    case .invalidResponse:
      "不正な使用量データが返されました。"
    case .requestFailed(let message):
      message
    case .noRateLimits:
      "このCodexアカウントでは使用量を取得できません。"
    }
  }
}

enum CodexRateLimitResponseParser {
  static func parse(
    _ data: Data,
    fetchedAt: Date = Date()
  ) throws -> [AgentRateLimitSnapshot] {
    let response: AppServerResponse
    do {
      response = try JSONDecoder().decode(AppServerResponse.self, from: data)
    } catch {
      throw AgentRateLimitError.invalidResponse
    }

    if let error = response.error {
      throw AgentRateLimitError.requestFailed(error.message)
    }
    guard let result = response.result else {
      throw AgentRateLimitError.invalidResponse
    }

    let buckets: [(String, RateLimitBucket)]
    if let byID = result.rateLimitsByLimitId, !byID.isEmpty {
      buckets = byID.sorted { left, right in
        if left.key == "codex" { return true }
        if right.key == "codex" { return false }
        return left.key < right.key
      }
    } else if let bucket = result.rateLimits {
      buckets = [(bucket.limitId, bucket)]
    } else {
      throw AgentRateLimitError.noRateLimits
    }

    let snapshots = buckets.compactMap { key, bucket -> AgentRateLimitSnapshot? in
      let windows = [bucket.primary, bucket.secondary].compactMap { rawWindow in
        rawWindow.map {
          AgentRateLimitWindow(
            usedPercent: $0.usedPercent.clamped(to: 0...100),
            durationMinutes: $0.windowDurationMins,
            resetsAt: Date(timeIntervalSince1970: $0.resetsAt)
          )
        }
      }
      guard !windows.isEmpty else { return nil }
      return AgentRateLimitSnapshot(
        id: bucket.limitId.isEmpty ? key : bucket.limitId,
        displayName: displayName(for: bucket, fallbackID: key),
        planType: bucket.planType,
        windows: windows,
        fetchedAt: fetchedAt
      )
    }

    guard !snapshots.isEmpty else {
      throw AgentRateLimitError.noRateLimits
    }
    return snapshots
  }

  private static func displayName(for bucket: RateLimitBucket, fallbackID: String) -> String {
    if let name = bucket.limitName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    {
      return name
    }
    let id = bucket.limitId.isEmpty ? fallbackID : bucket.limitId
    return id == "codex" ? "Codex" : id
  }

  private struct AppServerResponse: Decodable {
    let result: ResultPayload?
    let error: ResponseError?
  }

  private struct ResultPayload: Decodable {
    let rateLimits: RateLimitBucket?
    let rateLimitsByLimitId: [String: RateLimitBucket]?
  }

  private struct ResponseError: Decodable {
    let message: String
  }

  private struct RateLimitBucket: Decodable {
    let limitId: String
    let limitName: String?
    let primary: RateLimitWindowPayload?
    let secondary: RateLimitWindowPayload?
    let planType: String?
  }

  private struct RateLimitWindowPayload: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: TimeInterval
  }
}

enum ClaudeRateLimitResponseParser {
  static func parse(
    _ output: String,
    fetchedAt: Date = Date(),
    calendar: Calendar = .current
  ) -> AgentRateLimitSnapshot {
    let definitions: [(label: String, duration: Int)] = [
      ("Current session", 300),
      ("Current week (all models)", 10_080),
    ]
    let windows = definitions.compactMap { definition in
      parseWindow(
        named: definition.label,
        durationMinutes: definition.duration,
        in: output,
        fetchedAt: fetchedAt,
        calendar: calendar
      )
    }

    return AgentRateLimitSnapshot(
      id: AgentRateLimitProvider.claudeCode.id,
      displayName: AgentRateLimitProvider.claudeCode.displayName,
      planType: windows.isEmpty ? "API課金" : "Claude.ai",
      windows: windows,
      fetchedAt: fetchedAt,
      detail: windows.isEmpty ? "サブスクリプションのレート制限はありません" : nil
    )
  }

  private static func parseWindow(
    named label: String,
    durationMinutes: Int,
    in output: String,
    fetchedAt: Date,
    calendar: Calendar
  ) -> AgentRateLimitWindow? {
    let escapedLabel = NSRegularExpression.escapedPattern(for: label)
    let pattern =
      "(?im)^\\s*\(escapedLabel):?\\s*(?:[^\\n]*?\\s)?([0-9]+(?:\\.[0-9]+)?)% used(?:\\s*[·•-]\\s*resets\\s+([^\\r\\n]+))?"
    guard
      let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: output,
        range: NSRange(output.startIndex..., in: output)
      ),
      let percentRange = Range(match.range(at: 1), in: output),
      let usedPercent = Double(output[percentRange])
    else {
      return nil
    }

    let resetText: String?
    if match.range(at: 2).location != NSNotFound,
      let range = Range(match.range(at: 2), in: output)
    {
      resetText = String(output[range])
    } else {
      resetText = nil
    }
    let fallback = fetchedAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
    return AgentRateLimitWindow(
      usedPercent: usedPercent.clamped(to: 0...100),
      durationMinutes: durationMinutes,
      resetsAt: resetText.flatMap {
        parseResetDate($0, relativeTo: fetchedAt, calendar: calendar)
      } ?? fallback
    )
  }

  private static func parseResetDate(
    _ rawValue: String,
    relativeTo now: Date,
    calendar: Calendar
  ) -> Date? {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    var timeZone = calendar.timeZone
    if let zoneExpression = try? NSRegularExpression(pattern: #"\s*\(([^)]+)\)\s*$"#),
      let match = zoneExpression.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
      )
    {
      if let zoneRange = Range(match.range(at: 1), in: value),
        let parsedZone = TimeZone(identifier: String(value[zoneRange]))
      {
        timeZone = parsedZone
      }
      if let fullRange = Range(match.range(at: 0), in: value) {
        value.removeSubrange(fullRange)
      }
    }

    let datedFormats = ["MMM d 'at' h:mma", "MMM d, h:mma", "MMM d h:mma"]
    for format in datedFormats {
      let formatter = resetFormatter(format: format, timeZone: timeZone)
      formatter.defaultDate = now
      if let date = formatter.date(from: value) {
        var parsedCalendar = calendar
        parsedCalendar.timeZone = timeZone
        let year = parsedCalendar.component(.year, from: now)
        var components = parsedCalendar.dateComponents([.month, .day, .hour, .minute], from: date)
        components.year = year
        if let candidate = parsedCalendar.date(from: components) {
          return candidate >= now
            ? candidate
            : parsedCalendar.date(byAdding: .year, value: 1, to: candidate)
        }
      }
    }

    for format in ["h:mma", "ha"] {
      let formatter = resetFormatter(format: format, timeZone: timeZone)
      if let time = formatter.date(from: value) {
        var parsedCalendar = calendar
        parsedCalendar.timeZone = timeZone
        var components = parsedCalendar.dateComponents([.year, .month, .day], from: now)
        let timeComponents = parsedCalendar.dateComponents([.hour, .minute], from: time)
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        if let candidate = parsedCalendar.date(from: components) {
          return candidate > now
            ? candidate
            : parsedCalendar.date(byAdding: .day, value: 1, to: candidate)
        }
      }
    }
    return nil
  }

  private static func resetFormatter(format: String, timeZone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter
  }
}

enum OpenCodeRateLimitResponseParser {
  static func parse(
    _ data: Data,
    fetchedAt: Date = Date()
  ) throws -> AgentRateLimitSnapshot {
    let payload: Response
    do {
      payload = try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw AgentRateLimitError.invalidResponse
    }

    let definitions: [(key: String, duration: Int)] = [
      ("rolling", 300),
      ("weekly", 10_080),
      ("monthly", 43_200),
    ]
    let windows = definitions.compactMap { definition -> AgentRateLimitWindow? in
      guard let window = payload.usage[definition.key] else { return nil }
      return AgentRateLimitWindow(
        usedPercent: window.percent.clamped(to: 0...100),
        durationMinutes: definition.duration,
        resetsAt: Self.date(from: window.resetsAt)
          ?? fetchedAt.addingTimeInterval(TimeInterval(definition.duration * 60))
      )
    }
    guard !windows.isEmpty else {
      throw AgentRateLimitError.noRateLimits
    }
    return AgentRateLimitSnapshot(
      id: AgentRateLimitProvider.openCode.id,
      displayName: AgentRateLimitProvider.openCode.displayName,
      planType: "Go",
      windows: windows,
      fetchedAt: fetchedAt
    )
  }

  private static func date(from value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private struct Response: Decodable {
    let usage: [String: Window]
  }

  private struct Window: Decodable {
    let percent: Double
    let resetsAt: String
  }
}

struct AgentRateLimitFetchReport: Sendable {
  let snapshots: [AgentRateLimitSnapshot]
  let failures: [String: String]
}

struct AgentRateLimitClient: Sendable {
  var fetch: @Sendable () async -> AgentRateLimitFetchReport

  static let live = AgentRateLimitClient {
    await withTaskGroup(of: ProviderOutcome.self) { group in
      group.addTask {
        await outcome(for: .codex) {
          try CodexAppServerRateLimitRequest.fetch()
        }
      }
      group.addTask {
        await outcome(for: .claudeCode) {
          [try ClaudeRateLimitRequest.fetch()]
        }
      }
      group.addTask {
        await outcome(for: .openCode) {
          [try await OpenCodeRateLimitRequest.fetch()]
        }
      }

      var snapshots = [AgentRateLimitSnapshot]()
      var failures = [String: String]()
      for await result in group {
        snapshots.append(contentsOf: result.snapshots)
        if let message = result.failureMessage {
          failures[result.provider.id] = message
        }
      }
      let order = Dictionary(
        uniqueKeysWithValues: AgentRateLimitProvider.allCases.enumerated().map { ($1.id, $0) }
      )
      snapshots.sort {
        (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max)
      }
      return AgentRateLimitFetchReport(snapshots: snapshots, failures: failures)
    }
  }

  private struct ProviderOutcome: Sendable {
    let provider: AgentRateLimitProvider
    let snapshots: [AgentRateLimitSnapshot]
    let failureMessage: String?
  }

  private static func outcome(
    for provider: AgentRateLimitProvider,
    operation: @Sendable () async throws -> [AgentRateLimitSnapshot]
  ) async -> ProviderOutcome {
    do {
      return ProviderOutcome(
        provider: provider,
        snapshots: try await operation(),
        failureMessage: nil
      )
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      return ProviderOutcome(provider: provider, snapshots: [], failureMessage: message)
    }
  }
}

private enum CodexAppServerRateLimitRequest {
  private static let responseID = 1

  static func fetch(timeout: TimeInterval = 12) throws -> [AgentRateLimitSnapshot] {
    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "exec codex app-server"]
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError

    do {
      try process.run()
    } catch {
      throw AgentRateLimitError.codexUnavailable
    }

    defer {
      try? standardInput.fileHandleForWriting.close()
      if process.isRunning {
        process.terminate()
      }
      try? standardOutput.fileHandleForReading.close()
      try? standardError.fileHandleForReading.close()
    }

    let requests =
      [
        "{\"method\":\"initialize\",\"id\":0,\"params\":{\"clientInfo\":{\"name\":\"clair\",\"title\":\"Clair\",\"version\":\"0.1.0\"}}}",
        "{\"method\":\"initialized\",\"params\":{}}",
        "{\"method\":\"account/rateLimits/read\",\"id\":\(responseID)}",
      ].joined(separator: "\n") + "\n"
    try standardInput.fileHandleForWriting.write(contentsOf: Data(requests.utf8))

    let deadline = Date().addingTimeInterval(timeout)
    var buffer = Data()
    while Date() < deadline {
      let remainingMilliseconds = max(
        1,
        Int32(deadline.timeIntervalSinceNow * 1_000)
      )
      var descriptor = pollfd(
        fd: standardOutput.fileHandleForReading.fileDescriptor,
        events: Int16(POLLIN),
        revents: 0
      )
      let pollResult = Darwin.poll(&descriptor, 1, remainingMilliseconds)
      if pollResult == 0 {
        throw AgentRateLimitError.timedOut
      }
      if pollResult < 0 {
        if errno == EINTR { continue }
        throw AgentRateLimitError.processFailed("Codex app-serverから応答を読めませんでした。")
      }

      var bytes = [UInt8](repeating: 0, count: 8_192)
      let bytesRead = bytes.withUnsafeMutableBytes { storage in
        Darwin.read(
          standardOutput.fileHandleForReading.fileDescriptor,
          storage.baseAddress,
          storage.count
        )
      }
      if bytesRead < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        throw AgentRateLimitError.processFailed("Codex app-serverから応答を読めませんでした。")
      }
      if bytesRead == 0 {
        break
      }
      buffer.append(contentsOf: bytes.prefix(bytesRead))

      while let newline = buffer.firstRange(of: Data([0x0A])) {
        let line = buffer[..<newline.lowerBound]
        buffer.removeSubrange(...newline.lowerBound)
        guard let response = matchingResponse(in: Data(line)) else { continue }
        return try CodexRateLimitResponseParser.parse(response)
      }
    }

    if !process.isRunning {
      process.waitUntilExit()
      let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
      let message = String(decoding: errorData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if message.localizedCaseInsensitiveContains("command not found") {
        throw AgentRateLimitError.codexUnavailable
      }
      throw AgentRateLimitError.processFailed(message)
    }
    throw AgentRateLimitError.timedOut
  }

  private static func matchingResponse(in data: Data) -> Data? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = object["id"] as? NSNumber,
      id.intValue == responseID
    else {
      return nil
    }
    return data
  }
}

private enum ClaudeRateLimitRequest {
  static func fetch(timeout: TimeInterval = 12) throws -> AgentRateLimitSnapshot {
    let data = try ProcessOutputRequest.run(
      shellCommand: "exec claude -p '/usage'",
      toolName: "Claude Code",
      timeout: timeout
    )
    return ClaudeRateLimitResponseParser.parse(String(decoding: data, as: UTF8.self))
  }
}

private enum OpenCodeRateLimitRequest {
  static func fetch() async throws -> AgentRateLimitSnapshot {
    guard let apiKey = try apiKey() else {
      return AgentRateLimitSnapshot(
        id: AgentRateLimitProvider.openCode.id,
        displayName: AgentRateLimitProvider.openCode.displayName,
        planType: nil,
        windows: [],
        fetchedAt: Date(),
        detail: "OpenCode Goに接続されていません"
      )
    }

    guard let url = URL(string: "https://opencode.ai/zen/go/v1/usage") else {
      throw AgentRateLimitError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("Clair/0.1", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AgentRateLimitError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        throw AgentRateLimitError.requestFailed("OpenCode Goの認証を確認してください。")
      }
      throw AgentRateLimitError.requestFailed(
        "OpenCode Goから使用量を取得できませんでした（HTTP \(httpResponse.statusCode)）。"
      )
    }
    return try OpenCodeRateLimitResponseParser.parse(data)
  }

  private static func apiKey() throws -> String? {
    let authURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/opencode/auth.json")
    guard FileManager.default.fileExists(atPath: authURL.path) else { return nil }
    let data = try Data(contentsOf: authURL)
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let credential = root["opencode-go"] as? [String: Any],
      let key = credential["key"] as? String,
      !key.isEmpty
    else {
      return nil
    }
    return key
  }
}

private enum ProcessOutputRequest {
  static func run(
    shellCommand: String,
    toolName: String,
    timeout: TimeInterval
  ) throws -> Data {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", shellCommand]
    process.standardOutput = standardOutput
    process.standardError = standardError

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      throw AgentRateLimitError.processFailed("\(toolName) CLIが見つかりません。")
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      throw AgentRateLimitError.processFailed("\(toolName)の使用量取得がタイムアウトしました。")
    }
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      let message = String(decoding: errorOutput, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if message.localizedCaseInsensitiveContains("command not found") {
        throw AgentRateLimitError.processFailed("\(toolName) CLIが見つかりません。")
      }
      throw AgentRateLimitError.processFailed(
        message.isEmpty ? "\(toolName)から使用量を取得できませんでした。" : message
      )
    }
    return output
  }
}

@MainActor
final class AgentRateLimitCoordinator: ObservableObject {
  enum Phase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  @Published private(set) var snapshots: [AgentRateLimitSnapshot] = []
  @Published private(set) var phase: Phase = .idle

  @Published private(set) var failures: [String: String] = [:]

  private let client: AgentRateLimitClient
  private var refreshTask: Task<Void, Never>?
  private var automaticTask: Task<Void, Never>?

  init(client: AgentRateLimitClient = .live) {
    self.client = client
  }

  deinit {
    refreshTask?.cancel()
    automaticTask?.cancel()
  }

  func start() {
    guard automaticTask == nil else { return }
    refresh()
    automaticTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(120))
        guard !Task.isCancelled else { return }
        self?.refresh()
      }
    }
  }

  func stop() {
    automaticTask?.cancel()
    automaticTask = nil
  }

  func refresh() {
    guard refreshTask == nil else { return }
    phase = .loading
    let client = client
    refreshTask = Task { [weak self] in
      let report = await client.fetch()
      guard let self else { return }
      self.refreshTask = nil
      self.snapshots = report.snapshots
      self.failures = report.failures
      if report.snapshots.isEmpty, let message = report.failures.values.first {
        self.phase = .failed(message)
      } else {
        self.phase = .loaded
      }
    }
  }

  func snapshot(for provider: AgentRateLimitProvider) -> AgentRateLimitSnapshot? {
    snapshots.first { $0.id == provider.id }
  }

  func failureMessage(for provider: AgentRateLimitProvider) -> String? {
    failures[provider.id]
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}

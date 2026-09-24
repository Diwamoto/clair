import Foundation

/// H11: AI provider usage windows for the status bar, read from each provider's own API — never scraped from its TUI.
/// A provider Clair cannot read says so; it never gets a made-up number.
struct ProviderQuota: Sendable, Equatable {
  struct Window: Sendable, Equatable {
    let minutes: Int
    let usedPercent: Double
    let resetsAt: Date

    var remainingPercent: Int { Int((100 - usedPercent).rounded()) }

    var label: String {
      switch minutes {
      case ProviderQuota.monthMinutes: "1か月"
      case let m where m.isMultiple(of: 1440): "\(m / 1440)日間"
      case let m where m.isMultiple(of: 60): "\(m / 60)時間"
      default: "\(minutes)分間"
      }
    }

    func resetText(now: Date) -> String {
      let s = max(0, Int(resetsAt.timeIntervalSince(now)))
      let d = s / 86400
      let h = s % 86400 / 3600
      let m = s % 3600 / 60
      if s == 0 { return "まもなくリセット" }
      if d > 0 { return "リセットまで \(d)日\(h)時間" }
      return h > 0 ? "リセットまで \(h)時間\(m)分" : "リセットまで \(max(m, 1))分"
    }
  }

  enum State: Sendable, Equatable {
    case ok([Window])
    /// The provider was asked and could not answer (not installed, signed out, timed out).
    case unavailable(String)
    /// Clair has no sanctioned source for this provider yet.
    case unsupported(String)
  }

  let provider: String
  let state: State
  let fetchedAt: Date
  /// A throttled provider (HTTP 429) is not asked again before this.
  var notBefore: Date? = nil

  /// Older than two refresh intervals: the numbers may no longer be true (e.g. after sleep).
  func isStale(now: Date) -> Bool { now.timeIntervalSince(fetchedAt) > 600 }

  func summary(now: Date) -> String {
    switch state {
    case .ok(let windows):
      let parts = windows.map {
        "\($0.label) 残り\($0.remainingPercent)% · \($0.resetText(now: now))"
      }
      let time = fetchedAt.formatted(date: .omitted, time: .shortened)
      return "\(provider): " + parts.joined(separator: " / ")
        + (isStale(now: now) ? "(古い値 · \(time) 取得)" : "(\(time) 取得)")
    case .unavailable(let why): return "\(provider): 取得できません — \(why)"
    case .unsupported(let why): return "\(provider): 未対応 — \(why)"
    }
  }

  /// The window closest to running out across every provider that answered — what the status bar shows.
  static func tightest(_ all: [ProviderQuota]) -> (provider: String, window: Window)? {
    all.flatMap { q -> [(String, Window)] in
      if case .ok(let ws) = q.state { ws.map { (q.provider, $0) } } else { [] }
    }.max { $0.1.usedPercent < $1.1.usedPercent }
  }

  /// OpenCode Go's monthly window renews on the subscription day, not every 30 days; this only names it.
  static let monthMinutes = 43200

  /// Codex blocks (spawns a process), so the caller runs this off the main actor.
  /// `previous` carries a throttled provider's last answer forward instead of asking again.
  static func fetchAll(previous: [ProviderQuota] = [], now: Date = Date()) async -> [ProviderQuota] {
    [
      ProviderQuota(provider: "Codex", state: codex(), fetchedAt: now),
      await claudeCode(previous: previous.first { $0.provider == "Claude Code" }, now: now),
      ProviderQuota(provider: "OpenCode", state: await openCode(), fetchedAt: now),
    ]
  }

  /// Claude Code's own `/usage` source: the undocumented `api.anthropic.com/api/oauth/usage`, authorized with the
  /// OAuth token Claude Code keeps in the login Keychain (owner-approved 2026-09-23, as Orca/CodexBar do).
  /// Only `claudeAiOauth.accessToken` is kept from that item; the token goes only to api.anthropic.com.
  static func claudeCode(previous: ProviderQuota?, now: Date, timeout: TimeInterval = 12) async -> ProviderQuota {
    if let previous, let notBefore = previous.notBefore, now < notBefore { return previous }
    func answer(_ state: State) -> ProviderQuota { ProviderQuota(provider: "Claude Code", state: state, fetchedAt: now) }
    guard let oauth = claudeCredentials()?["claudeAiOauth"] as? [String: Any],
      let token = oauth["accessToken"] as? String, !token.isEmpty
    else { return answer(.unavailable("Claude Code にログインしていません")) }
    if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue, expires / 1000 < now.timeIntervalSince1970 {
      return answer(.unavailable("Claude Code のログインが期限切れです(claude を一度起動すると更新されます)"))
    }
    var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: timeout)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    // ponytail: fixed Claude Code UA — without one the endpoint's bucket 429s at once; read `claude --version` if a pinned one stops working.
    request.setValue("claude-code/2.1.280", forHTTPHeaderField: "User-Agent")
    guard let (body, response) = try? await URLSession.shared.data(for: request),
      let http = response as? HTTPURLResponse
    else { return answer(.unavailable("api.anthropic.com に接続できません")) }
    switch http.statusCode {
    case 200: return answer(parseClaude(body))
    case 401, 403: return answer(.unavailable("Claude Code の認証に失敗しました(\(http.statusCode))"))
    case 429:
      // Keep the last numbers (they turn stale on their own) and stay away until the server says so.
      let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 900
      var held = previous ?? answer(.unavailable("利用枠 API の呼び出し制限中です"))
      held.notBefore = now.addingTimeInterval(max(wait, 300))
      return held
    default: return answer(.unavailable("api.anthropic.com が HTTP \(http.statusCode) を返しました"))
    }
  }

  /// The Keychain item Claude Code writes on macOS (via `security`, so reading it the same way needs no prompt),
  /// or `~/.claude/.credentials.json` where Claude Code keeps it as a file.
  static func claudeCredentials() -> [String: Any]? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    var data: Data?
    if (try? process.run()) != nil {
      data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      if process.terminationStatus != 0 { data = nil }
    }
    data = data ?? (try? Data(
      contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")))
    return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
  }

  /// `five_hour` / `seven_day`: `{"utilization":0-100,"resets_at":ISO-8601}`, recorded 2026-09-23.
  /// ponytail: per-model weekly windows (`seven_day_opus`/`_sonnet`) are skipped; add them with their own labels if needed.
  static func parseClaude(_ body: Data) -> State {
    let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    let windows = [("five_hour", 300), ("seven_day", 10080)].compactMap { name, minutes -> Window? in
      guard let w = o?[name] as? [String: Any],
        let used = (w["utilization"] as? NSNumber)?.doubleValue,
        let reset = (w["resets_at"] as? String).flatMap(isoDate)
      else { return nil }
      return Window(minutes: minutes, usedPercent: min(max(used, 0), 100), resetsAt: reset)
    }
    return windows.isEmpty ? .unavailable("このアカウントには利用枠の情報がありません") : .ok(windows)
  }

  static func isoDate(_ s: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.date(from: s)
  }

  /// OpenCode Go's usage endpoint, authorized with the Go key OpenCode itself stored (owner-approved 2026-09-23).
  /// The key goes only to opencode.ai over HTTPS — the host OpenCode already sends it to.
  static func openCode(timeout: TimeInterval = 12) async -> State {
    let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share")
    guard let file = try? Data(contentsOf: data.appending(path: "opencode/auth.json")),
      let auth = try? JSONSerialization.jsonObject(with: file) as? [String: Any],
      let key = (auth["opencode-go"] as? [String: Any])?["key"] as? String, !key.isEmpty
    else { return .unavailable("OpenCode Go にログインしていません(opencode auth login)") }
    var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!, timeoutInterval: timeout)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    guard let (body, response) = try? await URLSession.shared.data(for: request),
      let status = (response as? HTTPURLResponse)?.statusCode
    else { return .unavailable("opencode.ai に接続できません") }
    switch status {
    case 200: return parseOpenCode(body)
    case 401, 403: return .unavailable("OpenCode Go の認証に失敗しました(\(status))")
    default: return .unavailable("opencode.ai が HTTP \(status) を返しました")
    }
  }

  /// `{"usage":{"rolling"|"weekly"|"monthly":{"percent":0-100,"resetsAt":ISO-8601}}}`, recorded 2026-09-23.
  static func parseOpenCode(_ body: Data) -> State {
    let usage = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["usage"] as? [String: Any]
    let windows = [("rolling", 300), ("weekly", 10080), ("monthly", monthMinutes)].compactMap {
      name, minutes -> Window? in
      guard let w = usage?[name] as? [String: Any],
        let used = (w["percent"] as? NSNumber)?.doubleValue,
        let reset = (w["resetsAt"] as? String).flatMap(isoDate)
      else { return nil }
      return Window(minutes: minutes, usedPercent: min(max(used, 0), 100), resetsAt: reset)
    }
    return windows.isEmpty ? .unavailable("このアカウントには利用枠の情報がありません") : .ok(windows)
  }

  /// Codex's own app-server protocol: `account/rateLimits/read` over stdio JSON-RPC.
  static func codex(timeout: TimeInterval = 12) -> State {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    // Login shell, so PATH matches the user's terminal (the same way agents are launched).
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "exec codex app-server"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return .unavailable("Codex を起動できません") }
    let requests = [
      #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"clair","title":"Clair","version":"0.1.0"}}}"#,
      #"{"method":"initialized","params":{}}"#,
      #"{"method":"account/rateLimits/read","id":1}"#,
    ]
    try? input.fileHandleForWriting.write(
      contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
    // Terminating the process closes stdout, which ends the read loop below.
    let watchdog = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    defer {
      watchdog.cancel()
      if process.isRunning { process.terminate() }
      try? input.fileHandleForWriting.close()
    }
    var buffer = Data()
    while true {
      let chunk = output.fileHandleForReading.availableData
      if chunk.isEmpty { break }
      buffer.append(chunk)
      while let nl = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<nl]
        buffer.removeSubrange(buffer.startIndex...nl)
        if let state = parseCodex(Data(line)) { return state }
      }
    }
    return .unavailable("Codex CLI が見つからないか応答しません")
  }

  /// The `account/rateLimits/read` response line, or nil for any other line (notifications, the initialize reply).
  static func parseCodex(_ line: Data) -> State? {
    guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      (o["id"] as? NSNumber)?.intValue == 1
    else {
      return nil
    }
    if let error = o["error"] as? [String: Any] {
      return .unavailable(error["message"] as? String ?? "取得に失敗しました")
    }
    let limits = (o["result"] as? [String: Any])?["rateLimits"] as? [String: Any]
    let windows = ["primary", "secondary"].compactMap { limits?[$0] as? [String: Any] }.compactMap {
      w -> Window? in
      guard let used = (w["usedPercent"] as? NSNumber)?.doubleValue,
        let minutes = (w["windowDurationMins"] as? NSNumber)?.intValue,
        let reset = (w["resetsAt"] as? NSNumber)?.doubleValue
      else { return nil }
      return Window(
        minutes: minutes, usedPercent: min(max(used, 0), 100),
        resetsAt: Date(timeIntervalSince1970: reset))
    }
    return windows.isEmpty ? .unavailable("このアカウントには利用枠の情報がありません") : .ok(windows)
  }
}

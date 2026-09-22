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

  /// Blocking (spawns a process): call off the main actor.
  static func fetchAll(now: Date = Date()) -> [ProviderQuota] {
    [
      ProviderQuota(provider: "Codex", state: codex(), fetchedAt: now),
      // ponytail: Claude Code exposes `rate_limits` only to a statusLine command, so reading it means launching `claude`
      // with an injected `--settings` hook (ADR-0002 runs the agent TUI unmodified) — pending an owner decision.
      ProviderQuota(
        provider: "Claude Code", state: .unsupported("statusLine hook 未接続"), fetchedAt: now),
      // ponytail: OpenCode has no local usage API; its Go plan's HTTP usage endpoint needs the user's key. Add with that decision.
      ProviderQuota(provider: "OpenCode", state: .unsupported("利用枠 API なし"), fetchedAt: now),
    ]
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

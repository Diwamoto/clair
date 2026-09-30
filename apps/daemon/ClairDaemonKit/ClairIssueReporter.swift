#if os(macOS)

  import ClairWorkspace
  import Darwin
  import Foundation

  /// ADR-0021: anomalies (terminal disconnects and stalls, failed updates, crashes) become GitHub
  /// issues on `Diwamoto/clair`, filed through the user's own `gh` login. Nothing is embedded: no
  /// token, no relay. One title is one issue; a repeat adds a comment, at most once a day per Mac.
  public enum ClairIssueReporter {
    public static let repository = "Diwamoto/clair"
    static let quietPeriod: TimeInterval = 24 * 3600
    static let crashScanKey = "crash-scan"
    static let crashProcesses = ["ClairMacApp", "ClairDaemon", "clair"]

    /// Only the installed Stable app (and the daemon/CLI inside it) reports; Dev, `make dev`,
    /// tests and SwiftPM binaries never do.
    static var isEnabled: Bool {
      ClairChannel.current == .stable
        && (Bundle.main.executablePath ?? "").hasPrefix("/Applications/\(ClairChannel.stable.displayName).app/")
    }

    static var stateURL: URL { ClairChannel.current.dataURL.appending(path: "issue-reports.json") }

    /// `title` names the anomaly without run-specific values so repeats land on one issue.
    /// Blocks while `gh` runs; `reportInBackground` is the fire-and-forget form.
    public static func report(_ title: String, _ details: String) {
      guard isEnabled, claim(title) else { return }
      post(title: "[auto] \(title)", body: redact(details + "\n\n" + systemContext()))
    }

    public static func reportInBackground(_ title: String, _ details: String) {
      Thread.detachNewThread { report(title, details) }
    }

    /// Error case name without associated values, so `controlSocketSetup("…")` still dedups;
    /// a Foundation error (URLError, CocoaError) is its domain and code.
    public static func kind(of error: Error) -> String {
      let text = String(describing: error)
      if text.hasPrefix("Error Domain=") {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
      }
      return String(text.prefix { $0 != "(" })
    }

    // MARK: crashes

    /// Files every Clair crash report written since the last scan. The first scan on a Mac only
    /// sets the mark, so crashes from before this feature existed are not filed.
    public static func reportNewCrashes(
      in directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/DiagnosticReports")
    ) {
      guard isEnabled else { return }
      let since = withState { state -> Date? in
        defer { state[crashScanKey] = Date() }
        return state[crashScanKey]
      }
      guard let since else { return }
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      for file in files where file.pathExtension == "ips" {
        guard crashProcesses.contains(where: { file.lastPathComponent.hasPrefix($0 + "-") }),
          let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate, modified > since,
          let text = try? String(contentsOf: file, encoding: .utf8),
          let crash = crashSummary(ips: text)
        else { continue }
        report(crash.title, crash.details)
      }
    }

    /// An `.ips` file is a one-line JSON header followed by the JSON report.
    static func crashSummary(ips: String) -> (title: String, details: String)? {
      let parts = ips.split(separator: "\n", maxSplits: 1)
      guard parts.count == 2,
        let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
        let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any]
      else { return nil }
      let process = body["procName"] as? String ?? header["name"] as? String ?? "?"
      let exception = body["exception"] as? [String: Any] ?? [:]
      let type = [exception["type"], exception["signal"]].compactMap { $0 as? String }
        .joined(separator: " ")
      let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
      let threads = body["threads"] as? [[String: Any]] ?? []
      let faulting = body["faultingThread"] as? Int ?? 0
      let frames = (faulting < threads.count ? threads[faulting]["frames"] as? [[String: Any]] : nil) ?? []
      let lines = frames.prefix(25).map { frame -> String in
        let index = frame["imageIndex"] as? Int ?? -1
        let image = images.indices.contains(index) ? images[index] : "?"
        if let symbol = frame["symbol"] as? String { return "\(image)  \(symbol)" }
        return "\(image) + \(frame["imageOffset"] as? Int ?? 0)"
      }
      // The first frame in a Clair binary says where it broke; system frames are the same for
      // every fatalError / force-unwrap.
      let site = lines.first { line in crashProcesses.contains { line.hasPrefix($0 + " ") } }
      let messages = (body["asi"] as? [String: [String]])?.values.flatMap { $0 } ?? []
      var details = """
        `\(process)` crashed (\(header["app_version"] as? String ?? "?"), \(header["timestamp"] as? String ?? "?")).

        - exception: \(type.isEmpty ? "?" : type)
        """
      if let termination = body["termination"] as? [String: Any], let indicator = termination["indicator"] {
        details += "\n- termination: \(indicator)"
      }
      for message in messages { details += "\n- message: \(message)" }
      details += "\n\nCrashed thread:\n```\n\(lines.joined(separator: "\n"))\n```"
      return ("crash: \(process) \(type)\(site.map { " at \($0)" } ?? "")", details)
    }

    // MARK: posting

    /// Records `title` as reported unless it already was within `quietPeriod`. Recording before
    /// posting means a failing `gh` cannot turn into a retry storm.
    static func claim(_ title: String, now: Date = Date(), at url: URL = stateURL) -> Bool {
      withState(at: url) { state in
        if let last = state[title], now.timeIntervalSince(last) < quietPeriod { return false }
        state[title] = now
        return true
      }
    }

    /// Several `clair attach` processes can hit the same stall at once; the flock serializes them.
    static func withState<T>(at url: URL = stateURL, _ body: (inout [String: Date]) -> T) -> T {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let lock = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      if lock >= 0 { flock(lock, LOCK_EX) }
      defer { if lock >= 0 { Darwin.close(lock) } }
      var state =
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) }
        ?? [:]
      let result = body(&state)
      try? JSONEncoder().encode(state).write(to: url, options: .atomic)
      return result
    }

    /// Posts with `gh` when its login can push to the repository (the owner). Anyone else gets the
    /// pre-filled new-issue page instead, so Clair never files under a stranger's account.
    static func post(title: String, body: String) {
      if let gh = ghExecutable(), run(gh, ["api", "repos/\(repository)", "--jq", ".permissions.push"]) == "true" {
        let existing = run(
          gh, ["issue", "list", "-R", repository, "--state", "open", "--search", "\"\(title)\" in:title",
               "--json", "number,title", "--limit", "20"])
          .flatMap { try? JSONDecoder().decode([Issue].self, from: Data($0.utf8)) }?
          .first { $0.title == title }
        let posted =
          if let existing {
            run(gh, ["issue", "comment", String(existing.number), "-R", repository, "--body-file", "-"], input: body)
          } else {
            run(gh, ["issue", "create", "-R", repository, "--title", title, "--body-file", "-"], input: body)
          }
        if posted != nil { return }
      }
      var page = URLComponents(string: "https://github.com/\(repository)/issues/new")!
      // A browser URL tops out around 8 KB.
      page.queryItems = [.init(name: "title", value: title), .init(name: "body", value: String(body.prefix(6_000)))]
      if let url = page.url { _ = run(URL(fileURLWithPath: "/usr/bin/open"), [url.absoluteString]) }
    }

    private struct Issue: Decodable {
      let number: Int
      let title: String
    }

    /// A GUI app's PATH has no Homebrew, so look where `gh` is normally installed.
    static func ghExecutable() -> URL? {
      let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
      return (["/opt/homebrew/bin", "/usr/local/bin"] + path)
        .map { URL(fileURLWithPath: $0).appending(path: "gh") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Output of a successful run (trimmed), nil when it fails to start or exits non-zero.
    static func run(_ executable: URL, _ arguments: [String], input: String? = nil) -> String? {
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      var environment = ProcessInfo.processInfo.environment
      environment["GH_PROMPT_DISABLED"] = "1"
      environment["NO_COLOR"] = "1"
      process.environment = environment
      let stdout = Pipe()
      let stdin = Pipe()
      process.standardOutput = stdout
      process.standardError = FileHandle.nullDevice
      process.standardInput = input == nil ? FileHandle.nullDevice : stdin
      guard (try? process.run()) != nil else { return nil }
      if let input {
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
      }
      let output = stdout.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: context

    /// Paths carry the user name; the repository is public.
    static func redact(_ text: String) -> String {
      text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Version, OS and power history: most stalls so far line up with sleep/wake or throttling.
    static func systemContext(now: Date = Date()) -> String {
      let info = ProcessInfo.processInfo
      let bundle = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Info.plist")
      let version = bundle.flatMap { NSDictionary(contentsOf: $0)?["CFBundleShortVersionString"] as? String } ?? "?"
      func ago(_ name: String) -> String {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return "never" }
        return "\(Int(now.timeIntervalSince1970) - value.tv_sec) s ago"
      }
      return """
        <details><summary>Environment</summary>

        - Clair \(version) (\(Bundle.main.executableURL?.lastPathComponent ?? "?"))
        - \(info.operatingSystemVersionString), \(info.processorCount) cores
        - reported: \(ISO8601DateFormatter().string(from: now))
        - uptime: \(Int(info.systemUptime)) s, last sleep: \(ago("kern.sleeptime")), last wake: \(ago("kern.waketime"))
        - thermal state: \(info.thermalState.rawValue), low power mode: \(info.isLowPowerModeEnabled)

        </details>
        """
    }
  }

#endif

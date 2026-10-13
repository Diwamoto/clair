import ClairDaemonKit
import ClairShared
import ClairWorkspace
import Foundation

/// "前回のクラッシュを調査": everything Clair knows about its last failures, in one file an agent can read.
/// AppKit catches an exception thrown while handling an event, logs `<private>` and keeps going, so a
/// broken window just disappears and macOS writes no crash report. `recordException` keeps those.
public enum ClairCrashInvestigation {
  public static var exceptionLog: URL { ClairChannel.current.dataURL.appending(path: "exceptions.log") }

  /// Called from the app's `NSApplication.reportException`. Appends; the log restarts past 1 MB.
  public static func recordException(name: String, reason: String?, stack: [String], at url: URL = exceptionLog) {
    let entry = "## \(ISO8601DateFormatter().string(from: Date())) \(name)\n\(reason ?? "")\n\n"
      + stack.joined(separator: "\n") + "\n\n"
    let fm = FileManager.default
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    if size < 1_000_000, let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(entry.utf8))
    } else {
      try? Data(entry.utf8).write(to: url, options: .atomic)
    }
  }

  /// The report: exceptions AppKit swallowed, the newest crash reports, ADR-0021 anomaly history, and
  /// Clair's error/fault lines from the system log. Blocking (`log show` takes seconds); call off main.
  public static func report(
    exceptions: URL = exceptionLog,
    crashes: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports"),
    anomalies: URL = ClairChannel.current.dataURL.appending(path: "issue-reports.json"),
    systemLog: () -> String = recentSystemLog
  ) -> String {
    var out = "# Clair crash investigation\n\n- created: \(ISO8601DateFormatter().string(from: Date()))\n"
      + "- app: \(Bundle.main.executablePath ?? "?") (\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))\n"

    let swallowed = (try? String(contentsOf: exceptions, encoding: .utf8)).map { String($0.suffix(20_000)) }
    out += "\n# Exceptions AppKit caught (window vanished, no crash report)\n\n" + (swallowed ?? "none recorded\n")

    let ips = ((try? FileManager.default.contentsOfDirectory(
      at: crashes, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
      .filter { file in
        file.pathExtension == "ips"
          && ClairIssueReporter.crashProcesses.contains { file.lastPathComponent.hasPrefix($0 + "-") }
      }
      .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
      .sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    out += "\n# Newest crash reports\n\n"
    if ips.isEmpty { out += "none\n" }
    for file in ips {
      let summary = (try? String(contentsOf: file, encoding: .utf8)).flatMap(ClairIssueReporter.crashSummary)
      out += "## \(file.path)\n\n\(summary?.details ?? "unparsable")\n\n"
    }

    let history = (try? Data(contentsOf: anomalies))
      .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    out += "\n# Anomalies reported (ADR-0021, last occurrence)\n\n"
    out += history.isEmpty ? "none\n" : history.sorted { $0.value > $1.value }
      .map { "- \(ISO8601DateFormatter().string(from: $0.value)) \($0.key)" }.joined(separator: "\n") + "\n"

    out += "\n# System log: Clair errors and faults, last 2 hours\n\n```\n\(systemLog())\n```\n"
    return out
  }

  public static func recentSystemLog() -> String {
    let predicate = #"(process == "ClairMacApp" OR process == "ClairDaemon" OR process == "clair")"#
      + " AND (messageType == error OR messageType == fault)"
    // ponytail: last 400 lines, unfiltered noise included; filter known-benign subsystems if it gets drowned.
    let lines = ClairIssueReporter.run(
      URL(fileURLWithPath: "/usr/bin/log"), ["show", "--last", "2h", "--style", "compact", "--predicate", predicate]
    )?.split(separator: "\n").suffix(400) ?? ["log show failed"]
    return lines.joined(separator: "\n")
  }

  /// The agent's opening prompt for a report at `path`.
  static func prompt(report path: String) -> String {
    "Clair のクラッシュ・ウインドウ消失・異常を調査してください。収集した情報: \(path) 。"
      + "例外やスタックからこのリポジトリの原因箇所を特定し、再現手順と修正案を日本語で報告してください。"
      + "このリポジトリが Clair のソースでなければ、レポートの要約だけしてください。"
  }
}

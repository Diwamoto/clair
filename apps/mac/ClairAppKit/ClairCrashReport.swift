import ClairShared
import AppKit
import Foundation

/// On launch, offers to file a GitHub issue for a crash macOS recorded since the last check. The report is
/// cut down to exception + the crashed thread's top frames and opened as a prefilled "new issue" page, so
/// nothing leaves the machine until the owner presses Submit themselves.
/// ponytail: newest crash only, no dedupe; add grouping if crashes get frequent.
public enum ClairCrashReport {
  static let repo = "https://github.com/Diwamoto/clair/issues/new"
  static let seenKey = "ClairCrashReport.lastSeen"

  @MainActor public static func offerIfCrashed() {
    let defaults = UserDefaults.standard
    let last = defaults.object(forKey: seenKey) as? Date
    defaults.set(Date(), forKey: seenKey)
    // First run with this feature: only mark the baseline, do not report old crashes.
    guard let last, let (file, date) = newestReport(after: last),
      let text = try? String(contentsOf: file, encoding: .utf8), let body = summary(ips: text)
    else { return }
    let alert = NSAlert()
    alert.messageText = tr("前回 Clair がクラッシュしました")
    alert.informativeText = tr("%@ のクラッシュレポートから GitHub issue を作成しますか？ブラウザで内容を確認してから送信できます。", date.formatted())
    alert.addButton(withTitle: tr("issue を作成"))
    alert.addButton(withTitle: tr("閉じる"))
    guard alert.runModal() == .alertFirstButtonReturn, let url = issueURL(body: body) else { return }
    NSWorkspace.shared.open(url)
  }

  static func newestReport(after date: Date) -> (URL, Date)? {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
    let files = (try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return files.compactMap { url -> (URL, Date)? in
      guard url.lastPathComponent.hasPrefix("ClairMacApp"), url.pathExtension == "ips",
        let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > date
      else { return nil }
      return (url, d)
    }.max { $0.1 < $1.1 }
  }

  /// `.ips` = one JSON header line + a JSON body. Returns a Markdown issue body, or nil if unparsable.
  static func summary(ips: String, maxFrames: Int = 20) -> String? {
    guard let split = ips.firstIndex(of: "\n"),
      let header = try? JSONSerialization.jsonObject(with: Data(ips[..<split].utf8)) as? [String: Any],
      let body = try? JSONSerialization.jsonObject(with: Data(ips[split...].utf8)) as? [String: Any]
    else { return nil }
    let exception = body["exception"] as? [String: Any] ?? [:]
    let images = body["usedImages"] as? [[String: Any]] ?? []
    let threads = body["threads"] as? [[String: Any]] ?? []
    let crashed = threads.first { $0["triggered"] as? Bool == true } ?? threads.first ?? [:]
    let frames = (crashed["frames"] as? [[String: Any]] ?? []).prefix(maxFrames).enumerated().map { i, f in
      let image = (f["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil }
      let symbol = f["symbol"] as? String ?? "?"
      let source = (f["sourceFile"] as? String).map { " (\($0)\((f["sourceLine"] as? Int).map { ":\($0)" } ?? ""))" } ?? ""
      return "\(i) \(image ?? "?") \(symbol)\(source)"
    }
    var lines = [
      "## Crash", "",
      "- version: \(header["app_version"] as? String ?? "?")",
      "- os: \(header["os_version"] as? String ?? "?")",
      "- time: \(header["timestamp"] as? String ?? "?")",
      "- exception: \(exception["type"] as? String ?? "?") \(exception["signal"] as? String ?? "")",
    ]
    // fatalError / precondition messages land here.
    if let asi = body["asi"] as? [String: [String]] {
      lines.append("- message: \(asi.values.flatMap { $0 }.joined(separator: " / ").prefix(500))")
    }
    lines += ["", "## Crashed thread", "", "```", frames.joined(separator: "\n"), "```", "", "## What I was doing", "", ""]
    return lines.joined(separator: "\n")
  }

  static func issueURL(body: String) -> URL? {
    var c = URLComponents(string: repo)
    // GitHub rejects very long URLs; the frame list is already capped, this is the backstop.
    c?.queryItems = [.init(name: "title", value: "Crash: "), .init(name: "labels", value: "bug"),
                     .init(name: "body", value: String(body.prefix(6000)))]
    return c?.url
  }
}

import Foundation

/// #72: a time of day (on some weekdays) at which Clair launches an agent pane in `project`, or types `prompt`
/// into the existing pane `key`. Kept in `~/.clair/schedules.json`; fires only while Clair runs.
public struct ClairSchedule: Codable, Equatable, Sendable {
  public var id: String
  /// Calendar weekdays (1 = Sunday … 7 = Saturday); empty means every day.
  public var days: [Int]
  public var hour: Int
  public var minute: Int
  public var project: String
  /// New pane with this launch profile; nil means `agent.send` to `key`.
  public var profile: String?
  public var key: String?
  public var prompt: String
  /// A run missed while the Mac slept or Clair was not running: run it once on return (true) or skip it.
  public var catchUp: Bool
  /// The last scheduled time handled (run or skipped); set to the creation time on add.
  public var lastRun: Date

  /// A fire this late is still "on time"; beyond it the run counts as missed.
  static let grace: TimeInterval = 120

  public enum Decision: Equatable { case wait, run(Date), skip(Date) }

  /// The most recent scheduled time at or before `now` (looks back 8 days).
  public func latestFire(atOrBefore now: Date, calendar: Calendar = .current) -> Date? {
    let today = calendar.startOfDay(for: now)
    for back in 0...7 {
      guard let day = calendar.date(byAdding: .day, value: -back, to: today),
            days.isEmpty || days.contains(calendar.component(.weekday, from: day)),
            let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), fire <= now else { continue }
      return fire
    }
    return nil
  }

  public func decide(now: Date, calendar: Calendar = .current) -> Decision {
    guard let fire = latestFire(atOrBefore: now, calendar: calendar), fire > lastRun else { return .wait }
    return now.timeIntervalSince(fire) <= Self.grace || catchUp ? .run(fire) : .skip(fire)
  }

  /// `"weekdays"`, `"daily"`/empty, or comma-separated `mon,tue,…`; nil when a name is unknown.
  public static func parseDays(_ text: String) -> [Int]? {
    let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    switch text.lowercased().trimmingCharacters(in: .whitespaces) {
    case "", "daily": return []
    case "weekdays": return [2, 3, 4, 5, 6]
    case let list:
      let days = list.split(separator: ",").map { names.firstIndex(of: $0.trimmingCharacters(in: .whitespaces)).map { $0 + 1 } }
      return days.contains(nil) ? nil : Array(Set(days.compactMap { $0 })).sorted()
    }
  }

  /// `HH:MM` (24 h).
  public static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
    let parts = text.split(separator: ":").map { Int($0) }
    guard parts.count == 2, let h = parts[0], let m = parts[1], (0..<24).contains(h), (0..<60).contains(m) else { return nil }
    return (h, m)
  }

  public var json: [String: Any] {
    var out: [String: Any] = [
      "id": id, "time": String(format: "%02d:%02d", hour, minute), "days": days, "project": project,
      "prompt": prompt, "catchUp": catchUp,
    ]
    if let profile { out["profile"] = profile }
    if let key { out["key"] = key }
    return out
  }

  public static func url(home: URL = .homeDirectory) -> URL { home.appending(path: ".clair/schedules.json") }

  public static func load(_ url: URL = url()) -> [ClairSchedule] {
    (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([ClairSchedule].self, from: $0) } ?? []
  }

  public static func save(_ all: [ClairSchedule], _ url: URL = url()) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(all).write(to: url, options: .atomic)
  }
}

import Foundation

// UI language (Settings → General → Language). English is the default; Japanese is the other choice.
// ponytail: in-code string tables keyed by the source literal (UI code is written in either language);
// move to String Catalogs when a third language or translators outside the repo arrive.

public enum ClairLanguage: String, Sendable, CaseIterable {
  case english = "English", japanese = "日本語"

  private static let lock = NSLock()
  nonisolated(unsafe) private static var value = ClairLanguage.english
  public static var current: ClairLanguage {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}

/// The UI string for `key` in the current language, `%@` filled from `args` in order.
/// A key missing from the table shows as written: `tr("%@ を起動", name)`.
public func tr(_ key: String, _ args: Any...) -> String {
  let table = ClairLanguage.current == .english ? LocalizedStrings.english : LocalizedStrings.japanese
  return LocalizedStrings.format(table[key] ?? key, args.map { "\($0)" })
}

enum LocalizedStrings {
  /// Fills `%@` in order, or `%1$@`… by position (a translation may reorder arguments).
  static func format(_ template: String, _ args: [String]) -> String {
    guard !args.isEmpty else { return template }
    var out = "", next = 0, rest = Substring(template)
    while let r = rest.range(of: "%") {
      out += rest[..<r.lowerBound]
      rest = rest[r.upperBound...]
      if rest.hasPrefix("@") {
        out += next < args.count ? args[next] : ""; next += 1; rest = rest.dropFirst()
      } else if let d = rest.first?.wholeNumberValue, rest.dropFirst().hasPrefix("$@") {
        out += d >= 1 && d <= args.count ? args[d - 1] : ""; rest = rest.dropFirst(3)
      } else {
        out += "%"
      }
    }
    return out + rest
  }
}

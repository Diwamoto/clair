import ClairShared
import Foundation

/// A review is the user's own line comments on a file, a folder or the Project (spec §6), handed to an agent
/// as a JSON file it reads and addresses. The GUI picks the target; the agent runs in the Project root.
public enum AgentReviewRequest {
  public enum Target: Equatable, Sendable {
    case file(String)
    case folder(String)
    case project
  }

  /// The Project-relative files a target covers, sorted.
  public static func files(_ target: Target, in all: [String]) -> [String] {
    switch target {
    case .file(let path): all.contains(path) ? [path] : []
    case .folder(let path): all.filter { $0.hasPrefix(path + "/") }.sorted()
    case .project: all.sorted()
    }
  }

  /// Writes the open threads to `<root>/.clair/reviews/<stamp>.json` and returns that Project-relative path.
  /// The folder carries its own `.gitignore` so review files never show up as changes.
  public static func write(_ threads: [WorkbenchReviewThread], root: String, now: Date = Date()) throws -> String {
    let dir = URL(fileURLWithPath: root).appending(path: ".clair/reviews")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("*\n".utf8).write(to: dir.appending(path: ".gitignore"))
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
    let name = ".clair/reviews/\(f.string(from: now)).json"
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(threads).write(to: URL(fileURLWithPath: root).appending(path: name), options: .atomic)
    return name
  }

  /// The agent's task: read the review file and address every comment.
  public static func prompt(file: String) -> String {
    tr("`%@` にレビューコメントがあります。", file)
      + tr("各要素の path と line（1 始まり）が対象箇所、comments が指摘です。stale が true のものはコメント後に行が変わっています。")
      + tr("すべてのコメントに対応してコードを修正し、最後に各コメントへの対応内容を報告してください。")
  }
}

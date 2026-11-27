import Foundation

/// HTML tools: self-contained pages opened in a pane of their own (the HTML preview's WebView, no source).
/// 標準 = the ones that ship with Clair, written to the channel's data folder so the preview can serve them;
/// マイツール = the user's, one `.html` each in `~/.clair/tools` (added by drop or `tool.add`, same name overwrites).
public enum HTMLTools {
  public struct Tool: Sendable, Equatable {
    public let name: String
    public let path: String
    public let builtin: Bool
  }

  static let builtin: [(name: String, html: String)] = [("terraform-plan.html", terraformPlan)]

  public static func folder(home: URL = .homeDirectory) -> URL { home.appending(path: ".clair/tools") }
  public static var builtinFolder: URL { ClairChannel.current.dataURL.appending(path: "tools") }

  public static func isHTML(_ path: String) -> Bool { ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) }

  /// 標準 first, then マイツール by name. Writes the shipped pages out when they are missing or out of date.
  public static func list(home: URL = .homeDirectory, builtins: URL = builtinFolder) -> [Tool] {
    let shipped = builtin.map { b -> Tool in
      let url = builtins.appending(path: b.name)
      if (try? String(contentsOf: url, encoding: .utf8)) != b.html {
        try? FileManager.default.createDirectory(at: builtins, withIntermediateDirectories: true)
        try? b.html.write(to: url, atomically: true, encoding: .utf8)
      }
      return Tool(name: b.name, path: url.path, builtin: true)
    }
    let dir = folder(home: home)
    let mine = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
      .filter(isHTML).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .map { Tool(name: $0, path: dir.appending(path: $0).path, builtin: false) }
    return shipped + mine
  }

  /// Copies an `.html` file into `~/.clair/tools` under its own name (overwriting), and returns the copy's path.
  public static func add(_ path: String, home: URL = .homeDirectory) throws -> String {
    var isDirectory: ObjCBool = false
    guard isHTML(path), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: path])
    }
    let dir = folder(home: home), to = dir.appending(path: (path as NSString).lastPathComponent)
    if URL(fileURLWithPath: path).standardizedFileURL.path == to.standardizedFileURL.path { return to.path }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    try data.write(to: to, options: .atomic)
    return to.path
  }

  /// Whether `path` is a tool's page (directly in `~/.clair/tools` or the shipped folder): its pane is named after it.
  public static func isTool(_ path: String, home: URL = .homeDirectory) -> Bool {
    let dir = (path as NSString).deletingLastPathComponent
    return dir == folder(home: home).path || dir == builtinFolder.path
  }

  /// A tool by its file name (or its full path), マイツール before 標準 when both have the name.
  public static func find(_ name: String, home: URL = .homeDirectory, builtins: URL = builtinFolder) -> Tool? {
    let tools = list(home: home, builtins: builtins)
    return tools.first { !$0.builtin && ($0.name == name || $0.path == name) } ?? tools.first { $0.name == name || $0.path == name }
  }
}

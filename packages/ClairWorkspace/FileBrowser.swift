import ClairShared
import Foundation

// The file browser (spec §8, ADR-0025): Finder's column view as an editor tab, `finder:<folder>`.
// UI-free so the registry, the CLI and tests share it; the column view itself is in ClairAppKit.
// A folder is listed one level at a time when its column appears — never the whole tree up front.

public enum FileBrowser {
  public static let tabPrefix = "finder:"
  public static func tabPath(_ folder: String) -> String { tabPrefix + folder }
  /// The folder a browser tab starts from, or nil for any other tab.
  public static func root(tab path: String) -> String? { path.hasPrefix(tabPrefix) ? String(path.dropFirst(tabPrefix.count)) : nil }

  /// Tabs that are not Project files (a browser, a history chat, a proposal) and so survive a rescan of the tree.
  public static func isVirtualTab(_ path: String) -> Bool {
    root(tab: path) != nil || AgentHistory.id(tab: path) != nil || FileProposal.id(tab: path) != nil
  }

  public struct Entry: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isHidden: Bool
    public let size: Int?
    public let modified: Date?
    public var id: String { path }
  }

  /// One folder's listing: folders first, then Finder's name order. Hidden items only when asked (⇧⌘.).
  public static func list(_ folder: String, showHidden: Bool = false) throws -> [Entry] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey]
    let urls = try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: folder, isDirectory: true), includingPropertiesForKeys: keys,
      options: showHidden ? [] : [.skipsHiddenFiles])
    return urls.map { url in
      let v = try? url.resourceValues(forKeys: Set(keys))
      return Entry(
        name: url.lastPathComponent, path: url.path, isDirectory: v?.isDirectory == true,
        isHidden: v?.isHidden == true || url.lastPathComponent.hasPrefix("."), size: v?.fileSize, modified: v?.contentModificationDate)
    }.sorted { a, b in
      a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
  }

  /// The column sort (Finder's 表示 › 並べ替え). Folders stay on top in every order.
  public enum Sort: String, Sendable, CaseIterable { case name, modified, size, kind }

  /// `entries` in `sort` order; `ascending` false flips it. Ties fall back to the name.
  public static func sorted(_ entries: [Entry], by sort: Sort, ascending: Bool) -> [Entry] {
    func byName(_ a: Entry, _ b: Entry) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
    func before(_ a: Entry, _ b: Entry) -> Bool {
      switch sort {
      case .name: return byName(a, b)
      case .modified:
        let (x, y) = (a.modified ?? .distantPast, b.modified ?? .distantPast)
        return x != y ? x < y : byName(a, b)
      case .size:
        let (x, y) = (a.size ?? 0, b.size ?? 0)
        return x != y ? x < y : byName(a, b)
      case .kind:
        let (x, y) = ((a.name as NSString).pathExtension.lowercased(), (b.name as NSString).pathExtension.lowercased())
        return x != y ? x < y : byName(a, b)
      }
    }
    return entries.sorted { a, b in
      a.isDirectory != b.isDirectory ? a.isDirectory : ascending ? before(a, b) : before(b, a)
    }
  }

  /// Opens in Clair's editor: the first 8 KiB decode as UTF-8 and hold no NUL. Anything else goes to another app.
  public static func isText(_ path: String) -> Bool {
    guard let h = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? h.close() }
    let head = (try? h.read(upToCount: 8192)) ?? Data()
    if head.contains(0) { return false }
    if String(data: head, encoding: .utf8) != nil { return true }
    // A cut multi-byte sequence at the 8 KiB boundary is still text.
    return (1...3).contains { String(data: head.dropLast($0), encoding: .utf8) != nil }
  }

  /// The first `lines` lines of a text file for the preview column; nil when it is not text.
  public static func head(_ path: String, lines: Int = 14) -> String? {
    guard isText(path), let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    let data = (try? h.read(upToCount: 4096)) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    return text.split(separator: "\n", maxSplits: lines, omittingEmptySubsequences: false).prefix(lines).joined(separator: "\n")
  }

  /// A dropped or typed path on a command line: a backslash before every character a shell reads as syntax,
  /// the rule Ghostty applies to a file dropped from the macOS Finder.
  public static func shellEscape(_ path: String) -> String {
    let special = Set(" \t\n\\'\"`$!&*()[]{}<>|;#?~^")
    return String(path.flatMap { c -> [Character] in special.contains(c) ? ["\\", c] : [c] })
  }

  /// Finder's name for a pasted item whose name is taken: `name のコピー.ext`, then `name のコピー 2.ext`, ….
  public static func copyName(_ name: String, isDirectory: Bool, taken: Set<String>) -> String {
    guard taken.contains(name) else { return name }
    let ns = name as NSString
    let ext = isDirectory ? "" : ns.pathExtension
    let base = ext.isEmpty ? name : ns.deletingPathExtension
    for n in 1... {
      let candidate = "\(base) \(tr("のコピー"))\(n == 1 ? "" : " \(n)")\(ext.isEmpty ? "" : "." + ext)"
      if !taken.contains(candidate) { return candidate }
    }
    return name
  }

  /// Pastes copied items into `folder` (Finder's ⌘C / ⌘V). Returns the new paths; stops at the first failure.
  public static func paste(_ sources: [String], into folder: String) throws -> [String] {
    var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
    var out: [String] = []
    for source in sources {
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir) else { continue }
      let name = copyName((source as NSString).lastPathComponent, isDirectory: isDir.boolValue, taken: taken)
      let target = (folder as NSString).appendingPathComponent(name)
      try FileManager.default.copyItem(atPath: source, toPath: target)
      taken.insert(name); out.append(target)
    }
    return out
  }

  /// The `@path` an agent reads: Project-relative inside `root`, else absolute (with `~` for home).
  public static func mention(_ path: String, root: String?) -> String {
    if let root, path.hasPrefix(root + "/") { return "@" + String(path.dropFirst(root.count + 1)) }
    let home = NSHomeDirectory()
    return "@" + (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
  }

  public static func isFolder(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
  }

  /// `~/x` → `/Users/me/x`; anything else is standardized (`..` and `.` resolved).
  public static func expand(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
  }
}

/// What the active browser tab shows, for `finder.selection`. Transient, like `EditorContext`.
public struct FileBrowserContext: Sendable, Codable, Equatable {
  public let folder: String
  public let selection: [String]
  public init(folder: String, selection: [String]) { self.folder = folder; self.selection = selection }
}

/// A request for a browser tab to show `folder` (and select `select`). The GUI acts on each `seq` once.
public struct FileBrowserReveal: Sendable, Codable, Equatable {
  public let tab: String
  public let folder: String
  public let select: String?
  public let seq: Int
}

// MARK: - proposals

/// An agent's proposal to reorganise a folder (`finder.propose`): file operations the user applies or rejects in a
/// tab. Nothing on disk changes until the user applies; the agent reads the outcome with `finder.proposal`.
public struct FileProposal: Sendable, Codable, Equatable {
  public enum Kind: String, Sendable, Codable { case mkdir, move, rename, trash }
  public enum State: String, Sendable, Codable { case pending, applied, rejected, failed }

  public struct Op: Sendable, Codable, Equatable {
    public let op: Kind
    /// Absolute after validation; an agent may send them relative to the folder.
    public var from: String?
    public var to: String?
    public var why: String?
    public init(op: Kind, from: String? = nil, to: String? = nil, why: String? = nil) {
      self.op = op; self.from = from; self.to = to; self.why = why
    }
    public var isDestructive: Bool { op == .trash }
  }

  public let id: String
  public let folder: String
  public let ops: [Op]
  public var state: State = .pending
  /// Indices of the operations that ran, in order.
  public var applied: [Int] = []
  public var error: String?

  public static let tabPrefix = "proposal:"
  public var tabPath: String { Self.tabPrefix + id }
  public static func id(tab path: String) -> String? { path.hasPrefix(tabPrefix) ? String(path.dropFirst(tabPrefix.count)) : nil }

  public static let maxOps = 500

  /// `"0,2,5"` → `[0, 2, 5]`; anything that is not a number is dropped.
  public static func picked(_ list: String) -> [Int] { list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

  /// Decodes and checks an agent's operations against `folder`: every path stays inside it, a source exists when its
  /// operation runs, and no target is already taken. Run in order, so a move may land in a folder an earlier mkdir makes.
  // ponytail: containment is checked on standardized paths, not resolved symlinks; a symlink inside the folder that
  // points outside is followed. Resolve with `resolvingSymlinksInPath` if agents ever propose through links.
  public static func validate(_ json: String, folder rawFolder: String) throws(CommandError) -> (folder: String, ops: [Op]) {
    let folder = FileBrowser.expand(rawFolder)
    guard FileBrowser.isFolder(folder) else {
      throw CommandError(.preconditionFailed, "not a folder \(rawFolder)")
    }
    guard let raw = try? JSONDecoder().decode([Op].self, from: Data(json.utf8)) else {
      throw CommandError(.invalidInput, #"ops must be a JSON array of {"op":"mkdir|move|rename|trash","from":…,"to":…,"why":…}"#)
    }
    guard !raw.isEmpty, raw.count <= maxOps else { throw CommandError(.invalidInput, "1 to \(maxOps) operations") }
    func inside(_ p: String?) throws(CommandError) -> String {
      guard let p, !p.isEmpty else { throw CommandError(.invalidInput, "missing path") }
      let abs = FileBrowser.expand(p.hasPrefix("/") || p.hasPrefix("~") ? p : (folder as NSString).appendingPathComponent(p))
      guard abs.hasPrefix(folder + "/") else { throw CommandError(.invalidInput, "\(p) is outside \(folder)") }
      return abs
    }
    // The folder as the earlier operations will have left it: made paths, and paths moved or trashed away (with all below).
    var exists = Set<String>(), gone = Set<String>()
    func present(_ p: String) -> Bool {
      if exists.contains(p) { return true }
      if gone.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return false }
      return FileManager.default.fileExists(atPath: p)
    }
    var ops: [Op] = []
    for o in raw {
      var op = o
      switch o.op {
      case .mkdir:
        op.from = nil; op.to = try inside(o.to)
      case .move, .rename:
        op.from = try inside(o.from); op.to = try inside(o.to)
      case .trash:
        op.from = try inside(o.from); op.to = nil
      }
      if let from = op.from {
        guard present(from) else { throw CommandError(.preconditionFailed, "no such item \(from)") }
        gone.insert(from)
        for p in exists where p.hasPrefix(from + "/") { exists.remove(p) }
      }
      if let to = op.to {
        guard !present(to) else { throw CommandError(.preconditionFailed, "\(to) already exists") }
        guard present((to as NSString).deletingLastPathComponent) || (to as NSString).deletingLastPathComponent == folder else {
          throw CommandError(.preconditionFailed, "no folder for \(to)")
        }
        exists.insert(to); gone.remove(to)
      }
      ops.append(op)
    }
    return (folder, ops)
  }

  /// Runs the picked operations in order. Trash goes to the Finder's Trash, so every step can be undone by hand.
  public mutating func apply(_ picked: [Int]) {
    guard state == .pending else { return }
    let fm = FileManager.default
    for i in picked.sorted() where ops.indices.contains(i) {
      let o = ops[i]
      do {
        switch o.op {
        case .mkdir: try fm.createDirectory(atPath: o.to!, withIntermediateDirectories: false)
        case .move, .rename:
          guard !fm.fileExists(atPath: o.to!) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: o.to!]) }
          try fm.moveItem(atPath: o.from!, toPath: o.to!)
        case .trash: try fm.trashItem(at: URL(fileURLWithPath: o.from!), resultingItemURL: nil)
        }
        applied.append(i)
      } catch {
        state = .failed
        self.error = "\(o.op.rawValue) \(o.from ?? o.to ?? ""): \(error.localizedDescription)"
        return
      }
    }
    state = .applied
  }

  /// What `finder.proposal` answers: the state, the operations that ran and, on failure, why it stopped.
  public var report: String {
    struct Report: Encodable { let id: String; let state: String; let applied: [Op]; let skipped: Int; let error: String? }
    let r = Report(id: id, state: state.rawValue, applied: applied.map { ops[$0] }, skipped: ops.count - applied.count, error: error)
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? enc.encode(r)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }
}

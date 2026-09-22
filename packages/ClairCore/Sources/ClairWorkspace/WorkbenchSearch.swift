import ClairEditorCore
import CryptoKit
import Foundation
#if os(macOS)
  import CoreServices
#endif

// V05: Quick Open ranking, project-wide search/replace (E04 core), file watcher with agent
// live reload (principle 8: disk wins, unsaved buffer is discarded) and per-file local history.
// ponytail: search reads files serially (cancellable per file) and skips >1 MB / non-UTF-8; parallelise if 10k-file search feels slow.

public enum QuickOpen {
  /// Case-insensitive subsequence match. Basename hits and consecutive runs rank first; ties keep path order.
  public static func rank(_ query: String, _ files: [WorkbenchFile]) -> [WorkbenchFile] {
    let q = Array(query.lowercased())
    guard !q.isEmpty else { return files }
    return files.compactMap { f -> (Int, WorkbenchFile)? in
      let name = f.path.split(separator: "/").last.map(String.init) ?? f.path
      guard let s = score(q, f.path.lowercased()) else { return nil }
      return (s + (score(q, name.lowercased()) != nil ? 100 : 0), f)
    }.enumerated().sorted { ($0.element.0, $1.offset) > ($1.element.0, $0.offset) }.map(\.element.1)
  }

  private static func score(_ q: [Character], _ s: String) -> Int? {
    var i = 0, run = 0, total = 0
    for c in s where i < q.count {
      if c == q[i] { i += 1; run += 1; total += run } else { run = 0 }
    }
    return i == q.count ? total : nil
  }
}

public struct SearchHit: Sendable, Equatable {
  public let path: String
  public let line: Int  // 1-based
  public let text: String
}

public enum ProjectSearch {
  static let maxBytes = 1 << 20

  private static func load(_ root: String, _ path: String) -> TextBuffer? {
    guard let d = FileManager.default.contents(atPath: root + "/" + path), d.count <= maxBytes else { return nil }
    return try? TextBuffer(utf8: [UInt8](d))
  }

  public static func find(root: String, files: [WorkbenchFile], _ pattern: SearchPattern) throws -> [SearchHit] {
    var hits: [SearchHit] = []
    for f in files {
      try Task.checkCancellation()
      guard let buf = load(root, f.path) else { continue }
      let ms: [SearchMatch]
      do { ms = try TextSearch.find(pattern, in: buf.snapshot) } catch SearchError.invalidRegex { throw SearchError.invalidRegex } catch { continue }
      let text = buf.snapshot.string()
      for m in ms {
        let start = text.utf8.index(text.utf8.startIndex, offsetBy: m.range.lowerBound.value)
        let line = text.utf8[..<start].reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let ls = text[..<start].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let le = text[start...].firstIndex(of: "\n") ?? text.endIndex
        hits.append(SearchHit(path: f.path, line: line, text: String(text[ls..<le])))
      }
    }
    return hits
  }

  /// Rewrites matching files (each snapshotted into `history` first) and returns replaced-match count.
  @discardableResult
  public static func replace(root: String, files: [WorkbenchFile], _ pattern: SearchPattern, with r: String, history: LocalHistory? = nil) throws -> Int {
    var n = 0
    for f in files {
      guard let buf = load(root, f.path) else { continue }
      let reps = try TextSearch.preview(pattern, replacingWith: r, in: buf.snapshot)
      guard !reps.isEmpty else { continue }
      try history?.record(root: root, path: f.path)
      let m = EditorTransactionManager(buffer: buf, selection: TextSelectionSet(cursor: UTF8Offset(0)))
      let out = try m.apply(replacements: reps).string()
      try out.write(toFile: root + "/" + f.path, atomically: true, encoding: .utf8)
      n += reps.count
    }
    return n
  }
}

extension WorkbenchState {
  /// Agent/external disk change: refresh the tree and drop unsaved markers for the changed files.
  public mutating func applyDiskChange(_ paths: Set<String>, root: String) {
    applyDiskChange(paths, files: WorkbenchFiles.scan(root))
  }

  /// Same, with the (slow) scan already done off the main thread.
  public mutating func applyDiskChange(_ paths: Set<String>, files scanned: [WorkbenchFile]) {
    let firstDeferredLoad = files.isEmpty && filesCache[project] == nil
    files = scanned
    filesCache[project] = scanned
    if firstDeferredLoad {
      if collapsed.isEmpty { collapsed = WorkbenchFiles.directories(of: scanned) }
      let existing = Set(scanned.map(\.path))
      tabs = tabs.filter(existing.contains)
      dirty.formIntersection(tabs)
      if active.map(tabs.contains) != true { active = tabs.last }
    }
    dirty.subtract(paths)
  }
}

#if os(macOS)
/// FSEvents on a Project root; `onChange` gets root-relative paths (debounced by FSEvents latency).
public final class FileWatcher: @unchecked Sendable {
  private var stream: FSEventStreamRef?
  private let root: String
  private let onChange: @Sendable (Set<String>) -> Void

  public init?(root: String, latency: TimeInterval = 0.2, onChange: @escaping @Sendable (Set<String>) -> Void) {
    self.root = realpath(root, nil).map { String(cString: $0) } ?? root  // FSEvents reports /private/var, which Foundation would strip
    self.onChange = onChange
    var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
      let w = Unmanaged<FileWatcher>.fromOpaque(info!).takeUnretainedValue()
      let list = unsafeBitCast(paths, to: NSArray.self) as! [String]
      // `.git/` and build output are ignored: our own `git status` rewrites `.git/index`, which would otherwise re-trigger a rescan forever.
      let rel = Set(list.prefix(n).compactMap { $0.hasPrefix(w.root + "/") ? String($0.dropFirst(w.root.count + 1)) : nil }.filter { !WorkbenchFiles.isSkipped($0) })
      if !rel.isEmpty { w.onChange(rel) }
    }
    guard let s = FSEventStreamCreate(nil, cb, &ctx, [self.root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
    else { return nil }
    stream = s
    FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "clair.filewatcher"))
    FSEventStreamStart(s)
  }

  deinit { if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) } }
}
#endif

/// Per-file snapshots under `dir` (Clair's data dir), never inside the Project.
public struct LocalHistory: Sendable {
  public let dir: URL
  public let keep: Int
  public init(dir: URL, keep: Int = 50) { self.dir = dir; self.keep = keep }

  private func folder(_ root: String, _ path: String) -> URL {
    let h = SHA256.hash(data: Data((root + "\0" + path).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    return dir.appendingPathComponent(h, isDirectory: true)
  }

  public func record(root: String, path: String) throws {
    guard let d = FileManager.default.contents(atPath: root + "/" + path) else { return }
    let f = folder(root, path)
    try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
    try d.write(to: f.appendingPathComponent(String(format: "%020.6f", Date().timeIntervalSince1970)))
    for old in try versions(root: root, path: path).dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
  }

  /// Newest first.
  public func versions(root: String, path: String) throws -> [URL] {
    let f = folder(root, path)
    guard FileManager.default.fileExists(atPath: f.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  /// Line diff of what a restore would change: "-" lines leave the file, "+" lines come back.
  public func preview(_ version: URL, root: String, path: String) -> [String] {
    func lines(_ d: Data?) -> [String] { d.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\n") ?? [] }
    let cur = lines(FileManager.default.contents(atPath: root + "/" + path)), old = lines(try? Data(contentsOf: version))
    let d = old.difference(from: cur)
    return d.removals.compactMap { c -> String? in if case .remove(let i, let l, _) = c { "- \(l)" } else { nil } }
      + d.insertions.compactMap { c -> String? in if case .insert(_, let l, _) = c { "+ \(l)" } else { nil } }
  }

  /// Restores a version; the current content is snapshotted first so a restore is itself undoable.
  public func restore(_ version: URL, root: String, path: String) throws {
    try record(root: root, path: path)
    try Data(contentsOf: version).write(to: URL(fileURLWithPath: root + "/" + path), options: .atomic)
  }
}

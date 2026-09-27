import ClairEditorCore
import Foundation
#if os(macOS)
  import CoreServices
#endif

// V05: Quick Open ranking, project-wide search/replace (E04 core), file watcher with agent
// live reload (principle 8: disk wins, unsaved buffer is discarded).
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
    try find(root: root, files: files, pattern) { hits += $0 }
    return hits
  }

  /// Streams each file's hits as soon as that file is scanned, so the UI can show early results.
  public static func find(root: String, files: [WorkbenchFile], _ pattern: SearchPattern, each: ([SearchHit]) -> Void) throws {
    for f in files {
      try Task.checkCancellation()
      guard let buf = load(root, f.path) else { continue }
      let ms: [SearchMatch]
      do { ms = try TextSearch.find(pattern, in: buf.snapshot) } catch SearchError.invalidRegex { throw SearchError.invalidRegex } catch { continue }
      guard !ms.isEmpty else { continue }
      let bytes = Array(buf.snapshot.string().utf8)
      // Walk forward once: matches are in order, so line counting stays linear per file.
      var line = 1, lineStart = 0, pos = 0
      var out: [SearchHit] = []
      for m in ms {
        let at = min(m.range.lowerBound.value, bytes.count)
        while pos < at { if bytes[pos] == 10 { line += 1; lineStart = pos + 1 }; pos += 1 }
        let end = bytes[at...].firstIndex(of: 10) ?? bytes.count
        out.append(SearchHit(path: f.path, line: line, text: String(decoding: bytes[lineStart..<end], as: UTF8.self)))
      }
      each(out)
    }
  }

  /// Rewrites matching files and returns replaced-match count.
  @discardableResult
  public static func replace(root: String, files: [WorkbenchFile], _ pattern: SearchPattern, with r: String) throws -> Int {
    var n = 0
    for f in files {
      guard let buf = load(root, f.path) else { continue }
      let reps = try TextSearch.preview(pattern, replacingWith: r, in: buf.snapshot)
      guard !reps.isEmpty else { continue }
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
/// FSEvents on a Project root and its added folders; `onChange` gets root-relative paths (debounced by FSEvents latency).
public final class FileWatcher: @unchecked Sendable {
  private var stream: FSEventStreamRef?
  /// (watched realpath, root-relative prefix): `""` for the root, `../docs/` for an added folder.
  private let roots: [(path: String, prefix: String)]
  private let onChange: @Sendable (Set<String>) -> Void

  public init?(root: String, folders: [String] = [], latency: TimeInterval = 0.2, onChange: @escaping @Sendable (Set<String>) -> Void) {
    // FSEvents reports /private/var, which Foundation would strip
    func real(_ p: String) -> String { realpath(p, nil).map { c in defer { free(c) }; return String(cString: c) } ?? p }
    roots = [(real(root), "")] + folders.map { (real($0), WorkbenchFiles.relative($0, from: root) + "/") }
    self.onChange = onChange
    var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
      let w = Unmanaged<FileWatcher>.fromOpaque(info!).takeUnretainedValue()
      let list = unsafeBitCast(paths, to: NSArray.self) as! [String]
      let rel = Set(list.prefix(n).compactMap { w.relative($0) })
      if !rel.isEmpty { w.onChange(rel) }
    }
    guard let s = FSEventStreamCreate(nil, cb, &ctx, roots.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
    else { return nil }
    stream = s
    FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "clair.filewatcher"))
    FSEventStreamStart(s)
  }

  /// Root-relative path for an event, or nil when it is noise. Build output and `.git/` are ignored,
  /// except `.git/index` and `.git/HEAD` so a commit/stage/checkout in a terminal recolors the tree.
  /// Our own scans never write them: `git status` runs with `GIT_OPTIONAL_LOCKS=0`.
  /// ponytail: a linked worktree's index lives outside the root and is not watched; watch its gitdir if that matters.
  func relative(_ path: String) -> String? {
    guard let r = roots.first(where: { path.hasPrefix($0.path + "/") }) else { return nil }
    let inner = String(path.dropFirst(r.path.count + 1))
    if inner == ".git/index" || inner == ".git/HEAD" { return r.prefix + inner }
    return WorkbenchFiles.isSkipped(inner) ? nil : r.prefix + inner
  }

  deinit { if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) } }
}
#endif

import ClairEditorFixtures
import Foundation

/// Adversarial corpus for `BUDGET-OP-100` (docs/benchmarks/clair-v2-performance-budget.md §3).
///
/// Built to break the measured paths, not to look like a normal repository: the
/// file count sits exactly on `WorkbenchFiles.limit`, the nesting is deeper than
/// any real tree, and the Git state is dirty enough that `status` has real work.
///
/// Generation is expensive (tens of thousands of files plus `git add`), so it is
/// cached under a fixed path and reused until `--regenerate` removes it. Cached
/// corpora are content-addressed by `layoutVersion`: bump it and the next run
/// rebuilds instead of silently measuring a stale shape.
enum BudgetCorpus {
  /// Bump when any generated shape below changes.
  static let layoutVersion = 1

  static let wideFileCount = 20_000  // == WorkbenchFiles.limit
  static let wideDirectoryCount = 400
  static let deepDepth = 40
  static let dirtyModifiedCount = 3_000
  static let dirtyUntrackedCount = 1_000

  struct Corpus: Sendable {
    /// 20,000 files across 400 directories, committed clean.
    let wide: String
    /// A 40-level nested chain.
    let deep: String
    /// 3,000 modified + 1,000 untracked files on top of a clean commit.
    let dirty: String
    /// `EditorFixtureGenerator` canonical files, keyed by fixture name.
    let fixtures: [String: URL]
    /// ~4 MiB of deeply nested JSON, for the tree-sitter paths.
    let largeJSON: URL
    /// Scratch directory the ops may write into.
    let scratch: String
  }

  static let root = URL(fileURLWithPath: "/tmp/clair-perf-corpus-v\(layoutVersion)")

  /// Builds the corpus, or returns the cached one. Not thread-safe; call once.
  static func make() throws -> Corpus {
    let marker = root.appending(path: ".complete")
    let cached = FileManager.default.fileExists(atPath: marker.path)
    if !cached {
      try? FileManager.default.removeItem(at: root)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    let wide = root.appending(path: "wide")
    let deep = root.appending(path: "deep")
    let dirty = root.appending(path: "dirty")
    let fixtureDir = root.appending(path: "fixtures")
    let scratch = root.appending(path: "scratch")

    if !cached {
      try buildWide(at: wide)
      try buildDeep(at: deep)
      try buildDirty(at: dirty)
      try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
      for fixture in EditorFixtureGenerator.canonicalFixtures {
        _ = try EditorFixtureGenerator.generate(fixture, into: fixtureDir)
      }
      try buildLargeJSON(at: root.appending(path: "large.json"))
    }
    // Scratch is always fresh: a previous run's writes must not be measured.
    try? FileManager.default.removeItem(at: scratch)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    var fixtures: [String: URL] = [:]
    for fixture in EditorFixtureGenerator.canonicalFixtures {
      let url = fixtureDir.appending(path: "\(fixture.name).swift")
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw CorpusError.missing("fixture \(fixture.name) at \(url.path)")
      }
      fixtures[fixture.name] = url
    }

    if !cached { try Data().write(to: marker) }
    return Corpus(
      wide: wide.path, deep: deep.path, dirty: dirty.path,
      fixtures: fixtures, largeJSON: root.appending(path: "large.json"), scratch: scratch.path)
  }

  enum CorpusError: Error, CustomStringConvertible {
    case missing(String), git(String)
    var description: String {
      switch self {
      case .missing(let what): "corpus is missing \(what)"
      case .git(let what): "corpus git failed: \(what)"
      }
    }
  }

  // MARK: - shapes

  private static func buildWide(at root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let perDirectory = wideFileCount / wideDirectoryCount
    for d in 0..<wideDirectoryCount {
      // Two path segments, so `treeOrder` has more than one component to compare.
      let dir = root.appending(path: "pkg\(d / 20)").appending(path: "mod\(d)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      for f in 0..<perDirectory {
        // Names share a long prefix: the Quick Open subsequence scorer cannot
        // reject them on the first character.
        let body = "// module \(d) file \(f)\nfunc handlerForModule\(d)File\(f)() -> Int { \(f) }\n"
        try Data(body.utf8).write(to: dir.appending(path: "ServiceHandlerImplementation\(f).swift"))
      }
    }
    try commitAll(root)
  }

  private static func buildDeep(at root: URL) throws {
    var dir = root
    for level in 0..<deepDepth {
      dir = dir.appending(path: "level\(level)")
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 200 files at the bottom, so search/replace has a real working set at depth.
    for f in 0..<200 {
      try Data("let deepValue\(f) = \"needle-alpha\"\n".utf8)
        .write(to: dir.appending(path: "Deep\(f).swift"))
    }
    try commitAll(root)
  }

  private static func buildDirty(at root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let total = dirtyModifiedCount + 2_000
    for f in 0..<total {
      let dir = root.appending(path: "src").appending(path: "group\(f / 250)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data("let committed\(f) = \(f)\n".utf8).write(to: dir.appending(path: "File\(f).swift"))
    }
    try commitAll(root)
    // Now dirty it: modify the first N, add untracked files the scan must also see.
    for f in 0..<dirtyModifiedCount {
      let url = root.appending(path: "src").appending(path: "group\(f / 250)")
        .appending(path: "File\(f).swift")
      try Data("let committed\(f) = \(f)\n// modified after the commit\n".utf8).write(to: url)
    }
    for f in 0..<dirtyUntrackedCount {
      let dir = root.appending(path: "untracked").appending(path: "group\(f / 250)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data("let fresh\(f) = \(f)\n".utf8).write(to: dir.appending(path: "New\(f).swift"))
    }
  }

  /// ~4 MiB of nested JSON: deep enough that tree-sitter builds a real tree.
  private static func buildLargeJSON(at url: URL) throws {
    var out = "{\n  \"records\": [\n"
    for i in 0..<20_000 {
      out += """
          {"id": \(i), "name": "record-\(i)", "tags": ["alpha", "beta", "gamma"], \
        "nested": {"depth": {"value": \(i), "flag": \(i % 2 == 0)}}}\(i == 19_999 ? "" : ",")\n
        """
    }
    out += "  ]\n}\n"
    try Data(out.utf8).write(to: url)
  }

  private static func commitAll(_ root: URL) throws {
    for args in [
      ["init", "-q"],
      ["config", "user.email", "perf@clair.test"],
      ["config", "user.name", "Clair Perf"],
      ["add", "-A"],
      ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "corpus"],
    ] {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      p.arguments = ["-C", root.path] + args
      p.standardOutput = FileHandle.nullDevice
      p.standardError = FileHandle.nullDevice
      try p.run()
      p.waitUntilExit()
      guard p.terminationStatus == 0 else {
        throw CorpusError.git("git \(args.joined(separator: " ")) in \(root.path)")
      }
    }
  }
}

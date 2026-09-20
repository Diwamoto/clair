import Foundation

// V04: Project model, real file tree, and layout persistence for the Mac workbench.
// A Project is any local folder (Git optional). Per-Project layout/tabs are kept
// while switching and restored across launches; anything unrestorable degrades
// to the default layout instead of failing.

public struct WorkbenchProject: Sendable, Codable, Equatable {
  public let name: String
  public let path: String
  /// Managed worktree only: the repository it was created from and its branch (V06).
  public var origin: String? = nil
  public var branch: String? = nil

  /// Absolute, symlink-resolved directory path, or nil if `path` is not an existing directory.
  static func normalized(_ path: String) -> String? {
    guard path.hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url.path : nil
  }
}

/// Restorable per-Project UI state.
public struct ProjectLayout: Sendable, Codable, Equatable {
  public var tree = PaneTree()
  public var tabs: [String] = []
  public var active: String?
  public var dirty: Set<String> = []
  public var collapsed: Set<String> = []
  /// V07: live agent terminals by pane id. Never persisted — restore must not silently respawn agents.
  public var launches: [Int: AgentLaunch] = [:]
  private enum CodingKeys: String, CodingKey { case tree, tabs, active, dirty, collapsed }
}

extension WorkbenchState {
  var layout: ProjectLayout {
    get { ProjectLayout(tree: tree, tabs: tabs, active: active, dirty: dirty, collapsed: collapsed, launches: launches) }
    set { tree = newValue.tree; tabs = newValue.tabs; active = newValue.active; dirty = newValue.dirty; collapsed = newValue.collapsed; launches = newValue.launches }
  }

  /// Stashes the current Project's layout, rescans the target's files and loads its layout.
  mutating func switchProject(to p: WorkbenchProject) {
    if !project.isEmpty { layouts[project] = layout }
    project = p.name
    files = WorkbenchFiles.scan(p.path)
    var l = layouts[p.name] ?? {
      // First time this Project is shown: every directory starts folded (an unfolded tree of a big repo is thousands of rows).
      var fresh = ProjectLayout()
      fresh.collapsed = WorkbenchFiles.directories(of: files)
      return fresh
    }()
    let paths = Set(files.map(\.path))
    l.tabs = l.tabs.filter(paths.contains)
    l.dirty.formIntersection(l.tabs)
    if l.active.map(l.tabs.contains) != true { l.active = l.tabs.last }
    if !l.tree.isValid { l.tree = PaneTree() }
    l.launches = l.launches.filter { id, _ in l.tree.leaves.contains { $0.id == id } }
    layout = l
    notices.markRead(project: p.name)  // looking at a Project clears its badge
  }
}

public enum WorkbenchFiles {
  static let skipped: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".DS_Store", "target"]
  /// Every directory that contains a file, as root-relative paths.
  static func directories(of files: [WorkbenchFile]) -> Set<String> {
    var out = Set<String>()
    for f in files {
      let parts = f.path.split(separator: "/")
      for d in 0..<max(parts.count - 1, 0) { out.insert(parts[0...d].joined(separator: "/")) }
    }
    return out
  }
  /// True for a root-relative path inside a skipped directory (build output, VCS internals).
  static func isSkipped(_ relative: String) -> Bool { relative.split(separator: "/").contains { skipped.contains(String($0)) } }
  static let limit = 20_000  // ponytail: flat cap (10k files scan in ~0.2s, V05); lazy per-directory listing beyond this.

  /// Regular files under `root` (relative, sorted), never following symlinks, with Git status if `root` is a repo.
  public static func scan(_ root: String) -> [WorkbenchFile] {
    let base = URL(fileURLWithPath: root).resolvingSymlinksInPath()
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
    else { return [] }
    var paths: [String] = []
    for case let u as URL in e {
      if skipped.contains(u.lastPathComponent) { e.skipDescendants(); continue }
      let v = try? u.resourceValues(forKeys: Set(keys))
      guard v?.isRegularFile == true, v?.isSymbolicLink != true else { continue }
      paths.append(String(u.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1)))  // files only, so this never follows a link
      if paths.count >= limit { break }
    }
    let status = gitStatus(root)
    return paths.sorted().map { WorkbenchFile(path: $0, status: status[$0]) }
  }

  /// `M`/`A`/`D`/`R`… from `git status`, `U` for untracked. Empty if not a repo or git fails.
  static func gitStatus(_ root: String) -> [String: String] {
    guard FileManager.default.fileExists(atPath: root + "/.git") else { return [:] }
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all"]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [:] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitWithoutRunLoop()  // ponytail: no timeout; add one if a huge repo stalls the GUI.
    var result: [String: String] = [:]
    var fields = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
    while let f = fields.next(), f.count > 3 {
      let xy = f.prefix(2), path = String(f.dropFirst(3))
      if xy.contains(where: { $0 == "R" || $0 == "C" }) { _ = fields.next() }  // skip the original path
      let c = xy == "??" ? "U" : String(xy.first { $0 != " " } ?? "M")
      result[path] = c
    }
    return result
  }
}

// MARK: - Persistence

private struct WorkspaceSnapshot: Codable {
  var projects: [WorkbenchProject]
  var project: String
  var layouts: [String: ProjectLayout]
  var toggles: [String: Bool]
}

extension WorkbenchState {
  public func save(to url: URL) throws {
    var s = self
    if !s.project.isEmpty { s.layouts[s.project] = s.layout }
    let data = try JSONEncoder().encode(WorkspaceSnapshot(projects: s.projects, project: s.project, layouts: s.layouts, toggles: s.toggles))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  /// nil if nothing usable is stored. Missing roots are dropped; unsaved-edit markers are never restored (principle 8).
  public static func restore(from url: URL) -> WorkbenchState? {
    guard let data = try? Data(contentsOf: url), let snap = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    else { return nil }
    var s = WorkbenchState()
    for (k, v) in snap.toggles where s.toggles[k] != nil { s.toggles[k] = v }
    s.projects = snap.projects.filter { WorkbenchProject.normalized($0.path) != nil }
    guard let current = s.projects.first(where: { $0.name == snap.project }) ?? s.projects.first else { return s }
    if s.toggles["restoreLayout"] == true {
      s.layouts = snap.layouts.mapValues { var l = $0; l.dirty = []; return l }
    }
    s.switchProject(to: current)
    return s
  }
}

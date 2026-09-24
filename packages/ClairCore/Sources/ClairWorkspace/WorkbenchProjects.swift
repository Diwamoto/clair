import Foundation

public enum WorkbenchTab: Sendable, Equatable {
  case file(String)
  case terminal(Int)
}

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

  public init(name: String, path: String, origin: String? = nil, branch: String? = nil) {
    self.name = name
    self.path = path
    self.origin = origin
    self.branch = branch
  }

  /// Absolute, symlink-resolved directory path, or nil if `path` is not an existing directory.
  public static func normalized(_ path: String) -> String? {
    guard path.hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url.path : nil
  }

  /// Absolute, symlink-resolved path of an existing regular file, or nil.
  static func normalizedFile(_ path: String) -> String? {
    guard path.hasPrefix("/") else { return nil }
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue ? url.path : nil
  }

  /// The Project a file outside every open Project becomes: its nearest Git root, else its folder.
  static func root(containing file: String) -> WorkbenchProject {
    var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
    let folder = dir
    while dir.path != "/" {
      if FileManager.default.fileExists(atPath: dir.appending(path: ".git").path) { return WorkbenchProject(name: dir.lastPathComponent, path: dir.path) }
      dir.deleteLastPathComponent()
    }
    return WorkbenchProject(name: folder.lastPathComponent, path: folder.path)
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
  /// Every pane closed in this Project only; not persisted (restore reopens the layout).
  public var panesClosed = false
  private enum CodingKeys: String, CodingKey { case tree, tabs, active, dirty, collapsed }
}

extension WorkbenchState {
  var layout: ProjectLayout {
    get { ProjectLayout(tree: tree, tabs: tabs, active: active, dirty: dirty, collapsed: collapsed, launches: launches, panesClosed: panesClosed) }
    set { tree = newValue.tree; tabs = newValue.tabs; active = newValue.active; dirty = newValue.dirty; collapsed = newValue.collapsed; launches = newValue.launches; panesClosed = newValue.panesClosed }
  }

  /// The open Project with the deepest root containing `file` (a nested Project wins over its parent).
  func owner(of file: String) -> WorkbenchProject? {
    projects.filter { file.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
  }

  /// Switches to the Project at `p.path`, adding it (under a unique name) if it is not open yet.
  public mutating func openProject(_ p: WorkbenchProject, scanFiles: Bool = true) {
    if let open = projects.first(where: { $0.path == p.path }) { switchProject(to: open, scanFiles: scanFiles); return }
    var name = p.name, n = 2
    while projects.contains(where: { $0.name == name }) { name = "\(p.name) \(n)"; n += 1 }
    let added = WorkbenchProject(name: name, path: p.path)
    projects.append(added); switchProject(to: added, scanFiles: scanFiles)
  }

  mutating func openTab(_ path: String) {
    panesClosed = false
    tree.ensureEditorAtLeft()
    if !tabs.contains(path) { tabs.append(path) }
    active = path; settingsOpen = false; palette = nil
  }

  /// Titlebar order and selection are shared by shortcuts and native chrome.
  /// Editor panes show the active file; they are not extra titlebar tabs.
  public var titlebarTabs: [WorkbenchTab] {
    tabs.map(WorkbenchTab.file) + tree.leaves.filter { $0.kind == .terminal }.map { .terminal($0.id) }
  }

  public var selectedTitlebarTab: WorkbenchTab? {
    guard let pane = tree.leaves.first(where: { $0.id == tree.focused }) else { return nil }
    switch pane.kind {
    case .editor: return active.flatMap { tabs.contains($0) ? .file($0) : nil }
    case .terminal: return .terminal(pane.id)
    }
  }

  mutating func selectTab(_ tab: WorkbenchTab) {
    switch tab {
    case .file(let path):
      guard tabs.contains(path), let editor = tree.leaves.first(where: { $0.kind == .editor }) else { return }
      active = path
      tree.focus(editor.id)
    case .terminal(let id):
      guard tree.leaves.contains(where: { $0.id == id && $0.kind == .terminal }) else { return }
      tree.focus(id)
    }
  }

  mutating func cycleTab(_ direction: Int) {
    let all = titlebarTabs
    guard !all.isEmpty else { return }
    let current = selectedTitlebarTab.flatMap { all.firstIndex(of: $0) } ?? 0
    selectTab(all[(current + direction + all.count) % all.count])
  }

  /// Stashes the current Project's layout and loads the target's layout. The GUI can skip the
  /// initial disk/Git scan so its first frame is never held up; its file watcher fills the tree
  /// immediately afterwards on a utility queue.
  public mutating func switchProject(to p: WorkbenchProject, scanFiles: Bool = true) {
    if !project.isEmpty { layouts[project] = layout; filesCache[project] = files }
    project = p.name
    // A revisited Project shows its last tree at once; the GUI rescans in the background (a scan walks the disk and runs `git status`).
    let cached = filesCache[p.name]
    files = cached ?? (scanFiles ? WorkbenchFiles.scan(p.path) : [])
    var l = layouts[p.name] ?? ProjectLayout()
    // Nothing folded yet (a new Project, or a layout saved before folding was the default): fold every directory,
    // since an unfolded tree of a big repo is thousands of rows. ponytail: a tree the user fully unfolded is folded again on the next switch.
    if l.collapsed.isEmpty { l.collapsed = WorkbenchFiles.directories(of: files) }
    // With a deferred first scan, keep restored tabs until the background result tells us which
    // paths still exist. Cached and synchronous trees can be reconciled immediately.
    if cached != nil || scanFiles {
      let paths = Set(files.map(\.path))
      l.tabs = l.tabs.filter(paths.contains)
      l.dirty.formIntersection(l.tabs)
      if l.active.map(l.tabs.contains) != true { l.active = l.tabs.last }
    }
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
    // The enumerator yields realpath(3) paths (`/private/var/…`), which `resolvingSymlinksInPath` strips to `/var/…`.
    let prefix = (realpath(base.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? base.path).count + 1
    var paths: [String] = []
    for case let u as URL in e {
      if skipped.contains(u.lastPathComponent) { e.skipDescendants(); continue }
      let v = try? u.resourceValues(forKeys: Set(keys))
      guard v?.isRegularFile == true, v?.isSymbolicLink != true else { continue }
      paths.append(String(u.path.dropFirst(prefix)))  // `base` is resolved and the enumerator never follows links, so no per-file realpath
      if paths.count >= limit { break }
    }
    let status = gitStatus(root)
    return paths.sorted(by: treeOrder).map { WorkbenchFile(path: $0, status: status[$0]) }
  }

  /// Explorer order: in every directory, folders before files, each by name (case-insensitive, raw name breaks ties).
  static func treeOrder(_ a: String, _ b: String) -> Bool {
    let x = a.split(separator: "/"), y = b.split(separator: "/")
    for i in 0..<min(x.count, y.count) {
      if x[i] == y[i] { continue }
      let xf = i == x.count - 1, yf = i == y.count - 1  // last component = file
      if xf != yf { return yf }
      let (l, r) = (x[i].lowercased(), y[i].lowercased())
      return l != r ? l < r : x[i] < y[i]
    }
    return x.count < y.count
  }

  /// `M`/`A`/`D`/`R`… from `git status`, `U` for untracked. Empty if not a repo or git fails.
  static func gitStatus(_ root: String) -> [String: String] {
    #if os(macOS)
    guard FileManager.default.fileExists(atPath: root + "/.git") else { return [:] }
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all"]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [:] }
    let deadline = p.terminate(after: WorkbenchGit.timeout)
    defer { deadline.cancel() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitWithoutRunLoop()
    guard p.terminationReason == .exit else { return [:] }
    var result: [String: String] = [:]
    var fields = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
    while let f = fields.next(), f.count > 3 {
      let xy = f.prefix(2), path = String(f.dropFirst(3))
      if xy.contains(where: { $0 == "R" || $0 == "C" }) { _ = fields.next() }  // skip the original path
      let c = xy == "??" ? "U" : String(xy.first { $0 != " " } ?? "M")
      result[path] = c
    }
    return result
    #else
    return [:]  // ponytail: iOS has no git subprocess; the host supplies status over the wire.
    #endif
  }
}

// MARK: - Persistence

private struct WorkspaceSnapshot: Codable {
  var projects: [WorkbenchProject]
  var project: String
  var layouts: [String: ProjectLayout]
  var toggles: [String: Bool]
  var choices: [String: String]?
  var shortcuts: [String: String]?
}

extension WorkbenchState {
  public func save(to url: URL) throws {
    var s = self
    if !s.project.isEmpty { s.layouts[s.project] = s.layout }
    let data = try JSONEncoder().encode(WorkspaceSnapshot(projects: s.projects, project: s.project, layouts: s.layouts, toggles: s.toggles, choices: s.choices, shortcuts: s.shortcuts))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  /// nil if nothing usable is stored. Missing roots are dropped; unsaved-edit markers are never restored (principle 8).
  public static func restore(from url: URL, scanFiles: Bool = true) -> WorkbenchState? {
    guard let data = try? Data(contentsOf: url), let snap = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    else { return nil }
    var s = WorkbenchState()
    for (k, v) in snap.toggles where s.toggles[k] != nil { s.toggles[k] = v }
    for (k, v) in snap.choices ?? [:] where WorkbenchState.choiceOptions[k]?.contains(v) == true { s.choices[k] = v }
    for (id, key) in snap.shortcuts ?? [:] where key.isEmpty || WorkbenchState.canonicalShortcut(key) == key { s.shortcuts[id] = key }
    s.projects = snap.projects.filter { WorkbenchProject.normalized($0.path) != nil }
    guard let current = s.projects.first(where: { $0.name == snap.project }) ?? s.projects.first else { return s }
    if s.toggles["restoreLayout"] == true {
      s.layouts = snap.layouts.mapValues { var l = $0; l.dirty = []; return l }
    }
    s.switchProject(to: current, scanFiles: scanFiles)
    return s
  }
}

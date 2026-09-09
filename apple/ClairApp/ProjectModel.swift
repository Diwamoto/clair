import Darwin
import Foundation

enum ProjectColor: String, CaseIterable, Codable, Hashable, Sendable {
  case blue
  case purple
  case orange
  case green
  case red
  case gray

  var displayName: String {
    rawValue.capitalized
  }
}

enum ProjectAvailability: String, Codable, Equatable, Sendable {
  case available
  case missing
  case notDirectory
  case unreadable

  var isAvailable: Bool {
    self == .available
  }

  var displayName: String {
    switch self {
    case .available:
      "利用可能"
    case .missing:
      "見つかりません"
    case .notDirectory:
      "フォルダではありません"
    case .unreadable:
      "アクセス権がありません"
    }
  }
}

struct Project: Identifiable, Equatable, Sendable {
  let id: UUID
  let rootURL: URL
  var name: String
  var color: ProjectColor
  var availability: ProjectAvailability

  var rootPath: String {
    rootURL.path
  }
}

struct ProjectFileTreeNode: Identifiable, Equatable, Hashable {
  let id: String
  let url: URL
  let name: String
  let isDirectory: Bool
  let children: [ProjectFileTreeNode]?
  let hasMoreChildren: Bool

  var path: String {
    url.path
  }

  var allNodeIDs: Set<String> {
    var result: Set<String> = [id]
    for child in children ?? [] {
      result.formUnion(child.allNodeIDs)
    }
    return result
  }

  func node(withID nodeID: String) -> ProjectFileTreeNode? {
    if id == nodeID {
      return self
    }
    for child in children ?? [] {
      if let match = child.node(withID: nodeID) {
        return match
      }
    }
    return nil
  }
}

/// A directory entry with just the metadata needed to rebuild the visible
/// tree. Keeping this smaller than a full node makes the background directory
/// cache cheap to transfer back to the main actor.
struct ProjectFileTreeDirectoryEntry: Equatable, Hashable, Sendable {
  let id: String
  let name: String
  let isDirectory: Bool
  let isSymbolicLink: Bool
}

struct ProjectFileTreeDirectoryListing: Equatable, Sendable {
  let entries: [ProjectFileTreeDirectoryEntry]
  let hasMoreChildren: Bool
  let directoryModificationTime: TimeInterval?
}

struct ProjectFileTreeSnapshot: Equatable {
  let root: ProjectFileTreeNode?
  let availability: ProjectAvailability
  let isLoading: Bool

  init(
    root: ProjectFileTreeNode?,
    availability: ProjectAvailability,
    isLoading: Bool = false
  ) {
    self.root = root
    self.availability = availability
    self.isLoading = isLoading
  }

  var isAvailable: Bool {
    availability.isAvailable && root != nil
  }

  static func empty(
    for availability: ProjectAvailability,
    isLoading: Bool = false
  ) -> ProjectFileTreeSnapshot {
    ProjectFileTreeSnapshot(root: nil, availability: availability, isLoading: isLoading)
  }

  func node(withID nodeID: String) -> ProjectFileTreeNode? {
    root?.node(withID: nodeID)
  }
}

struct ProjectRecord: Codable, Equatable, Sendable {
  let id: UUID
  var rootPath: String
  var name: String
  var color: ProjectColor
  var isOpen: Bool
  var order: Int
}

struct ProjectStoreSnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var projects: [ProjectRecord]
  var activeProjectID: UUID?

  static var empty: ProjectStoreSnapshot {
    ProjectStoreSnapshot(
      schemaVersion: currentSchemaVersion,
      projects: [],
      activeProjectID: nil
    )
  }
}

enum ProjectPaneOrientation: String, Codable, CaseIterable, Sendable {
  case horizontal
  case vertical
}

enum ProjectPaneTabKind: String, Codable, CaseIterable, Sendable {
  case editor
  case terminal
  case diff
}

struct ProjectPaneTab: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let kind: ProjectPaneTabKind
  var title: String
  let filePath: String?
  let sessionID: UUID?
  let agentProfileID: String?
  let executionRootPath: String?
  let worktreeID: WorktreeID?
  let diffRelativePath: String?
  let diffBasis: ProjectGitDiffBasis?
  var editorSelection: ProjectEditorUTF16Range?
  var editorScrollTop: Double?

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case title
    case filePath
    case sessionID
    case agentProfileID
    case executionRootPath
    case worktreeID
    case diffRelativePath
    case diffBasis
    case editorSelection
    case editorScrollTop
  }

  init(
    id: String,
    kind: ProjectPaneTabKind,
    title: String,
    filePath: String?,
    sessionID: UUID? = nil,
    agentProfileID: String? = nil,
    executionRootURL: URL? = nil,
    worktreeID: WorktreeID? = nil,
    diffRelativePath: String? = nil,
    diffBasis: ProjectGitDiffBasis? = nil,
    editorSelection: ProjectEditorUTF16Range? = nil,
    editorScrollTop: Double? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.filePath = filePath
    self.sessionID = sessionID
    self.agentProfileID = kind == .terminal ? agentProfileID : nil
    self.executionRootPath = kind == .terminal ? executionRootURL?.standardizedFileURL.path : nil
    self.worktreeID = kind == .terminal ? worktreeID : nil
    self.diffRelativePath = kind == .diff ? diffRelativePath : nil
    self.diffBasis = kind == .diff ? diffBasis : nil
    self.editorSelection = kind == .editor ? editorSelection : nil
    self.editorScrollTop = kind == .editor ? editorScrollTop : nil
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(ProjectPaneTabKind.self, forKey: .kind)
    title = try container.decode(String.self, forKey: .title)
    filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
    agentProfileID =
      kind == .terminal
      ? try container.decodeIfPresent(String.self, forKey: .agentProfileID)
      : nil
    executionRootPath =
      kind == .terminal
      ? try container.decodeIfPresent(String.self, forKey: .executionRootPath)
      : nil
    worktreeID =
      kind == .terminal
      ? try container.decodeIfPresent(WorktreeID.self, forKey: .worktreeID)
      : nil
    diffRelativePath =
      kind == .diff
      ? try container.decodeIfPresent(String.self, forKey: .diffRelativePath)
      : nil
    diffBasis =
      kind == .diff
      ? try container.decodeIfPresent(ProjectGitDiffBasis.self, forKey: .diffBasis)
      : nil
    editorSelection =
      kind == .editor
      ? try container.decodeIfPresent(ProjectEditorUTF16Range.self, forKey: .editorSelection)
      : nil
    editorScrollTop =
      kind == .editor
      ? try container.decodeIfPresent(Double.self, forKey: .editorScrollTop)
      : nil
    if kind == .terminal {
      let legacyID =
        id.hasPrefix("terminal:")
        ? String(id.dropFirst("terminal:".count))
        : id
      sessionID =
        try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        ?? UUID(uuidString: legacyID)
        ?? UUID()
    } else {
      sessionID = nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(filePath, forKey: .filePath)
    try container.encodeIfPresent(sessionID, forKey: .sessionID)
    try container.encodeIfPresent(agentProfileID, forKey: .agentProfileID)
    try container.encodeIfPresent(executionRootPath, forKey: .executionRootPath)
    try container.encodeIfPresent(worktreeID, forKey: .worktreeID)
    try container.encodeIfPresent(diffRelativePath, forKey: .diffRelativePath)
    try container.encodeIfPresent(diffBasis, forKey: .diffBasis)
    try container.encodeIfPresent(editorSelection, forKey: .editorSelection)
    try container.encodeIfPresent(editorScrollTop, forKey: .editorScrollTop)
  }

  static func editor(path: String, title: String) -> ProjectPaneTab {
    ProjectPaneTab(
      id: path,
      kind: .editor,
      title: title,
      filePath: path,
      sessionID: nil
    )
  }

  static func terminal(
    id: UUID = UUID(),
    title: String = "ターミナル",
    agentProfileID: String? = nil,
    executionRootURL: URL? = nil,
    worktreeID: WorktreeID? = nil
  ) -> ProjectPaneTab {
    ProjectPaneTab(
      id: "terminal:\(id.uuidString)",
      kind: .terminal,
      title: title,
      filePath: nil,
      sessionID: id,
      agentProfileID: agentProfileID,
      executionRootURL: executionRootURL,
      worktreeID: worktreeID
    )
  }

  var executionRootURL: URL? {
    guard let executionRootPath else {
      return nil
    }
    return URL(fileURLWithPath: executionRootPath, isDirectory: true)
  }

  static func diff(
    id: UUID = UUID(),
    relativePath: String? = nil,
    basis: ProjectGitDiffBasis? = nil
  ) -> ProjectPaneTab {
    let title = relativePath.map { "差分: \(($0 as NSString).lastPathComponent)" } ?? "差分プレビュー"
    return ProjectPaneTab(
      id: "diff:\(id.uuidString)",
      kind: .diff,
      title: title,
      filePath: nil,
      sessionID: nil,
      diffRelativePath: relativePath,
      diffBasis: basis
    )
  }
}

struct ProjectPaneLeaf: Codable, Equatable, Sendable {
  let id: UUID
  var activeTabID: String?

  init(
    id: UUID = UUID(),
    activeTabID: String? = nil
  ) {
    self.id = id
    self.activeTabID = activeTabID
  }
}

indirect enum ProjectPaneNode: Codable, Equatable, Sendable {
  case leaf(ProjectPaneLeaf)
  case split(
    id: UUID,
    orientation: ProjectPaneOrientation,
    ratio: Double,
    first: ProjectPaneNode,
    second: ProjectPaneNode
  )

  var id: UUID {
    switch self {
    case .leaf(let leaf):
      leaf.id
    case .split(let id, _, _, _, _):
      id
    }
  }

  var leafIDs: [UUID] {
    switch self {
    case .leaf(let leaf):
      [leaf.id]
    case .split(_, _, _, let first, let second):
      first.leafIDs + second.leafIDs
    }
  }

  var leaves: [ProjectPaneLeaf] {
    switch self {
    case .leaf(let leaf):
      [leaf]
    case .split(_, _, _, let first, let second):
      first.leaves + second.leaves
    }
  }

  var isLeaf: Bool {
    if case .leaf = self {
      return true
    }
    return false
  }

  func leaf(withID leafID: UUID) -> ProjectPaneLeaf? {
    switch self {
    case .leaf(let leaf):
      return leaf.id == leafID ? leaf : nil
    case .split(_, _, _, let first, let second):
      return first.leaf(withID: leafID) ?? second.leaf(withID: leafID)
    }
  }

  func contains(nodeID: UUID) -> Bool {
    switch self {
    case .leaf(let leaf):
      leaf.id == nodeID
    case .split(let id, _, _, let first, let second):
      id == nodeID || first.contains(nodeID: nodeID) || second.contains(nodeID: nodeID)
    }
  }

  func validate(
    nodeIDs: inout Set<UUID>,
    tabIDs: inout Set<String>
  ) -> Bool {
    guard nodeIDs.insert(id).inserted else {
      return false
    }

    switch self {
    case .leaf(let leaf):
      if let activeTabID = leaf.activeTabID {
        guard !activeTabID.isEmpty, tabIDs.contains(activeTabID) else {
          return false
        }
      }
      return true
    case .split(_, _, let ratio, let first, let second):
      guard ratio.isFinite, (0.05...0.95).contains(ratio) else {
        return false
      }
      guard first.id != second.id else {
        return false
      }
      return first.validate(nodeIDs: &nodeIDs, tabIDs: &tabIDs)
        && second.validate(nodeIDs: &nodeIDs, tabIDs: &tabIDs)
    }
  }
}

struct ProjectSurfaceSnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 2
  static let legacySchemaVersion = 1

  var schemaVersion: Int
  let projectID: UUID
  var tabs: [ProjectPaneTab]
  var root: ProjectPaneNode
  var focusedPaneID: UUID
  var maximizedPaneID: UUID?
  var selectedNodeID: String?
  var expandedNodeIDs: [String]
  var workspaceActivity: String?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case projectID
    case tabs
    case root
    case focusedPaneID
    case maximizedPaneID
    case selectedNodeID
    case expandedNodeIDs
    case workspaceActivity
  }

  init(
    schemaVersion: Int,
    projectID: UUID,
    tabs: [ProjectPaneTab] = [],
    root: ProjectPaneNode,
    focusedPaneID: UUID,
    maximizedPaneID: UUID?,
    selectedNodeID: String?,
    expandedNodeIDs: [String],
    workspaceActivity: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.projectID = projectID
    self.tabs = tabs
    self.root = root
    self.focusedPaneID = focusedPaneID
    self.maximizedPaneID = maximizedPaneID
    self.selectedNodeID = selectedNodeID
    self.expandedNodeIDs = expandedNodeIDs
    self.workspaceActivity = workspaceActivity
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchema = try container.decode(Int.self, forKey: .schemaVersion)
    projectID = try container.decode(UUID.self, forKey: .projectID)
    focusedPaneID = try container.decode(UUID.self, forKey: .focusedPaneID)
    maximizedPaneID = try container.decodeIfPresent(UUID.self, forKey: .maximizedPaneID)
    selectedNodeID = try container.decodeIfPresent(String.self, forKey: .selectedNodeID)
    expandedNodeIDs = try container.decodeIfPresent([String].self, forKey: .expandedNodeIDs) ?? []
    workspaceActivity = try container.decodeIfPresent(String.self, forKey: .workspaceActivity)

    if decodedSchema <= Self.legacySchemaVersion, !container.contains(.tabs) {
      let legacyRoot = try container.decode(LegacyProjectPaneNode.self, forKey: .root)
      let migrated = legacyRoot.migrated()
      tabs = migrated.tabs
      root = migrated.root
      schemaVersion = Self.currentSchemaVersion
    } else {
      tabs = try container.decodeIfPresent([ProjectPaneTab].self, forKey: .tabs) ?? []
      root = try container.decode(ProjectPaneNode.self, forKey: .root)
      schemaVersion = decodedSchema
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(projectID, forKey: .projectID)
    try container.encode(tabs, forKey: .tabs)
    try container.encode(root, forKey: .root)
    try container.encode(focusedPaneID, forKey: .focusedPaneID)
    try container.encodeIfPresent(maximizedPaneID, forKey: .maximizedPaneID)
    try container.encodeIfPresent(selectedNodeID, forKey: .selectedNodeID)
    try container.encode(expandedNodeIDs, forKey: .expandedNodeIDs)
    try container.encodeIfPresent(workspaceActivity, forKey: .workspaceActivity)
  }

  static func empty(for projectID: UUID) -> ProjectSurfaceSnapshot {
    let leaf = ProjectPaneLeaf()
    return ProjectSurfaceSnapshot(
      schemaVersion: currentSchemaVersion,
      projectID: projectID,
      tabs: [],
      root: .leaf(leaf),
      focusedPaneID: leaf.id,
      maximizedPaneID: nil,
      selectedNodeID: nil,
      expandedNodeIDs: [],
      workspaceActivity: nil
    )
  }

  func validated(for expectedProjectID: UUID) -> ProjectSurfaceSnapshot? {
    guard schemaVersion == Self.currentSchemaVersion, projectID == expectedProjectID else {
      return nil
    }
    var tabIDs = Set<String>()
    for tab in tabs {
      guard Self.isValidTab(tab), tabIDs.insert(tab.id).inserted else {
        return nil
      }
    }
    var nodeIDs = Set<UUID>()
    guard root.validate(nodeIDs: &nodeIDs, tabIDs: &tabIDs) else {
      return nil
    }
    guard root.leafIDs.contains(focusedPaneID) else {
      return nil
    }
    if let maximizedPaneID, !root.leafIDs.contains(maximizedPaneID) {
      return nil
    }
    return self
  }

  private static func isValidTab(_ tab: ProjectPaneTab) -> Bool {
    guard !tab.id.isEmpty, !tab.title.isEmpty else {
      return false
    }
    switch tab.kind {
    case .editor:
      guard
        let filePath = tab.filePath,
        !filePath.isEmpty,
        tab.executionRootPath == nil,
        tab.worktreeID == nil
      else {
        return false
      }
      if let selection = tab.editorSelection,
        selection.location < 0 || selection.length < 0
          || selection.location > Int.max - selection.length
      {
        return false
      }
      if let scrollTop = tab.editorScrollTop,
        !scrollTop.isFinite || scrollTop < 0
      {
        return false
      }
    case .terminal, .diff:
      guard tab.filePath == nil else {
        return false
      }
      if tab.kind == .diff
        && (tab.executionRootPath != nil || tab.worktreeID != nil
          || tab.diffRelativePath?.isEmpty == true)
      {
        return false
      }
      if tab.kind == .terminal
        && (tab.diffRelativePath != nil || tab.diffBasis != nil)
      {
        return false
      }
      if tab.kind == .terminal, tab.worktreeID != nil, tab.executionRootPath == nil {
        return false
      }
      if tab.kind == .terminal, tab.sessionID == nil {
        return false
      }
    }
    return true
  }
}

private struct LegacyProjectPaneLeaf: Codable {
  let id: UUID
  var tabs: [ProjectPaneTab]
  var activeTabID: String?
}

private indirect enum LegacyProjectPaneNode: Codable {
  case leaf(LegacyProjectPaneLeaf)
  case split(
    id: UUID,
    orientation: ProjectPaneOrientation,
    ratio: Double,
    first: LegacyProjectPaneNode,
    second: LegacyProjectPaneNode
  )

  func migrated() -> (root: ProjectPaneNode, tabs: [ProjectPaneTab]) {
    switch self {
    case .leaf(let leaf):
      return (
        .leaf(ProjectPaneLeaf(id: leaf.id, activeTabID: leaf.activeTabID)),
        leaf.tabs
      )
    case .split(let id, let orientation, let ratio, let first, let second):
      let migratedFirst = first.migrated()
      let migratedSecond = second.migrated()
      return (
        .split(
          id: id,
          orientation: orientation,
          ratio: ratio,
          first: migratedFirst.root,
          second: migratedSecond.root
        ),
        migratedFirst.tabs + migratedSecond.tabs
      )
    }
  }
}

/// A tab from the surface tab store, with the pane currently showing it if any.
///
/// The native shell renders these in one workspace-level titlebar strip. Pane
/// identity is a viewport onto the store, not ownership of the tab.
struct ProjectWorkspaceTab: Identifiable, Equatable, Sendable {
  let paneID: UUID?
  let tab: ProjectPaneTab

  var id: String {
    tab.id
  }
}

struct ProjectWorkspaceStoreSnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var surfaces: [ProjectSurfaceSnapshot]

  static var empty: ProjectWorkspaceStoreSnapshot {
    ProjectWorkspaceStoreSnapshot(
      schemaVersion: currentSchemaVersion,
      surfaces: []
    )
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case surfaces
  }

  init(
    schemaVersion: Int,
    surfaces: [ProjectSurfaceSnapshot]
  ) {
    self.schemaVersion = schemaVersion
    self.surfaces = surfaces
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    var surfaceContainer = try container.nestedUnkeyedContainer(forKey: .surfaces)
    var decodedSurfaces: [ProjectSurfaceSnapshot] = []
    while !surfaceContainer.isAtEnd {
      let itemDecoder = try surfaceContainer.superDecoder()
      if let surface = try? ProjectSurfaceSnapshot(from: itemDecoder) {
        decodedSurfaces.append(surface)
      }
    }
    surfaces = decodedSurfaces
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(surfaces, forKey: .surfaces)
  }
}

enum ProjectFileTreeScanner {
  static let maxChildrenPerDirectory = 256
  static let maxDirectoryEntriesPerRefresh = 4_096
  static let maxCachedDirectories = 4_096
  static let maxCachedEntries = 65_536
  static let maxWatchedDirectories = 256
  static let maxWatchedFiles = 512

  private static let ignoredDirectoryNames: Set<String> = [
    ".build",
    ".cache",
    ".git",
    ".next",
    ".swiftpm",
    ".venv",
    "Build",
    "DerivedData",
    "Pods",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "out",
    "target",
    "tmp",
    "vendor",
    "venv",
  ]

  static func shouldIgnoreDirectory(named name: String) -> Bool {
    ignoredDirectoryNames.contains(name)
  }

  static func scan(
    rootURL: URL,
    rootChecker: any ProjectRootChecking,
    fileManager: FileManager = .default
  ) -> ProjectFileTreeSnapshot {
    do {
      let canonicalURL = try rootChecker.validate(rootURL)
      return scanLoaded(
        rootURL: canonicalURL,
        loadedDirectoryPaths: [canonicalURL.path],
        fileManager: fileManager
      )
    } catch ProjectError.rootMissing {
      return .empty(for: .missing)
    } catch ProjectError.rootNotDirectory {
      return .empty(for: .notDirectory)
    } catch ProjectError.rootUnreadable {
      return .empty(for: .unreadable)
    } catch {
      return .empty(for: .unreadable)
    }
  }

  static func scanLoaded(
    rootURL: URL,
    loadedDirectoryPaths: Set<String>,
    directoryEntryLimits: [String: Int] = [:],
    directoryCache: [String: ProjectFileTreeDirectoryListing] = [:],
    fileManager: FileManager = .default
  ) -> ProjectFileTreeSnapshot {
    let rootURL = rootURL.standardizedFileURL
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
      return .empty(for: .missing)
    }
    guard isDirectory.boolValue else {
      return .empty(for: .notDirectory)
    }
    guard fileManager.isReadableFile(atPath: rootURL.path) else {
      return .empty(for: .unreadable)
    }

    let rootPath = rootURL.path
    let loadedPaths = Set(
      loadedDirectoryPaths.map {
        URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
      }
    ).filter { path in
      path == rootPath || path.hasPrefix(rootPath + "/")
    }

    do {
      let root = try loadedNode(
        at: rootURL,
        loadedDirectoryPaths: loadedPaths,
        directoryEntryLimits: directoryEntryLimits,
        directoryCache: directoryCache,
        fileManager: fileManager,
        isRoot: true
      )
      return ProjectFileTreeSnapshot(root: root, availability: .available)
    } catch {
      return .empty(for: .unreadable)
    }
  }

  /// Reads directory metadata once in the background so expanding a folder
  /// does not have to wait for a fresh filesystem walk. The visible tree still
  /// remains lazy; only lightweight directory listings are prefetched.
  static func prefetchDirectoryCache(
    rootURL: URL,
    fileManager: FileManager = .default
  ) -> [String: ProjectFileTreeDirectoryListing] {
    let rootURL = rootURL.standardizedFileURL
    var isDirectory = ObjCBool(false)
    guard
      fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      fileManager.isReadableFile(atPath: rootURL.path)
    else {
      return [:]
    }

    var cache: [String: ProjectFileTreeDirectoryListing] = [:]
    var pending = [rootURL]
    var pendingIndex = 0
    var cachedEntryCount = 0

    while pendingIndex < pending.count, cache.count < maxCachedDirectories {
      if Task.isCancelled {
        break
      }

      let directoryURL = pending[pendingIndex]
      pendingIndex += 1
      let directoryPath = directoryURL.standardizedFileURL.path
      guard cache[directoryPath] == nil else {
        continue
      }

      guard
        let listing = immediateChildListing(
          at: directoryURL,
          limit: maxDirectoryEntriesPerRefresh,
          fileManager: fileManager
        )
      else {
        continue
      }
      cache[directoryPath] = listing
      cachedEntryCount += listing.entries.count
      if cachedEntryCount >= maxCachedEntries {
        break
      }

      for entry in listing.entries where entry.isDirectory && !entry.isSymbolicLink {
        guard !shouldIgnoreDirectory(named: entry.name) else {
          continue
        }
        pending.append(URL(fileURLWithPath: entry.id, isDirectory: true))
      }
    }

    return cache
  }

  static func directoriesToWatch(
    rootURL: URL,
    loadedDirectoryPaths: Set<String> = [],
    fileManager: FileManager = .default
  ) -> [URL] {
    let normalizedRoot = rootURL.standardizedFileURL
    let existingRoot = existingDirectory(for: normalizedRoot, fileManager: fileManager)
    let watchRoot =
      existingRoot
      ?? nearestExistingDirectory(
        for: normalizedRoot.deletingLastPathComponent(),
        fileManager: fileManager
      )

    guard let watchRoot else {
      return []
    }

    guard existingRoot != nil else {
      return [watchRoot]
    }

    var directories = [normalizedRoot]
    let rootPath = normalizedRoot.path
    let normalizedLoadedPaths =
      loadedDirectoryPaths
      .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
      .filter { url in
        url.path != rootPath
          && url.path.hasPrefix(rootPath + "/")
          && !shouldIgnoreDirectory(named: url.lastPathComponent)
      }
      .sorted { $0.path < $1.path }

    for url in normalizedLoadedPaths {
      guard directories.count < maxWatchedDirectories else {
        break
      }
      guard existingDirectory(for: url, fileManager: fileManager) != nil else {
        continue
      }
      directories.append(url)
    }
    return directories
  }

  static func pathsToWatch(
    rootURL: URL,
    loadedDirectoryPaths: Set<String> = [],
    fileManager: FileManager = .default
  ) -> [URL] {
    let directories = directoriesToWatch(
      rootURL: rootURL,
      loadedDirectoryPaths: loadedDirectoryPaths,
      fileManager: fileManager
    )
    var paths = directories
    paths.append(
      contentsOf: regularFilesToWatch(
        in: directories,
        fileManager: fileManager
      )
    )
    paths.append(contentsOf: gitMetadataPaths(rootURL: rootURL, fileManager: fileManager))
    return Array(Set(paths.map(\.path))).sorted().map { path in
      var isDirectory = ObjCBool(false)
      _ = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
      return URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
    }
  }

  private static func regularFilesToWatch(
    in directories: [URL],
    fileManager: FileManager
  ) -> [URL] {
    var files: [URL] = []
    for directory in directories {
      guard
        let enumerator = fileManager.enumerator(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
          options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        )
      else {
        continue
      }

      while let url = enumerator.nextObject() as? URL {
        if files.count >= maxWatchedFiles {
          return files
        }
        guard
          let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
          )
        else {
          continue
        }
        if values.isDirectory == true {
          if values.isSymbolicLink == true || shouldIgnoreDirectory(named: url.lastPathComponent) {
            enumerator.skipDescendants()
          }
          continue
        }
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
          continue
        }
        files.append(url.standardizedFileURL)
      }
    }
    return files
  }

  private static func gitMetadataPaths(
    rootURL: URL,
    fileManager: FileManager
  ) -> [URL] {
    let gitURL = rootURL.standardizedFileURL.appendingPathComponent(".git", isDirectory: true)
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) else {
      return []
    }

    guard isDirectory.boolValue else {
      return [gitURL]
    }

    let candidates = [
      gitURL,
      gitURL.appendingPathComponent("HEAD"),
      gitURL.appendingPathComponent("index"),
      gitURL.appendingPathComponent("packed-refs"),
      gitURL.appendingPathComponent("refs", isDirectory: true),
      gitURL.appendingPathComponent("logs/HEAD"),
    ]
    return candidates.filter { fileManager.fileExists(atPath: $0.path) }
  }

  private static func loadedNode(
    at url: URL,
    loadedDirectoryPaths: Set<String>,
    directoryEntryLimits: [String: Int],
    directoryCache: [String: ProjectFileTreeDirectoryListing],
    fileManager: FileManager,
    isRoot: Bool,
    cachedEntry: ProjectFileTreeDirectoryEntry? = nil
  ) throws -> ProjectFileTreeNode {
    let standardizedURL: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let name: String
    if let cachedEntry {
      standardizedURL = URL(fileURLWithPath: cachedEntry.id, isDirectory: cachedEntry.isDirectory)
      isDirectory = cachedEntry.isDirectory
      isSymbolicLink = cachedEntry.isSymbolicLink
      name = cachedEntry.name
    } else {
      let values = try url.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
      )
      standardizedURL = url.standardizedFileURL
      isDirectory = values.isDirectory == true
      isSymbolicLink = values.isSymbolicLink == true
      name = isRoot && url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
    let id = standardizedURL.path

    guard isDirectory, !isSymbolicLink else {
      return ProjectFileTreeNode(
        id: id,
        url: standardizedURL,
        name: name,
        isDirectory: false,
        children: nil,
        hasMoreChildren: false
      )
    }

    guard loadedDirectoryPaths.contains(id) else {
      return ProjectFileTreeNode(
        id: id,
        url: standardizedURL,
        name: name,
        isDirectory: true,
        children: nil,
        hasMoreChildren: false
      )
    }

    let requestedLimit = directoryEntryLimits[id] ?? maxChildrenPerDirectory
    let limit = min(
      max(requestedLimit, maxChildrenPerDirectory),
      maxDirectoryEntriesPerRefresh
    )
    let listing: ProjectFileTreeDirectoryListing?
    if let cachedListing = directoryCache[id],
      cacheIsCurrent(
        cachedListing,
        directoryURL: standardizedURL,
        fileManager: fileManager
      )
    {
      listing = cachedListing
    } else {
      listing = immediateChildListing(
        at: standardizedURL,
        limit: limit,
        fileManager: fileManager
      )
    }
    guard let listing else {
      if isRoot {
        throw ProjectError.rootUnreadable(path: standardizedURL.path)
      }
      return ProjectFileTreeNode(
        id: id,
        url: standardizedURL,
        name: name,
        isDirectory: true,
        children: [],
        hasMoreChildren: false
      )
    }
    let entries = Array(listing.entries.prefix(limit))
    let children = entries.compactMap { entry -> ProjectFileTreeNode? in
      guard !shouldIgnoreDirectory(named: entry.name) else {
        return nil
      }
      let childURL = URL(fileURLWithPath: entry.id, isDirectory: entry.isDirectory)
      return try? loadedNode(
        at: childURL,
        loadedDirectoryPaths: loadedDirectoryPaths,
        directoryEntryLimits: directoryEntryLimits,
        directoryCache: directoryCache,
        fileManager: fileManager,
        isRoot: false,
        cachedEntry: entry
      )
    }.sorted(by: sortNodes)

    return ProjectFileTreeNode(
      id: id,
      url: standardizedURL,
      name: name,
      isDirectory: true,
      children: children,
      hasMoreChildren: listing.hasMoreChildren || listing.entries.count > entries.count
    )
  }

  private static func immediateChildListing(
    at directoryURL: URL,
    limit: Int,
    fileManager: FileManager
  ) -> ProjectFileTreeDirectoryListing? {
    guard
      let enumerator = fileManager.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
        options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
      )
    else {
      return nil
    }

    let directoryModificationTime = (try? directoryURL.resourceValues(
      forKeys: [.contentModificationDateKey]
    ))?.contentModificationDate?.timeIntervalSinceReferenceDate
    var entries: [ProjectFileTreeDirectoryEntry] = []
    while let url = enumerator.nextObject() as? URL {
      let standardizedURL = url.standardizedFileURL
      guard
        let values = try? standardizedURL.resourceValues(
          forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        ),
        values.isDirectory == true || values.isRegularFile == true
      else {
        continue
      }

      entries.append(
        ProjectFileTreeDirectoryEntry(
          id: standardizedURL.path,
          name: standardizedURL.lastPathComponent,
          isDirectory: values.isDirectory == true,
          isSymbolicLink: values.isSymbolicLink == true
        )
      )
      if entries.count >= limit {
        return ProjectFileTreeDirectoryListing(
          entries: entries,
          hasMoreChildren: enumerator.nextObject() != nil,
          directoryModificationTime: directoryModificationTime
        )
      }
    }
    return ProjectFileTreeDirectoryListing(
      entries: entries,
      hasMoreChildren: false,
      directoryModificationTime: directoryModificationTime
    )
  }

  private static func cacheIsCurrent(
    _ listing: ProjectFileTreeDirectoryListing,
    directoryURL: URL,
    fileManager: FileManager
  ) -> Bool {
    let currentTime = (try? directoryURL.resourceValues(
      forKeys: [.contentModificationDateKey]
    ))?.contentModificationDate?.timeIntervalSinceReferenceDate
    return currentTime == listing.directoryModificationTime
  }

  private static func sortNodes(
    _ lhs: ProjectFileTreeNode,
    _ rhs: ProjectFileTreeNode
  ) -> Bool {
    if lhs.isDirectory != rhs.isDirectory {
      return lhs.isDirectory
    }
    let comparison = lhs.name.localizedStandardCompare(rhs.name)
    if comparison != .orderedSame {
      return comparison == .orderedAscending
    }
    return lhs.id < rhs.id
  }

  private static func existingDirectory(
    for url: URL,
    fileManager: FileManager
  ) -> URL? {
    var isDirectory = ObjCBool(false)
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return nil
    }
    return url.standardizedFileURL
  }

  private static func nearestExistingDirectory(
    for url: URL,
    fileManager: FileManager
  ) -> URL? {
    var candidate = url.standardizedFileURL
    while candidate.path != candidate.deletingLastPathComponent().path {
      if let existing = existingDirectory(for: candidate, fileManager: fileManager) {
        return existing
      }
      candidate.deleteLastPathComponent()
    }
    return existingDirectory(for: candidate, fileManager: fileManager)
  }
}

final class ProjectFileSystemWatcher: @unchecked Sendable {
  private let rootURL: URL
  private let fileManager: FileManager
  private let queue: DispatchQueue
  private let onChange: @Sendable () -> Void
  private var sources: [String: DispatchSourceFileSystemObject] = [:]
  private var pendingEventWorkItem: DispatchWorkItem?
  private var loadedDirectoryPaths: Set<String> = []
  private var isStarted = false

  init(
    rootURL: URL,
    fileManager: FileManager = .default,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.rootURL = rootURL
    self.fileManager = fileManager
    self.queue = DispatchQueue(
      label: "com.diwamoto.clair.file-tree.\(UUID().uuidString)",
      qos: .utility
    )
    self.onChange = onChange
  }

  func start() {
    queue.sync {
      guard !isStarted else {
        return
      }
      isStarted = true
      rebuildSources()
    }
  }

  func updateWatchedDirectories(_ directories: [URL]) {
    queue.sync {
      loadedDirectoryPaths = Set(directories.map { $0.standardizedFileURL.path })
      if isStarted {
        rebuildSources()
      }
    }
  }

  var watchedPathCount: Int {
    queue.sync { sources.count }
  }

  func stop() {
    queue.sync {
      guard isStarted else {
        return
      }
      isStarted = false
      pendingEventWorkItem?.cancel()
      pendingEventWorkItem = nil
      cancelSources()
    }
  }

  private func handleEvent() {
    pendingEventWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.isStarted else {
        return
      }
      self.rebuildSources()
      self.onChange()
      self.pendingEventWorkItem = nil
    }
    pendingEventWorkItem = workItem
    queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: workItem)
  }

  private func rebuildSources() {
    guard isStarted else {
      return
    }

    let desiredPaths = Set(
      ProjectFileTreeScanner.pathsToWatch(
        rootURL: rootURL,
        loadedDirectoryPaths: loadedDirectoryPaths,
        fileManager: fileManager
      ).map(\.path)
    )

    let stalePaths = sources.keys.filter { !desiredPaths.contains($0) }
    for path in stalePaths {
      sources[path]?.cancel()
      sources[path] = nil
    }

    for path in desiredPaths where sources[path] == nil {
      let descriptor = open(path, O_EVTONLY)
      guard descriptor >= 0 else {
        continue
      }

      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .delete, .rename, .revoke],
        queue: queue
      )
      source.setEventHandler { [weak self] in
        self?.handleEvent()
      }
      source.setCancelHandler {
        close(descriptor)
      }
      sources[path] = source
      source.resume()
    }
  }

  private func cancelSources() {
    for source in sources.values {
      source.cancel()
    }
    sources.removeAll()
  }
}

enum ProjectError: Error, Equatable, LocalizedError, Sendable {
  case rootMissing(path: String)
  case rootNotDirectory(path: String)
  case rootUnreadable(path: String)
  case duplicateRoot(existingProjectID: UUID)
  case projectNotFound(UUID)
  case projectNotOpen(UUID)
  case invalidName
  case invalidOrder(Int)
  case storeUnavailable
  case storeIO(String)
  case unsupportedStoreVersion(Int)
  case malformedStore
  case workspaceUnavailable
  case workspaceIO(String)
  case unsupportedWorkspaceVersion(Int)
  case malformedWorkspaceStore

  var errorDescription: String? {
    switch self {
    case .rootMissing(let path):
      "Project folder does not exist: \(path)"
    case .rootNotDirectory(let path):
      "Project root is not a folder: \(path)"
    case .rootUnreadable(let path):
      "Project folder is not readable: \(path)"
    case .duplicateRoot(let id):
      "That folder is already open as Project \(id.uuidString)."
    case .projectNotFound(let id):
      "Project \(id.uuidString) was not found."
    case .projectNotOpen(let id):
      "Project \(id.uuidString) is not open."
    case .invalidName:
      "Project name cannot be empty."
    case .invalidOrder(let index):
      "Project position is invalid: \(index)."
    case .storeUnavailable:
      "Clair's local Project store is unavailable."
    case .storeIO(let message):
      "Clair could not update the local Project store: \(message)"
    case .unsupportedStoreVersion(let version):
      "Clair does not support Project store version \(version)."
    case .malformedStore:
      "Clair's local Project store is malformed."
    case .workspaceUnavailable:
      "Clair's local workspace store is unavailable."
    case .workspaceIO(let message):
      "Clair could not update the local workspace store: \(message)"
    case .unsupportedWorkspaceVersion(let version):
      "Clair does not support workspace store version \(version)."
    case .malformedWorkspaceStore:
      "Clair's local workspace store is malformed."
    }
  }
}

protocol ProjectRootChecking {
  func canonicalURL(for rootURL: URL) -> URL
  func validate(_ rootURL: URL) throws -> URL
  func availability(for rootURL: URL) -> ProjectAvailability
}

struct FileSystemProjectRootChecker: ProjectRootChecking {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func canonicalURL(for rootURL: URL) -> URL {
    rootURL.standardizedFileURL.resolvingSymlinksInPath()
  }

  func validate(_ rootURL: URL) throws -> URL {
    let canonicalURL = canonicalURL(for: rootURL)
    var isDirectory = ObjCBool(false)

    guard fileManager.fileExists(atPath: canonicalURL.path, isDirectory: &isDirectory) else {
      throw ProjectError.rootMissing(path: canonicalURL.path)
    }
    guard isDirectory.boolValue else {
      throw ProjectError.rootNotDirectory(path: canonicalURL.path)
    }
    guard fileManager.isReadableFile(atPath: canonicalURL.path) else {
      throw ProjectError.rootUnreadable(path: canonicalURL.path)
    }

    return canonicalURL
  }

  func availability(for rootURL: URL) -> ProjectAvailability {
    do {
      _ = try validate(rootURL)
      return .available
    } catch ProjectError.rootMissing {
      return .missing
    } catch ProjectError.rootNotDirectory {
      return .notDirectory
    } catch ProjectError.rootUnreadable {
      return .unreadable
    } catch {
      return .unreadable
    }
  }
}

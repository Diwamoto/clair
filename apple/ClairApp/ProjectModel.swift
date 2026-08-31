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
      "Available"
    case .missing:
      "Missing"
    case .notDirectory:
      "Not a folder"
    case .unreadable:
      "Permission denied"
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

struct ProjectFileTreeSnapshot: Equatable {
  let root: ProjectFileTreeNode?
  let availability: ProjectAvailability

  var isAvailable: Bool {
    availability.isAvailable && root != nil
  }

  static func empty(for availability: ProjectAvailability) -> ProjectFileTreeSnapshot {
    ProjectFileTreeSnapshot(root: nil, availability: availability)
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

  static func editor(path: String, title: String) -> ProjectPaneTab {
    ProjectPaneTab(
      id: path,
      kind: .editor,
      title: title,
      filePath: path
    )
  }

  static func terminal(id: UUID = UUID()) -> ProjectPaneTab {
    ProjectPaneTab(
      id: "terminal:\(id.uuidString)",
      kind: .terminal,
      title: "Terminal",
      filePath: nil
    )
  }

  static func diff(id: UUID = UUID()) -> ProjectPaneTab {
    ProjectPaneTab(
      id: "diff:\(id.uuidString)",
      kind: .diff,
      title: "Diff Preview",
      filePath: nil
    )
  }
}

struct ProjectPaneLeaf: Codable, Equatable, Sendable {
  let id: UUID
  var tabs: [ProjectPaneTab]
  var activeTabID: String?

  init(
    id: UUID = UUID(),
    tabs: [ProjectPaneTab] = [],
    activeTabID: String? = nil
  ) {
    self.id = id
    self.tabs = tabs
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
      let ids = Set(leaf.tabs.map(\.id))
      guard ids.count == leaf.tabs.count else {
        return false
      }
      if let activeTabID = leaf.activeTabID, !ids.contains(activeTabID) {
        return false
      }
      for tab in leaf.tabs {
        guard !tab.id.isEmpty, !tab.title.isEmpty, tabIDs.insert(tab.id).inserted else {
          return false
        }
        switch tab.kind {
        case .editor:
          guard let filePath = tab.filePath, !filePath.isEmpty else {
            return false
          }
        case .terminal, .diff:
          guard tab.filePath == nil else {
            return false
          }
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
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  let projectID: UUID
  var root: ProjectPaneNode
  var focusedPaneID: UUID
  var maximizedPaneID: UUID?
  var selectedNodeID: String?
  var expandedNodeIDs: [String]

  static func empty(for projectID: UUID) -> ProjectSurfaceSnapshot {
    let leaf = ProjectPaneLeaf()
    return ProjectSurfaceSnapshot(
      schemaVersion: currentSchemaVersion,
      projectID: projectID,
      root: .leaf(leaf),
      focusedPaneID: leaf.id,
      maximizedPaneID: nil,
      selectedNodeID: nil,
      expandedNodeIDs: []
    )
  }

  func validated(for expectedProjectID: UUID) -> ProjectSurfaceSnapshot? {
    guard schemaVersion == Self.currentSchemaVersion, projectID == expectedProjectID else {
      return nil
    }
    var nodeIDs = Set<UUID>()
    var tabIDs = Set<String>()
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
  static func scan(
    rootURL: URL,
    rootChecker: any ProjectRootChecking,
    fileManager: FileManager = .default
  ) -> ProjectFileTreeSnapshot {
    do {
      let canonicalURL = try rootChecker.validate(rootURL)
      let root = try node(at: canonicalURL, fileManager: fileManager, isRoot: true)
      return ProjectFileTreeSnapshot(root: root, availability: .available)
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

  static func directoriesToWatch(
    rootURL: URL,
    fileManager: FileManager = .default
  ) -> [URL] {
    let watchRoot =
      existingDirectory(for: rootURL, fileManager: fileManager)
      ?? nearestExistingDirectory(
        for: rootURL.deletingLastPathComponent(),
        fileManager: fileManager
      )

    guard let watchRoot else {
      return []
    }

    guard existingDirectory(for: rootURL, fileManager: fileManager) != nil else {
      return [watchRoot]
    }

    var directories = [watchRoot]
    guard
      let enumerator = fileManager.enumerator(
        at: watchRoot,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsPackageDescendants]
      )
    else {
      return directories
    }

    for case let url as URL in enumerator {
      guard url.lastPathComponent != ".git" else {
        enumerator.skipDescendants()
        continue
      }

      guard
        let values = try? url.resourceValues(
          forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ), values.isDirectory == true, values.isSymbolicLink != true
      else {
        continue
      }
      directories.append(url)
    }
    return directories
  }

  private static func node(
    at url: URL,
    fileManager: FileManager,
    isRoot: Bool
  ) throws -> ProjectFileTreeNode {
    let values = try url.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    let isDirectory = values.isDirectory == true
    let isSymbolicLink = values.isSymbolicLink == true
    let name = isRoot && url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    let id = url.standardizedFileURL.path

    guard isDirectory, !isSymbolicLink, name != ".git" else {
      return ProjectFileTreeNode(
        id: id,
        url: url,
        name: name,
        isDirectory: isDirectory,
        children: nil
      )
    }

    let childURLs = try fileManager.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    let children = childURLs.compactMap { childURL -> ProjectFileTreeNode? in
      guard childURL.lastPathComponent != ".git" else {
        return nil
      }
      do {
        return try node(at: childURL, fileManager: fileManager, isRoot: false)
      } catch {
        return nil
      }
    }.sorted(by: sortNodes)

    return ProjectFileTreeNode(
      id: id,
      url: url,
      name: name,
      isDirectory: true,
      children: children
    )
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

  func stop() {
    queue.sync {
      guard isStarted else {
        return
      }
      isStarted = false
      cancelSources()
    }
  }

  private func handleEvent() {
    rebuildSources()
    onChange()
  }

  private func rebuildSources() {
    guard isStarted else {
      return
    }

    let desiredPaths = Set(
      ProjectFileTreeScanner.directoriesToWatch(
        rootURL: rootURL,
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

    do {
      _ = try fileManager.contentsOfDirectory(
        at: canonicalURL,
        includingPropertiesForKeys: nil,
        options: []
      )
    } catch {
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

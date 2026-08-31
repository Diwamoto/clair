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

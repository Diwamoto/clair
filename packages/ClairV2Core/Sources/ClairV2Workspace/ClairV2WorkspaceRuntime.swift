import ClairV2Shared
import Foundation

public struct ClairV2WorkspaceLimits: Codable, Equatable, Sendable {
  public static let hardMaximumFileReadBytes = 16 * 1024 * 1024
  public static let hardMaximumTreeEntries = 16 * 1024
  public static let hardMaximumTreeDepth = 32
  public static let hardMaximumChangedFiles = 4 * 1024
  public static let hardMaximumChangedOutputBytes = 1024 * 1024
  public static let hardMaximumGitOutputBytes = 4 * 1024 * 1024

  public let maximumFileReadBytes: Int
  public let maximumTreeEntries: Int
  public let maximumTreeDepth: Int
  public let maximumChangedFiles: Int
  public let maximumChangedOutputBytes: Int
  public let maximumGitOutputBytes: Int

  public static let standard = Self(
    uncheckedMaximumFileReadBytes: 1024 * 1024,
    uncheckedMaximumTreeEntries: 4 * 1024,
    uncheckedMaximumTreeDepth: 16,
    uncheckedMaximumChangedFiles: 512,
    uncheckedMaximumChangedOutputBytes: 64 * 1024,
    uncheckedMaximumGitOutputBytes: 256 * 1024
  )

  public init(
    maximumFileReadBytes: Int = Self.standard.maximumFileReadBytes,
    maximumTreeEntries: Int = Self.standard.maximumTreeEntries,
    maximumTreeDepth: Int = Self.standard.maximumTreeDepth,
    maximumChangedFiles: Int = Self.standard.maximumChangedFiles,
    maximumChangedOutputBytes: Int = Self.standard.maximumChangedOutputBytes,
    maximumGitOutputBytes: Int = Self.standard.maximumGitOutputBytes
  ) throws {
    guard maximumFileReadBytes > 0,
      maximumFileReadBytes <= Self.hardMaximumFileReadBytes,
      maximumTreeEntries > 0,
      maximumTreeEntries <= Self.hardMaximumTreeEntries,
      maximumTreeDepth >= 0,
      maximumTreeDepth <= Self.hardMaximumTreeDepth,
      maximumChangedFiles > 0,
      maximumChangedFiles <= Self.hardMaximumChangedFiles,
      maximumChangedOutputBytes > 0,
      maximumChangedOutputBytes <= Self.hardMaximumChangedOutputBytes,
      maximumGitOutputBytes >= maximumChangedOutputBytes,
      maximumGitOutputBytes <= Self.hardMaximumGitOutputBytes
    else {
      throw ClairV2WorkspaceError.invalidLimits
    }

    self = Self(
      uncheckedMaximumFileReadBytes: maximumFileReadBytes,
      uncheckedMaximumTreeEntries: maximumTreeEntries,
      uncheckedMaximumTreeDepth: maximumTreeDepth,
      uncheckedMaximumChangedFiles: maximumChangedFiles,
      uncheckedMaximumChangedOutputBytes: maximumChangedOutputBytes,
      uncheckedMaximumGitOutputBytes: maximumGitOutputBytes
    )
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumFileReadBytes: container.decode(Int.self, forKey: .maximumFileReadBytes),
      maximumTreeEntries: container.decode(Int.self, forKey: .maximumTreeEntries),
      maximumTreeDepth: container.decode(Int.self, forKey: .maximumTreeDepth),
      maximumChangedFiles: container.decode(Int.self, forKey: .maximumChangedFiles),
      maximumChangedOutputBytes: container.decode(
        Int.self,
        forKey: .maximumChangedOutputBytes
      ),
      maximumGitOutputBytes: container.decode(Int.self, forKey: .maximumGitOutputBytes)
    )
  }

  private init(
    uncheckedMaximumFileReadBytes: Int,
    uncheckedMaximumTreeEntries: Int,
    uncheckedMaximumTreeDepth: Int,
    uncheckedMaximumChangedFiles: Int,
    uncheckedMaximumChangedOutputBytes: Int,
    uncheckedMaximumGitOutputBytes: Int
  ) {
    maximumFileReadBytes = uncheckedMaximumFileReadBytes
    maximumTreeEntries = uncheckedMaximumTreeEntries
    maximumTreeDepth = uncheckedMaximumTreeDepth
    maximumChangedFiles = uncheckedMaximumChangedFiles
    maximumChangedOutputBytes = uncheckedMaximumChangedOutputBytes
    maximumGitOutputBytes = uncheckedMaximumGitOutputBytes
  }

  private enum CodingKeys: String, CodingKey {
    case maximumFileReadBytes
    case maximumTreeEntries
    case maximumTreeDepth
    case maximumChangedFiles
    case maximumChangedOutputBytes
    case maximumGitOutputBytes
  }
}

public struct ClairV2FileTreeOptions: Codable, Equatable, Sendable {
  public let maximumDepth: Int
  public let maximumEntries: Int

  public static let standard = Self(
    uncheckedMaximumDepth: 4,
    uncheckedMaximumEntries: 256
  )

  public init(
    maximumDepth: Int = Self.standard.maximumDepth,
    maximumEntries: Int = Self.standard.maximumEntries
  ) throws {
    guard maximumDepth >= 0,
      maximumDepth <= ClairV2WorkspaceLimits.hardMaximumTreeDepth,
      maximumEntries > 0,
      maximumEntries <= ClairV2WorkspaceLimits.hardMaximumTreeEntries
    else {
      throw ClairV2WorkspaceError.invalidLimits
    }
    self = Self(
      uncheckedMaximumDepth: maximumDepth,
      uncheckedMaximumEntries: maximumEntries
    )
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumDepth: container.decode(Int.self, forKey: .maximumDepth),
      maximumEntries: container.decode(Int.self, forKey: .maximumEntries)
    )
  }

  fileprivate init(uncheckedMaximumDepth: Int, uncheckedMaximumEntries: Int) {
    maximumDepth = uncheckedMaximumDepth
    maximumEntries = uncheckedMaximumEntries
  }

  private enum CodingKeys: String, CodingKey {
    case maximumDepth
    case maximumEntries
  }
}

/// A path relative to a registered Project or Worktree root.
///
/// The value is deliberately not a URL or an arbitrary filesystem path. It
/// cannot be absolute, contain `..`, contain a path separator other than `/`,
/// or contain control characters. Filesystem symlinks are checked separately
/// when the value is resolved.
public struct ClairV2WorkspacePath: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  public static let root = Self(unchecked: ".")

  public init(_ rawValue: String) throws {
    self.rawValue = try Self.normalized(rawValue)
  }

  public init?(rawValue: String) {
    guard let value = try? Self(rawValue) else { return nil }
    self = value
  }

  public var components: [String] {
    rawValue == "." ? [] : rawValue.split(separator: "/").map(String.init)
  }

  public var description: String { rawValue }

  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }

  private static func normalized(_ rawValue: String) throws -> String {
    guard !rawValue.isEmpty,
      rawValue.utf8.count <= 4 * 1024,
      !rawValue.hasPrefix("/"),
      !rawValue.contains("\\"),
      !rawValue.unicodeScalars.contains(where: { scalar in
        scalar.value < 0x20 || scalar.value == 0x7f
      })
    else {
      if rawValue.hasPrefix("/") || rawValue.split(separator: "/").contains("..") {
        throw ClairV2WorkspaceError.pathEscapesRoot
      }
      throw ClairV2WorkspaceError.invalidPath
    }

    if rawValue == "." {
      return rawValue
    }

    let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      components.allSatisfy({ component in
        !component.isEmpty && component != "." && component != ".."
      })
    else {
      if components.contains(where: { $0 == ".." }) {
        throw ClairV2WorkspaceError.pathEscapesRoot
      }
      throw ClairV2WorkspaceError.invalidPath
    }
    return components.joined(separator: "/")
  }
}

public struct ClairV2ProjectRoot: Codable, Equatable, Hashable, Sendable {
  public let id: ProjectID
  public let rootURL: URL

  public init(id: ProjectID, rootURL: URL) throws {
    guard rootURL.isFileURL,
      rootURL.path.hasPrefix("/"),
      !rootURL.path.isEmpty,
      !rootURL.path.contains("\0")
    else {
      throw ClairV2WorkspaceError.invalidProjectRoot
    }
    self.id = id
    self.rootURL = rootURL.standardizedFileURL
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(ProjectID.self, forKey: .id),
      rootURL: container.decode(URL.self, forKey: .rootURL)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case rootURL
  }
}

public enum ClairV2WorkspaceRootState: String, Codable, Equatable, Sendable {
  case available
  case missing
  case permissionDenied = "permission_denied"
  case notDirectory = "not_directory"
  case symlink
  case inaccessible
}

public struct ClairV2ProjectCatalogEntry: Codable, Equatable, Sendable {
  public let id: ProjectID
  public let rootURL: URL
  public let state: ClairV2WorkspaceRootState
  public let repositoryRootURL: URL?
  public let worktrees: [ClairV2WorktreeCatalogEntry]
  public let isTruncated: Bool

  public init(
    id: ProjectID,
    rootURL: URL,
    state: ClairV2WorkspaceRootState,
    repositoryRootURL: URL? = nil,
    worktrees: [ClairV2WorktreeCatalogEntry] = [],
    isTruncated: Bool = false
  ) {
    self.id = id
    self.rootURL = rootURL
    self.state = state
    self.repositoryRootURL = repositoryRootURL
    self.worktrees = worktrees
    self.isTruncated = isTruncated
  }
}

public struct ClairV2WorktreeCatalogEntry: Codable, Equatable, Sendable {
  public let id: WorktreeID
  public let projectID: ProjectID
  public let repositoryRootURL: URL
  public let rootURL: URL
  public let headRevision: String?
  public let branch: String?
  public let state: ClairV2WorkspaceRootState
  public let isMain: Bool
  public let isDetached: Bool
  public let isLocked: Bool
  public let isPrunable: Bool

  public init(
    id: WorktreeID,
    projectID: ProjectID,
    repositoryRootURL: URL,
    rootURL: URL,
    headRevision: String? = nil,
    branch: String? = nil,
    state: ClairV2WorkspaceRootState,
    isMain: Bool = false,
    isDetached: Bool = false,
    isLocked: Bool = false,
    isPrunable: Bool = false
  ) {
    self.id = id
    self.projectID = projectID
    self.repositoryRootURL = repositoryRootURL
    self.rootURL = rootURL
    self.headRevision = headRevision
    self.branch = branch
    self.state = state
    self.isMain = isMain
    self.isDetached = isDetached
    self.isLocked = isLocked
    self.isPrunable = isPrunable
  }
}

public typealias ClairV2ProjectRecord = ClairV2ProjectCatalogEntry
public typealias ClairV2WorktreeRecord = ClairV2WorktreeCatalogEntry

public struct ClairV2WorkspaceCatalog: Codable, Equatable, Sendable {
  public let projects: [ClairV2ProjectCatalogEntry]
  public let isTruncated: Bool

  public init(projects: [ClairV2ProjectCatalogEntry], isTruncated: Bool = false) {
    self.projects = projects
    self.isTruncated = isTruncated
  }
}

public enum ClairV2FileTreeEntryKind: String, Codable, Equatable, Sendable {
  case file
  case directory
  case symlink
  case other
}

public struct ClairV2FileTreeEntry: Codable, Equatable, Sendable {
  public let path: ClairV2WorkspacePath
  public let kind: ClairV2FileTreeEntryKind
  public let byteCount: UInt64?

  public init(
    path: ClairV2WorkspacePath,
    kind: ClairV2FileTreeEntryKind,
    byteCount: UInt64? = nil
  ) {
    self.path = path
    self.kind = kind
    self.byteCount = byteCount
  }
}

public struct ClairV2FileTree: Codable, Equatable, Sendable {
  public let root: ClairV2WorkspacePath
  public let entries: [ClairV2FileTreeEntry]
  public let maximumDepth: Int
  public let maximumEntries: Int
  public let isTruncated: Bool

  public init(
    root: ClairV2WorkspacePath,
    entries: [ClairV2FileTreeEntry],
    maximumDepth: Int,
    maximumEntries: Int,
    isTruncated: Bool
  ) {
    self.root = root
    self.entries = entries
    self.maximumDepth = maximumDepth
    self.maximumEntries = maximumEntries
    self.isTruncated = isTruncated
  }
}

public struct ClairV2FileReadResult: Codable, Equatable, Sendable {
  public let path: ClairV2WorkspacePath
  public let content: String
  public let byteCount: Int
  public let maximumBytes: Int

  public init(
    path: ClairV2WorkspacePath,
    content: String,
    byteCount: Int,
    maximumBytes: Int
  ) {
    self.path = path
    self.content = content
    self.byteCount = byteCount
    self.maximumBytes = maximumBytes
  }
}

public enum ClairV2ChangedFileKind: String, Codable, Equatable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case copied
  case typeChanged = "type_changed"
  case conflicted
  case untracked
}

public struct ClairV2ChangedFile: Codable, Equatable, Sendable {
  public let path: ClairV2WorkspacePath
  public let originalPath: ClairV2WorkspacePath?
  public let kind: ClairV2ChangedFileKind
  public let indexStatus: String
  public let worktreeStatus: String

  public var isStaged: Bool {
    kind != .untracked && indexStatus != "."
  }

  public var isUnstaged: Bool {
    kind == .untracked || worktreeStatus != "."
  }

  public init(
    path: ClairV2WorkspacePath,
    originalPath: ClairV2WorkspacePath? = nil,
    kind: ClairV2ChangedFileKind,
    indexStatus: String,
    worktreeStatus: String
  ) {
    self.path = path
    self.originalPath = originalPath
    self.kind = kind
    self.indexStatus = indexStatus
    self.worktreeStatus = worktreeStatus
  }
}

public struct ClairV2ChangedFileSummary: Codable, Equatable, Sendable {
  public let files: [ClairV2ChangedFile]
  public let isTruncated: Bool
  public let outputBytes: Int
  public let maximumOutputBytes: Int
  public let maximumFiles: Int

  public init(
    files: [ClairV2ChangedFile],
    isTruncated: Bool,
    outputBytes: Int,
    maximumOutputBytes: Int,
    maximumFiles: Int
  ) {
    self.files = files
    self.isTruncated = isTruncated
    self.outputBytes = outputBytes
    self.maximumOutputBytes = maximumOutputBytes
    self.maximumFiles = maximumFiles
  }
}

public enum ClairV2WorkspaceError: Error, Equatable, LocalizedError, Sendable {
  case invalidLimits
  case invalidProjectRoot
  case duplicateProjectID(ProjectID)
  case duplicateProjectRoot(URL)
  case unsupportedPlatform
  case projectNotFound(ProjectID)
  case worktreeNotFound(WorktreeID)
  case projectRootUnavailable(ProjectID, ClairV2WorkspaceRootState)
  case worktreeRootUnavailable(WorktreeID, ClairV2WorkspaceRootState)
  case repositoryNotFound(ProjectID)
  case gitExecutableUnavailable
  case gitCommandFailed(operation: String, status: Int32)
  case gitOutputTooLarge(operation: String, maximumBytes: Int)
  case gitOutputInvalidEncoding(operation: String)
  case gitOutputMalformed(operation: String)
  case invalidPath
  case pathEscapesRoot
  case pathNotFound(ClairV2WorkspacePath)
  case pathIsSymlink(ClairV2WorkspacePath)
  case pathPermissionDenied(ClairV2WorkspacePath)
  case pathNotDirectory(ClairV2WorkspacePath)
  case pathNotRegularFile(ClairV2WorkspacePath)
  case directoryReadFailed(ClairV2WorkspacePath)
  case fileTooLarge(path: ClairV2WorkspacePath, size: UInt64, maximumBytes: Int)
  case binaryFile(ClairV2WorkspacePath)
  case invalidEncoding(ClairV2WorkspacePath)

  public var errorDescription: String? {
    switch self {
    case .invalidLimits:
      "The Clair workspace limits are outside the supported bounds."
    case .invalidProjectRoot:
      "The Clair Project root must be an absolute local filesystem URL."
    case .duplicateProjectID(let id):
      "The Clair Project identity is registered more than once: \(id)."
    case .duplicateProjectRoot(let url):
      "The Clair Project root is registered more than once: \(url.path)."
    case .unsupportedPlatform:
      "The Clair workspace filesystem runtime is available on macOS only."
    case .projectNotFound(let id):
      "The Clair Project identity is not registered: \(id)."
    case .worktreeNotFound(let id):
      "The Clair Worktree identity is not registered: \(id)."
    case .projectRootUnavailable(let id, let state):
      "The Clair Project root \(id) is unavailable (\(state.rawValue))."
    case .worktreeRootUnavailable(let id, let state):
      "The Clair Worktree root \(id) is unavailable (\(state.rawValue))."
    case .repositoryNotFound(let id):
      "The Clair Project is not a Git repository: \(id)."
    case .gitExecutableUnavailable:
      "The Git executable is not available to the Clair workspace runtime."
    case .gitCommandFailed(let operation, let status):
      "Git \(operation) failed with exit status \(status)."
    case .gitOutputTooLarge(let operation, let maximumBytes):
      "Git \(operation) exceeded the \(maximumBytes)-byte output bound."
    case .gitOutputInvalidEncoding(let operation):
      "Git \(operation) returned invalid UTF-8 output."
    case .gitOutputMalformed(let operation):
      "Git \(operation) returned malformed output."
    case .invalidPath:
      "The workspace path is invalid."
    case .pathEscapesRoot:
      "The workspace path escapes its registered root."
    case .pathNotFound(let path):
      "The workspace path does not exist: \(path)."
    case .pathIsSymlink(let path):
      "Symlink traversal is not allowed: \(path)."
    case .pathPermissionDenied(let path):
      "Permission was denied for the workspace path: \(path)."
    case .pathNotDirectory(let path):
      "The workspace path is not a directory: \(path)."
    case .pathNotRegularFile(let path):
      "The workspace path is not a regular file: \(path)."
    case .directoryReadFailed(let path):
      "The workspace directory could not be read: \(path)."
    case .fileTooLarge(let path, let size, let maximumBytes):
      "The workspace file \(path) is \(size) bytes, above the \(maximumBytes)-byte read bound."
    case .binaryFile(let path):
      "The workspace file is binary and is not exposed by the text read API: \(path)."
    case .invalidEncoding(let path):
      "The workspace file is not valid UTF-8: \(path)."
    }
  }
}

/// Read-only access to registered Project roots and their Git Worktrees.
public struct ClairV2WorkspaceRuntime: Sendable {
  public let limits: ClairV2WorkspaceLimits

  private let projectsByID: [ProjectID: ClairV2ProjectRoot]

  public init(
    projects: [ClairV2ProjectRoot],
    limits: ClairV2WorkspaceLimits = .standard
  ) throws {
    var byID: [ProjectID: ClairV2ProjectRoot] = [:]
    var roots: Set<String> = []
    for project in projects {
      guard byID.updateValue(project, forKey: project.id) == nil else {
        throw ClairV2WorkspaceError.duplicateProjectID(project.id)
      }
      guard roots.insert(project.rootURL.path).inserted else {
        throw ClairV2WorkspaceError.duplicateProjectRoot(project.rootURL)
      }
    }
    self.projectsByID = byID
    self.limits = limits
  }

  public var projectRoots: [ClairV2ProjectRoot] {
    projectsByID.values.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  public func catalog() throws -> ClairV2WorkspaceCatalog {
    #if os(macOS)
      return try ClairV2WorkspaceCatalogReader(limits: limits).read(
        projects: projectRoots
      )
    #else
      throw ClairV2WorkspaceError.unsupportedPlatform
    #endif
  }

  public func projectCatalog() throws -> ClairV2WorkspaceCatalog {
    try catalog()
  }

  public func fileTree(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    path: ClairV2WorkspacePath = .root,
    options: ClairV2FileTreeOptions = .standard
  ) throws -> ClairV2FileTree {
    #if os(macOS)
      let root = try resolveRoot(projectID: projectID, worktreeID: worktreeID)
      let effectiveOptions = ClairV2FileTreeOptions(
        uncheckedMaximumDepth: min(options.maximumDepth, limits.maximumTreeDepth),
        uncheckedMaximumEntries: min(options.maximumEntries, limits.maximumTreeEntries)
      )
      return try ClairV2WorkspaceFileSystem.readTree(
        root: root,
        path: path,
        options: effectiveOptions
      )
    #else
      throw ClairV2WorkspaceError.unsupportedPlatform
    #endif
  }

  public func readFile(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    path: ClairV2WorkspacePath,
    maximumBytes: Int? = nil
  ) throws -> ClairV2FileReadResult {
    #if os(macOS)
      let root = try resolveRoot(projectID: projectID, worktreeID: worktreeID)
      let effectiveMaximumBytes = maximumBytes ?? limits.maximumFileReadBytes
      guard effectiveMaximumBytes > 0,
        effectiveMaximumBytes <= limits.maximumFileReadBytes
      else {
        throw ClairV2WorkspaceError.invalidLimits
      }
      return try ClairV2WorkspaceFileSystem.readText(
        root: root,
        path: path,
        maximumBytes: effectiveMaximumBytes
      )
    #else
      throw ClairV2WorkspaceError.unsupportedPlatform
    #endif
  }

  public func changedFileSummary(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil
  ) throws -> ClairV2ChangedFileSummary {
    #if os(macOS)
      let root = try resolveRoot(projectID: projectID, worktreeID: worktreeID)
      return try ClairV2WorkspaceGit.changedFileSummary(
        projectID: projectID,
        root: root,
        limits: limits
      )
    #else
      throw ClairV2WorkspaceError.unsupportedPlatform
    #endif
  }

  public func changedFiles(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil
  ) throws -> ClairV2ChangedFileSummary {
    try changedFileSummary(projectID: projectID, worktreeID: worktreeID)
  }

  #if os(macOS)

    private func resolveRoot(
      projectID: ProjectID,
      worktreeID: WorktreeID?
    ) throws -> ClairV2WorkspaceRootReference {
      guard let project = projectsByID[projectID] else {
        throw ClairV2WorkspaceError.projectNotFound(projectID)
      }
      if let worktreeID {
        let entry = try ClairV2WorkspaceCatalogReader(limits: limits).worktree(
          project: project,
          id: worktreeID
        )
        guard entry.state == .available else {
          throw ClairV2WorkspaceError.worktreeRootUnavailable(worktreeID, entry.state)
        }
        return ClairV2WorkspaceRootReference(
          projectID: projectID,
          worktreeID: worktreeID,
          rootURL: entry.rootURL
        )
      }
      let state = ClairV2WorkspacePOSIX.rootState(at: project.rootURL)
      guard state == .available else {
        throw ClairV2WorkspaceError.projectRootUnavailable(projectID, state)
      }
      return ClairV2WorkspaceRootReference(
        projectID: projectID,
        worktreeID: nil,
        rootURL: project.rootURL
      )
    }

  #endif
}

#if os(macOS)

  private struct ClairV2WorkspaceRootReference: Equatable, Sendable {
    let projectID: ProjectID
    let worktreeID: WorktreeID?
    let rootURL: URL
  }

  private enum ClairV2WorkspacePOSIXFileKind {
    case directory
    case regularFile
    case symlink
    case other
  }

  private struct ClairV2WorkspacePOSIXMetadata {
    let kind: ClairV2WorkspacePOSIXFileKind
    let byteCount: UInt64
  }

  private enum ClairV2WorkspacePOSIXLookupError: Error {
    case errno(Int32)
  }

  private enum ClairV2WorkspacePOSIX {
    static func rootState(at url: URL) -> ClairV2WorkspaceRootState {
      let fileMetadata: ClairV2WorkspacePOSIXMetadata
      do {
        fileMetadata = try metadata(at: url)
      } catch ClairV2WorkspacePOSIXLookupError.errno(let errorNumber) {
        return state(for: errorNumber)
      } catch {
        return .inaccessible
      }

      switch fileMetadata.kind {
      case .symlink:
        return .symlink
      case .regularFile, .other:
        return .notDirectory
      case .directory:
        let descriptor = Darwin.open(
          url.path,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
          return state(for: errno)
        }
        Darwin.close(descriptor)
        return .available
      }
    }

    static func metadata(at url: URL) throws -> ClairV2WorkspacePOSIXMetadata {
      var information = stat()
      guard Darwin.lstat(url.path, &information) == 0 else {
        throw ClairV2WorkspacePOSIXLookupError.errno(errno)
      }

      let fileType = information.st_mode & mode_t(S_IFMT)
      let kind: ClairV2WorkspacePOSIXFileKind
      switch fileType {
      case mode_t(S_IFDIR):
        kind = .directory
      case mode_t(S_IFREG):
        kind = .regularFile
      case mode_t(S_IFLNK):
        kind = .symlink
      default:
        kind = .other
      }
      return ClairV2WorkspacePOSIXMetadata(
        kind: kind,
        byteCount: information.st_size > 0 ? UInt64(information.st_size) : 0
      )
    }

    static func state(for errorNumber: Int32) -> ClairV2WorkspaceRootState {
      switch errorNumber {
      case ENOENT, ENOTDIR:
        .missing
      case EACCES, EPERM:
        .permissionDenied
      case ELOOP:
        .symlink
      default:
        .inaccessible
      }
    }

    static func isPermissionError(_ errorNumber: Int32) -> Bool {
      errorNumber == EACCES || errorNumber == EPERM
    }

    static func isMissingError(_ errorNumber: Int32) -> Bool {
      errorNumber == ENOENT || errorNumber == ENOTDIR
    }
  }

  private enum ClairV2WorkspaceFileSystem {
    static func readTree(
      root: ClairV2WorkspaceRootReference,
      path: ClairV2WorkspacePath,
      options: ClairV2FileTreeOptions
    ) throws -> ClairV2FileTree {
      let directoryURL = try resolve(
        root: root,
        path: path,
        expected: .directory
      )
      var entries: [ClairV2FileTreeEntry] = []
      var isTruncated = false
      try ensureDirectoryCanBeOpened(at: directoryURL, path: path)
      guard
        let enumerator = FileManager.default.enumerator(
          at: directoryURL,
          includingPropertiesForKeys: nil,
          options: []
        )
      else {
        throw ClairV2WorkspaceError.directoryReadFailed(path)
      }

      let canonicalDirectoryURL = directoryURL.resolvingSymlinksInPath()
      let basePrefix =
        canonicalDirectoryURL.path.hasSuffix("/")
        ? canonicalDirectoryURL.path
        : "\(canonicalDirectoryURL.path)/"
      while let object = enumerator.nextObject() {
        guard entries.count < options.maximumEntries else {
          isTruncated = true
          break
        }
        guard let rawChildURL = object as? URL else {
          throw ClairV2WorkspaceError.directoryReadFailed(path)
        }
        let childURL = rawChildURL.standardizedFileURL
        guard childURL.path.hasPrefix(basePrefix)
        else {
          throw ClairV2WorkspaceError.directoryReadFailed(path)
        }
        let suffix = String(childURL.path.dropFirst(basePrefix.count))
        guard !suffix.isEmpty else {
          throw ClairV2WorkspaceError.directoryReadFailed(path)
        }
        let childPath = try ClairV2WorkspacePath(
          path == .root ? suffix : "\(path.rawValue)/\(suffix)"
        )
        let metadata: ClairV2WorkspacePOSIXMetadata
        do {
          metadata = try ClairV2WorkspacePOSIX.metadata(at: childURL)
        } catch ClairV2WorkspacePOSIXLookupError.errno(let errorNumber) {
          if ClairV2WorkspacePOSIX.isMissingError(errorNumber) {
            throw ClairV2WorkspaceError.pathNotFound(childPath)
          }
          if ClairV2WorkspacePOSIX.isPermissionError(errorNumber) {
            throw ClairV2WorkspaceError.pathPermissionDenied(childPath)
          }
          throw ClairV2WorkspaceError.directoryReadFailed(path)
        }

        let kind: ClairV2FileTreeEntryKind
        switch metadata.kind {
        case .directory:
          kind = .directory
        case .regularFile:
          kind = .file
        case .symlink:
          kind = .symlink
        case .other:
          kind = .other
        }
        entries.append(
          ClairV2FileTreeEntry(
            path: childPath,
            kind: kind,
            byteCount: metadata.kind == .regularFile ? metadata.byteCount : nil
          )
        )

        guard metadata.kind == .directory else {
          if metadata.kind == .symlink {
            enumerator.skipDescendants()
          }
          continue
        }
        try ensureDirectoryCanBeOpened(at: childURL, path: childPath)
        let relativeDepth = childPath.components.count - path.components.count
        guard relativeDepth < options.maximumDepth else {
          isTruncated = true
          enumerator.skipDescendants()
          continue
        }
      }
      return ClairV2FileTree(
        root: path,
        entries: entries,
        maximumDepth: options.maximumDepth,
        maximumEntries: options.maximumEntries,
        isTruncated: isTruncated
      )
    }

    static func readText(
      root: ClairV2WorkspaceRootReference,
      path: ClairV2WorkspacePath,
      maximumBytes: Int
    ) throws -> ClairV2FileReadResult {
      _ = try resolve(root: root, path: path, expected: .regularFile)
      let (descriptor, initialByteCount) = try openRegularFile(root: root, path: path)
      defer { Darwin.close(descriptor) }

      guard initialByteCount <= UInt64(maximumBytes) else {
        throw ClairV2WorkspaceError.fileTooLarge(
          path: path,
          size: initialByteCount,
          maximumBytes: maximumBytes
        )
      }

      var data = Data()
      data.reserveCapacity(min(Int(initialByteCount), maximumBytes))
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)

      while true {
        let remaining = maximumBytes - data.count
        let requested = min(buffer.count, max(1, remaining + 1))
        let count = buffer.withUnsafeMutableBytes { bytes -> Int in
          guard let baseAddress = bytes.baseAddress else { return -1 }
          return Darwin.read(descriptor, baseAddress, requested)
        }
        if count > 0 {
          guard data.count + count <= maximumBytes else {
            throw ClairV2WorkspaceError.fileTooLarge(
              path: path,
              size: UInt64(data.count + count),
              maximumBytes: maximumBytes
            )
          }
          data.append(contentsOf: buffer[0..<count])
          continue
        }
        if count == 0 {
          break
        }
        if errno == EINTR {
          continue
        }
        if ClairV2WorkspacePOSIX.isPermissionError(errno) {
          throw ClairV2WorkspaceError.pathPermissionDenied(path)
        }
        if ClairV2WorkspacePOSIX.isMissingError(errno) {
          throw ClairV2WorkspaceError.pathNotFound(path)
        }
        throw ClairV2WorkspaceError.directoryReadFailed(path)
      }

      if data.contains(0) {
        throw ClairV2WorkspaceError.binaryFile(path)
      }
      guard let content = String(data: data, encoding: .utf8) else {
        throw ClairV2WorkspaceError.invalidEncoding(path)
      }
      return ClairV2FileReadResult(
        path: path,
        content: content,
        byteCount: data.count,
        maximumBytes: maximumBytes
      )
    }

    private static func resolve(
      root: ClairV2WorkspaceRootReference,
      path: ClairV2WorkspacePath,
      expected: ClairV2WorkspacePOSIXFileKind
    ) throws -> URL {
      let rootState = ClairV2WorkspacePOSIX.rootState(at: root.rootURL)
      guard rootState == .available else {
        if let worktreeID = root.worktreeID {
          throw ClairV2WorkspaceError.worktreeRootUnavailable(worktreeID, rootState)
        }
        throw ClairV2WorkspaceError.projectRootUnavailable(root.projectID, rootState)
      }

      var currentURL = root.rootURL
      var currentPath = ""
      for component in path.components {
        currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
        currentURL.appendPathComponent(component, isDirectory: false)
        let metadata: ClairV2WorkspacePOSIXMetadata
        do {
          metadata = try ClairV2WorkspacePOSIX.metadata(at: currentURL)
        } catch ClairV2WorkspacePOSIXLookupError.errno(let errorNumber) {
          guard let partialPath = try? ClairV2WorkspacePath(currentPath) else {
            throw ClairV2WorkspaceError.invalidPath
          }
          if ClairV2WorkspacePOSIX.isMissingError(errorNumber) {
            throw ClairV2WorkspaceError.pathNotFound(partialPath)
          }
          if ClairV2WorkspacePOSIX.isPermissionError(errorNumber) {
            throw ClairV2WorkspaceError.pathPermissionDenied(partialPath)
          }
          throw ClairV2WorkspaceError.directoryReadFailed(partialPath)
        }
        guard metadata.kind != .symlink else {
          guard let partialPath = try? ClairV2WorkspacePath(currentPath) else {
            throw ClairV2WorkspaceError.invalidPath
          }
          throw ClairV2WorkspaceError.pathIsSymlink(partialPath)
        }
        if component != path.components.last, metadata.kind != .directory {
          throw ClairV2WorkspaceError.pathNotDirectory(path)
        }
      }

      let metadata: ClairV2WorkspacePOSIXMetadata
      do {
        metadata = try ClairV2WorkspacePOSIX.metadata(at: currentURL)
      } catch ClairV2WorkspacePOSIXLookupError.errno(let errorNumber) {
        if ClairV2WorkspacePOSIX.isMissingError(errorNumber) {
          throw ClairV2WorkspaceError.pathNotFound(path)
        }
        if ClairV2WorkspacePOSIX.isPermissionError(errorNumber) {
          throw ClairV2WorkspaceError.pathPermissionDenied(path)
        }
        throw ClairV2WorkspaceError.directoryReadFailed(path)
      }
      guard metadata.kind == expected else {
        switch expected {
        case .directory:
          throw ClairV2WorkspaceError.pathNotDirectory(path)
        case .regularFile:
          throw ClairV2WorkspaceError.pathNotRegularFile(path)
        default:
          throw ClairV2WorkspaceError.invalidPath
        }
      }
      return currentURL
    }

    private static func ensureDirectoryCanBeOpened(
      at url: URL,
      path: ClairV2WorkspacePath
    ) throws {
      let descriptor = Darwin.open(
        url.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        if ClairV2WorkspacePOSIX.isPermissionError(errno) {
          throw ClairV2WorkspaceError.pathPermissionDenied(path)
        }
        if ClairV2WorkspacePOSIX.isMissingError(errno) {
          throw ClairV2WorkspaceError.pathNotFound(path)
        }
        if errno == ELOOP {
          throw ClairV2WorkspaceError.pathIsSymlink(path)
        }
        throw ClairV2WorkspaceError.directoryReadFailed(path)
      }
      Darwin.close(descriptor)
    }

    private static func openRegularFile(
      root: ClairV2WorkspaceRootReference,
      path: ClairV2WorkspacePath
    ) throws -> (descriptor: Int32, byteCount: UInt64) {
      let rootDescriptor = Darwin.open(
        root.rootURL.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard rootDescriptor >= 0 else {
        let state = ClairV2WorkspacePOSIX.rootState(at: root.rootURL)
        if let worktreeID = root.worktreeID {
          throw ClairV2WorkspaceError.worktreeRootUnavailable(worktreeID, state)
        }
        throw ClairV2WorkspaceError.projectRootUnavailable(root.projectID, state)
      }

      var directoryDescriptor = rootDescriptor
      var currentPath = ""
      let components = path.components
      guard let fileName = components.last else {
        Darwin.close(rootDescriptor)
        throw ClairV2WorkspaceError.pathNotRegularFile(path)
      }

      for component in components.dropLast() {
        currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
        let nextDescriptor = Darwin.openat(
          directoryDescriptor,
          component,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard nextDescriptor >= 0 else {
          let errorNumber = errno
          Darwin.close(directoryDescriptor)
          guard let partialPath = try? ClairV2WorkspacePath(currentPath) else {
            throw ClairV2WorkspaceError.invalidPath
          }
          if errorNumber == ELOOP {
            throw ClairV2WorkspaceError.pathIsSymlink(partialPath)
          }
          if ClairV2WorkspacePOSIX.isPermissionError(errorNumber) {
            throw ClairV2WorkspaceError.pathPermissionDenied(partialPath)
          }
          if ClairV2WorkspacePOSIX.isMissingError(errorNumber) {
            throw ClairV2WorkspaceError.pathNotFound(partialPath)
          }
          throw ClairV2WorkspaceError.pathNotDirectory(partialPath)
        }
        if directoryDescriptor != rootDescriptor {
          Darwin.close(directoryDescriptor)
        }
        directoryDescriptor = nextDescriptor
      }

      let fileDescriptor = Darwin.openat(
        directoryDescriptor,
        fileName,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      )
      if directoryDescriptor != rootDescriptor {
        Darwin.close(directoryDescriptor)
      }
      guard fileDescriptor >= 0 else {
        Darwin.close(rootDescriptor)
        let errorNumber = errno
        if errorNumber == ELOOP {
          throw ClairV2WorkspaceError.pathIsSymlink(path)
        }
        if ClairV2WorkspacePOSIX.isPermissionError(errorNumber) {
          throw ClairV2WorkspaceError.pathPermissionDenied(path)
        }
        if ClairV2WorkspacePOSIX.isMissingError(errorNumber) {
          throw ClairV2WorkspaceError.pathNotFound(path)
        }
        throw ClairV2WorkspaceError.pathNotRegularFile(path)
      }
      Darwin.close(rootDescriptor)

      var information = stat()
      guard Darwin.fstat(fileDescriptor, &information) == 0 else {
        Darwin.close(fileDescriptor)
        throw ClairV2WorkspaceError.pathNotRegularFile(path)
      }
      guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        Darwin.close(fileDescriptor)
        throw ClairV2WorkspaceError.pathNotRegularFile(path)
      }
      return (fileDescriptor, information.st_size > 0 ? UInt64(information.st_size) : 0)
    }
  }

  private struct ClairV2GitCommandOutput {
    let data: Data
    let isTruncated: Bool
  }

  private enum ClairV2GitCommandError: Error {
    case executableUnavailable
    case failed(operation: String, status: Int32)
  }

  private struct ClairV2GitWorktree {
    let rootURL: URL
    let headRevision: String?
    let branch: String?
    let isDetached: Bool
    let isLocked: Bool
    let isPrunable: Bool
  }

  private enum ClairV2WorkspaceGit {
    static func repositoryRoot(at rootURL: URL, limits: ClairV2WorkspaceLimits) throws -> URL? {
      do {
        let output = try run(
          ["rev-parse", "--show-toplevel"],
          at: rootURL,
          operation: "find repository root",
          maximumOutputBytes: limits.maximumGitOutputBytes
        )
        guard !output.isTruncated else {
          throw ClairV2WorkspaceError.gitOutputTooLarge(
            operation: "find repository root",
            maximumBytes: limits.maximumGitOutputBytes
          )
        }
        guard let text = String(data: output.data, encoding: .utf8) else {
          throw ClairV2WorkspaceError.gitOutputInvalidEncoding(
            operation: "find repository root"
          )
        }
        let lines = text.split(whereSeparator: { $0 == "\n" })
        guard lines.count == 1 else {
          throw ClairV2WorkspaceError.gitOutputMalformed(operation: "find repository root")
        }
        let path = String(lines[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
          throw ClairV2WorkspaceError.gitOutputMalformed(operation: "find repository root")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
      } catch ClairV2GitCommandError.failed(_, let status) where status == 128 {
        return nil
      } catch ClairV2GitCommandError.executableUnavailable {
        throw ClairV2WorkspaceError.gitExecutableUnavailable
      } catch ClairV2GitCommandError.failed(let operation, let status) {
        throw ClairV2WorkspaceError.gitCommandFailed(operation: operation, status: status)
      }
    }

    static func worktrees(
      repositoryRoot: URL,
      projectID: ProjectID,
      limits: ClairV2WorkspaceLimits
    ) throws -> (entries: [ClairV2WorktreeCatalogEntry], isTruncated: Bool) {
      let operation = "list worktrees"
      let output: ClairV2GitCommandOutput
      do {
        output = try run(
          ["worktree", "list", "--porcelain", "-z"],
          at: repositoryRoot,
          operation: operation,
          maximumOutputBytes: limits.maximumGitOutputBytes
        )
      } catch ClairV2GitCommandError.executableUnavailable {
        throw ClairV2WorkspaceError.gitExecutableUnavailable
      } catch ClairV2GitCommandError.failed(let operation, let status) {
        throw ClairV2WorkspaceError.gitCommandFailed(operation: operation, status: status)
      }

      let parsed = try parseWorktrees(output.data, isTruncated: output.isTruncated)
      var paths = Set<String>()
      var worktreeIDs = Set<WorktreeID>()
      var entries: [ClairV2WorktreeCatalogEntry] = []
      for worktree in parsed {
        guard paths.insert(canonicalPath(worktree.rootURL)).inserted else {
          throw ClairV2WorkspaceError.gitOutputMalformed(operation: operation)
        }
        let worktreeID = try makeWorktreeID(
          projectID: projectID,
          repositoryRoot: repositoryRoot,
          rootURL: worktree.rootURL
        )
        guard worktreeIDs.insert(worktreeID).inserted else {
          throw ClairV2WorkspaceError.gitOutputMalformed(operation: operation)
        }
        entries.append(
          ClairV2WorktreeCatalogEntry(
            id: worktreeID,
            projectID: projectID,
            repositoryRootURL: repositoryRoot,
            rootURL: worktree.rootURL,
            headRevision: worktree.headRevision,
            branch: worktree.branch,
            state: ClairV2WorkspacePOSIX.rootState(at: worktree.rootURL),
            isMain: canonicalPath(worktree.rootURL) == canonicalPath(repositoryRoot),
            isDetached: worktree.isDetached,
            isLocked: worktree.isLocked,
            isPrunable: worktree.isPrunable
          )
        )
      }
      return (
        entries.sorted { $0.rootURL.path < $1.rootURL.path },
        output.isTruncated
      )
    }

    private static func canonicalPath(_ url: URL) -> String {
      url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func changedFileSummary(
      projectID: ProjectID,
      root: ClairV2WorkspaceRootReference,
      limits: ClairV2WorkspaceLimits
    ) throws -> ClairV2ChangedFileSummary {
      guard try repositoryRoot(at: root.rootURL, limits: limits) != nil else {
        throw ClairV2WorkspaceError.repositoryNotFound(projectID)
      }
      let operation = "summarize changed files"
      let output: ClairV2GitCommandOutput
      do {
        output = try run(
          ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
          at: root.rootURL,
          operation: operation,
          maximumOutputBytes: limits.maximumChangedOutputBytes
        )
      } catch ClairV2GitCommandError.executableUnavailable {
        throw ClairV2WorkspaceError.gitExecutableUnavailable
      } catch ClairV2GitCommandError.failed(let operation, let status) {
        throw ClairV2WorkspaceError.gitCommandFailed(operation: operation, status: status)
      }

      let parsed = try parseChanges(
        output.data,
        isTruncated: output.isTruncated,
        maximumFiles: limits.maximumChangedFiles
      )
      return ClairV2ChangedFileSummary(
        files: parsed.files.sorted { $0.path.rawValue < $1.path.rawValue },
        isTruncated: output.isTruncated || parsed.isTruncated,
        outputBytes: output.data.count,
        maximumOutputBytes: limits.maximumChangedOutputBytes,
        maximumFiles: limits.maximumChangedFiles
      )
    }

    private static func run(
      _ arguments: [String],
      at rootURL: URL,
      operation: String,
      maximumOutputBytes: Int
    ) throws -> ClairV2GitCommandOutput {
      let executableCandidates = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
      ]
      guard
        let executablePath = executableCandidates.first(where: {
          FileManager.default.isExecutableFile(atPath: $0)
        })
      else {
        throw ClairV2GitCommandError.executableUnavailable
      }

      let process = Process()
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = arguments
      process.currentDirectoryURL = rootURL
      var environment = ProcessInfo.processInfo.environment
      environment["GIT_OPTIONAL_LOCKS"] = "0"
      environment["LC_ALL"] = "C"
      process.environment = environment
      let outputPipe = Pipe()
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = outputPipe
      process.standardError = FileHandle.nullDevice

      do {
        try process.run()
      } catch {
        throw ClairV2GitCommandError.executableUnavailable
      }

      var data = Data()
      var isTruncated = false
      let reader = outputPipe.fileHandleForReading
      while true {
        let remaining = maximumOutputBytes - data.count
        let requested = min(16 * 1024, max(1, remaining + 1))
        let chunk = reader.readData(ofLength: requested)
        if chunk.isEmpty {
          break
        }
        if chunk.count > remaining {
          data.append(contentsOf: chunk.prefix(max(0, remaining)))
          isTruncated = true
          process.terminate()
          break
        }
        data.append(chunk)
      }
      process.waitUntilExit()

      guard isTruncated || process.terminationStatus == 0 else {
        throw ClairV2GitCommandError.failed(
          operation: operation,
          status: process.terminationStatus
        )
      }
      return ClairV2GitCommandOutput(data: data, isTruncated: isTruncated)
    }

    private static func parseWorktrees(
      _ data: Data,
      isTruncated: Bool
    ) throws -> [ClairV2GitWorktree] {
      guard let text = String(data: data, encoding: .utf8) else {
        throw ClairV2WorkspaceError.gitOutputInvalidEncoding(operation: "list worktrees")
      }

      var records: [[String]] = []
      var fields: [String] = []
      for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
        let value = String(field)
        if value.isEmpty {
          if !fields.isEmpty {
            records.append(fields)
            fields = []
          }
        } else {
          fields.append(value)
        }
      }
      if !fields.isEmpty {
        if !isTruncated {
          throw ClairV2WorkspaceError.gitOutputMalformed(operation: "list worktrees")
        }
        fields = []
      }

      var worktrees: [ClairV2GitWorktree] = []
      for fields in records {
        guard let worktreeField = fields.first, worktreeField.hasPrefix("worktree ") else {
          throw ClairV2WorkspaceError.gitOutputMalformed(operation: "list worktrees")
        }
        let path = String(worktreeField.dropFirst("worktree ".count))
        guard path.hasPrefix("/") else {
          throw ClairV2WorkspaceError.gitOutputMalformed(operation: "list worktrees")
        }

        var headRevision: String?
        var branch: String?
        var isDetached = false
        var isLocked = false
        var isPrunable = false
        for field in fields.dropFirst() {
          if field.hasPrefix("HEAD ") {
            headRevision = String(field.dropFirst("HEAD ".count))
          } else if field.hasPrefix("branch ") {
            let value = String(field.dropFirst("branch ".count))
            branch =
              value.hasPrefix("refs/heads/")
              ? String(value.dropFirst("refs/heads/".count))
              : value
          } else if field == "detached" {
            isDetached = true
          } else if field.hasPrefix("locked") {
            isLocked = true
          } else if field.hasPrefix("prunable") {
            isPrunable = true
          }
        }
        worktrees.append(
          ClairV2GitWorktree(
            rootURL: URL(fileURLWithPath: path).standardizedFileURL,
            headRevision: headRevision,
            branch: branch,
            isDetached: isDetached || branch == nil,
            isLocked: isLocked,
            isPrunable: isPrunable
          )
        )
      }
      guard !worktrees.isEmpty || isTruncated else {
        throw ClairV2WorkspaceError.gitOutputMalformed(operation: "list worktrees")
      }
      return worktrees
    }

    private static func parseChanges(
      _ data: Data,
      isTruncated: Bool,
      maximumFiles: Int
    ) throws -> (files: [ClairV2ChangedFile], isTruncated: Bool) {
      let bytes = Array(data)
      let tokens = bytes.split(separator: 0, omittingEmptySubsequences: true)
      var files: [ClairV2ChangedFile] = []
      var index = 0
      var parserTruncated = isTruncated && data.last != 0

      while index < tokens.count {
        let token = Data(tokens[index])
        guard let header = String(data: token, encoding: .utf8) else {
          throw ClairV2WorkspaceError.gitOutputInvalidEncoding(
            operation: "summarize changed files"
          )
        }
        let headerCharacters = Array(header)
        guard headerCharacters.count >= 4,
          headerCharacters[2] == " "
        else {
          if isTruncated {
            parserTruncated = true
            break
          }
          throw ClairV2WorkspaceError.gitOutputMalformed(
            operation: "summarize changed files"
          )
        }

        let indexStatus = String(headerCharacters[0])
        let worktreeStatus = String(headerCharacters[1])
        let pathString = String(header.dropFirst(3))
        guard let path = try? ClairV2WorkspacePath(pathString) else {
          throw ClairV2WorkspaceError.gitOutputMalformed(
            operation: "summarize changed files"
          )
        }

        var originalPath: ClairV2WorkspacePath?
        let hasOriginalPath =
          indexStatus == "R" || indexStatus == "C"
          || worktreeStatus == "R" || worktreeStatus == "C"
        if hasOriginalPath {
          guard index + 1 < tokens.count else {
            parserTruncated = true
            break
          }
          let originalData = Data(tokens[index + 1])
          guard let originalString = String(data: originalData, encoding: .utf8),
            let typedOriginalPath = try? ClairV2WorkspacePath(originalString)
          else {
            throw ClairV2WorkspaceError.gitOutputMalformed(
              operation: "summarize changed files"
            )
          }
          originalPath = typedOriginalPath
          index += 2
        } else {
          index += 1
        }

        let kind = changeKind(indexStatus: indexStatus, worktreeStatus: worktreeStatus)
        if files.count < maximumFiles {
          files.append(
            ClairV2ChangedFile(
              path: path,
              originalPath: originalPath,
              kind: kind,
              indexStatus: indexStatus,
              worktreeStatus: worktreeStatus
            )
          )
        } else {
          parserTruncated = true
        }
      }
      return (files, parserTruncated)
    }

    private static func changeKind(
      indexStatus: String,
      worktreeStatus: String
    ) -> ClairV2ChangedFileKind {
      if indexStatus == "?" && worktreeStatus == "?" {
        return .untracked
      }
      if indexStatus == "U" || worktreeStatus == "U" {
        return .conflicted
      }
      if indexStatus == "R" || worktreeStatus == "R" {
        return .renamed
      }
      if indexStatus == "C" || worktreeStatus == "C" {
        return .copied
      }
      if indexStatus == "T" || worktreeStatus == "T" {
        return .typeChanged
      }
      if indexStatus == "A" || worktreeStatus == "A" {
        return .added
      }
      if indexStatus == "D" || worktreeStatus == "D" {
        return .deleted
      }
      return .modified
    }

    private static func makeWorktreeID(
      projectID: ProjectID,
      repositoryRoot: URL,
      rootURL: URL
    ) throws -> WorktreeID {
      var hash: UInt64 = 14_695_981_039_346_656_037
      let identity = "\(projectID.rawValue)\0\(repositoryRoot.path)\0\(rootURL.path)"
      for byte in identity.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      do {
        return try WorktreeID("worktree-\(String(format: "%016llx", hash))")
      } catch {
        throw ClairV2WorkspaceError.gitOutputMalformed(operation: "list worktrees")
      }
    }
  }

  private struct ClairV2WorkspaceCatalogReader {
    let limits: ClairV2WorkspaceLimits

    func read(projects: [ClairV2ProjectRoot]) throws -> ClairV2WorkspaceCatalog {
      let entries = try projects.map(read)
      return ClairV2WorkspaceCatalog(
        projects: entries.sorted { $0.id.rawValue < $1.id.rawValue },
        isTruncated: entries.contains(where: \.isTruncated)
      )
    }

    func worktree(
      project: ClairV2ProjectRoot,
      id: WorktreeID
    ) throws -> ClairV2WorktreeCatalogEntry {
      let entry = try read(project: project)
      guard let worktree = entry.worktrees.first(where: { $0.id == id }) else {
        throw ClairV2WorkspaceError.worktreeNotFound(id)
      }
      return worktree
    }

    private func read(project: ClairV2ProjectRoot) throws -> ClairV2ProjectCatalogEntry {
      let state = ClairV2WorkspacePOSIX.rootState(at: project.rootURL)
      guard state == .available else {
        return ClairV2ProjectCatalogEntry(
          id: project.id,
          rootURL: project.rootURL,
          state: state
        )
      }

      guard
        let repositoryRoot = try ClairV2WorkspaceGit.repositoryRoot(
          at: project.rootURL,
          limits: limits
        )
      else {
        return ClairV2ProjectCatalogEntry(
          id: project.id,
          rootURL: project.rootURL,
          state: state
        )
      }
      let repositoryState = ClairV2WorkspacePOSIX.rootState(at: repositoryRoot)
      guard repositoryState == .available else {
        return ClairV2ProjectCatalogEntry(
          id: project.id,
          rootURL: project.rootURL,
          state: repositoryState,
          repositoryRootURL: repositoryRoot
        )
      }
      let worktreeResult = try ClairV2WorkspaceGit.worktrees(
        repositoryRoot: repositoryRoot,
        projectID: project.id,
        limits: limits
      )
      return ClairV2ProjectCatalogEntry(
        id: project.id,
        rootURL: project.rootURL,
        state: state,
        repositoryRootURL: repositoryRoot,
        worktrees: worktreeResult.entries,
        isTruncated: worktreeResult.isTruncated
      )
    }
  }

#endif

import ClairShared
import Foundation

#if os(macOS)
  import Darwin
#endif

public struct ClairWorkspaceLimits: Codable, Equatable, Sendable {
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
      throw ClairWorkspaceError.invalidLimits
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

public struct ClairFileTreeOptions: Codable, Equatable, Sendable {
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
      maximumDepth <= ClairWorkspaceLimits.hardMaximumTreeDepth,
      maximumEntries > 0,
      maximumEntries <= ClairWorkspaceLimits.hardMaximumTreeEntries
    else {
      throw ClairWorkspaceError.invalidLimits
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
public struct ClairWorkspacePath: RawRepresentable, Codable, Hashable, Sendable,
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
        throw ClairWorkspaceError.pathEscapesRoot
      }
      throw ClairWorkspaceError.invalidPath
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
        throw ClairWorkspaceError.pathEscapesRoot
      }
      throw ClairWorkspaceError.invalidPath
    }
    return components.joined(separator: "/")
  }
}

public struct ClairProjectRoot: Codable, Equatable, Hashable, Sendable {
  public let id: ProjectID
  public let rootURL: URL

  public init(id: ProjectID, rootURL: URL) throws {
    guard rootURL.isFileURL,
      rootURL.path.hasPrefix("/"),
      !rootURL.path.isEmpty,
      !rootURL.path.contains("\0")
    else {
      throw ClairWorkspaceError.invalidProjectRoot
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

public enum ClairWorkspaceRootState: String, Codable, Equatable, Sendable {
  case available
  case missing
  case permissionDenied = "permission_denied"
  case notDirectory = "not_directory"
  case symlink
  case inaccessible
}

public final class ClairWorkspaceRootCapability: @unchecked Sendable {
  public let rootURL: URL
  public let device: UInt64
  public let inode: UInt64

  #if os(macOS)
    private let descriptor: Int32

    fileprivate init(rootURL: URL, descriptor: Int32, device: UInt64, inode: UInt64) {
      self.rootURL = rootURL
      self.descriptor = descriptor
      self.device = device
      self.inode = inode
    }

    public func duplicateDescriptor() throws -> Int32 {
      let duplicatedDescriptor = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
      guard duplicatedDescriptor >= 0 else {
        throw ClairWorkspaceError.rootCapabilityUnavailable(rootURL)
      }
      return duplicatedDescriptor
    }

    deinit {
      Darwin.close(descriptor)
    }
  #else
    fileprivate init(rootURL: URL, device: UInt64, inode: UInt64) {
      self.rootURL = rootURL
      self.device = device
      self.inode = inode
    }

    public func duplicateDescriptor() throws -> Int32 {
      throw ClairWorkspaceError.unsupportedPlatform
    }
  #endif
}

public struct ClairProjectCatalogEntry: Codable, Equatable, Sendable {
  public let id: ProjectID
  public let rootURL: URL
  public let state: ClairWorkspaceRootState
  public let rootDevice: UInt64?
  public let rootInode: UInt64?
  public let repositoryRootURL: URL?
  public let worktrees: [ClairWorktreeCatalogEntry]
  public let isTruncated: Bool

  public init(
    id: ProjectID,
    rootURL: URL,
    state: ClairWorkspaceRootState,
    rootDevice: UInt64? = nil,
    rootInode: UInt64? = nil,
    repositoryRootURL: URL? = nil,
    worktrees: [ClairWorktreeCatalogEntry] = [],
    isTruncated: Bool = false
  ) {
    self.id = id
    self.rootURL = rootURL
    self.state = state
    self.rootDevice = rootDevice
    self.rootInode = rootInode
    self.repositoryRootURL = repositoryRootURL
    self.worktrees = worktrees
    self.isTruncated = isTruncated
  }
}

public struct ClairWorktreeCatalogEntry: Codable, Equatable, Sendable {
  public let id: WorktreeID
  public let projectID: ProjectID
  public let repositoryRootURL: URL
  public let rootURL: URL
  public let rootDevice: UInt64?
  public let rootInode: UInt64?
  public let headRevision: String?
  public let branch: String?
  public let state: ClairWorkspaceRootState
  public let isMain: Bool
  public let isDetached: Bool
  public let isLocked: Bool
  public let isPrunable: Bool

  public init(
    id: WorktreeID,
    projectID: ProjectID,
    repositoryRootURL: URL,
    rootURL: URL,
    rootDevice: UInt64? = nil,
    rootInode: UInt64? = nil,
    headRevision: String? = nil,
    branch: String? = nil,
    state: ClairWorkspaceRootState,
    isMain: Bool = false,
    isDetached: Bool = false,
    isLocked: Bool = false,
    isPrunable: Bool = false
  ) {
    self.id = id
    self.projectID = projectID
    self.repositoryRootURL = repositoryRootURL
    self.rootURL = rootURL
    self.rootDevice = rootDevice
    self.rootInode = rootInode
    self.headRevision = headRevision
    self.branch = branch
    self.state = state
    self.isMain = isMain
    self.isDetached = isDetached
    self.isLocked = isLocked
    self.isPrunable = isPrunable
  }
}

public typealias ClairProjectRecord = ClairProjectCatalogEntry
public typealias ClairWorktreeRecord = ClairWorktreeCatalogEntry

public struct ClairWorkspaceCatalog: Codable, Equatable, Sendable {
  public let projects: [ClairProjectCatalogEntry]
  public let isTruncated: Bool

  public init(projects: [ClairProjectCatalogEntry], isTruncated: Bool = false) {
    self.projects = projects
    self.isTruncated = isTruncated
  }
}

public enum ClairFileTreeEntryKind: String, Codable, Equatable, Sendable {
  case file
  case directory
  case symlink
  case other
}

public struct ClairFileTreeEntry: Codable, Equatable, Sendable {
  public let path: ClairWorkspacePath
  public let kind: ClairFileTreeEntryKind
  public let byteCount: UInt64?

  public init(
    path: ClairWorkspacePath,
    kind: ClairFileTreeEntryKind,
    byteCount: UInt64? = nil
  ) {
    self.path = path
    self.kind = kind
    self.byteCount = byteCount
  }
}

public struct ClairFileTree: Codable, Equatable, Sendable {
  public let root: ClairWorkspacePath
  public let entries: [ClairFileTreeEntry]
  public let maximumDepth: Int
  public let maximumEntries: Int
  public let isTruncated: Bool

  public init(
    root: ClairWorkspacePath,
    entries: [ClairFileTreeEntry],
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

public struct ClairFileReadResult: Codable, Equatable, Sendable {
  public let path: ClairWorkspacePath
  public let content: String
  public let byteCount: Int
  public let maximumBytes: Int

  public init(
    path: ClairWorkspacePath,
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

public enum ClairChangedFileKind: String, Codable, Equatable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case copied
  case typeChanged = "type_changed"
  case conflicted
  case untracked
}

public struct ClairChangedFile: Codable, Equatable, Sendable {
  public let path: ClairWorkspacePath
  public let originalPath: ClairWorkspacePath?
  public let kind: ClairChangedFileKind
  public let indexStatus: String
  public let worktreeStatus: String

  public var isStaged: Bool {
    kind != .untracked && indexStatus != "."
  }

  public var isUnstaged: Bool {
    kind == .untracked || worktreeStatus != "."
  }

  public init(
    path: ClairWorkspacePath,
    originalPath: ClairWorkspacePath? = nil,
    kind: ClairChangedFileKind,
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

public struct ClairChangedFileSummary: Codable, Equatable, Sendable {
  public let files: [ClairChangedFile]
  public let isTruncated: Bool
  public let outputBytes: Int
  public let maximumOutputBytes: Int
  public let maximumFiles: Int

  public init(
    files: [ClairChangedFile],
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

public enum ClairGitDiffBasis: String, Codable, Equatable, Sendable {
  case workingTree = "working_tree"
  case staged
}

public enum ClairGitDiffKind: String, Codable, Equatable, Sendable {
  case text
  case binary
}

public struct ClairGitDiffHunk: Codable, Equatable, Sendable {
  public let id: String
  public let header: String
  public let oldStart: Int
  public let oldCount: Int
  public let newStart: Int
  public let newCount: Int

  public init(
    id: String,
    header: String,
    oldStart: Int,
    oldCount: Int,
    newStart: Int,
    newCount: Int
  ) {
    self.id = id
    self.header = header
    self.oldStart = oldStart
    self.oldCount = oldCount
    self.newStart = newStart
    self.newCount = newCount
  }
}

public struct ClairGitDiff: Codable, Equatable, Sendable {
  public let path: ClairWorkspacePath
  public let originalPath: ClairWorkspacePath?
  public let basis: ClairGitDiffBasis
  public let kind: ClairGitDiffKind
  public let text: String?
  public let hunks: [ClairGitDiffHunk]
  public let isTruncated: Bool
  public let outputBytes: Int
  public let maximumOutputBytes: Int

  public init(
    path: ClairWorkspacePath,
    originalPath: ClairWorkspacePath? = nil,
    basis: ClairGitDiffBasis,
    kind: ClairGitDiffKind,
    text: String?,
    hunks: [ClairGitDiffHunk],
    isTruncated: Bool,
    outputBytes: Int,
    maximumOutputBytes: Int
  ) {
    self.path = path
    self.originalPath = originalPath
    self.basis = basis
    self.kind = kind
    self.text = text
    self.hunks = hunks
    self.isTruncated = isTruncated
    self.outputBytes = outputBytes
    self.maximumOutputBytes = maximumOutputBytes
  }
}

public enum ClairWorkspaceError: Error, Equatable, LocalizedError, Sendable {
  case invalidLimits
  case invalidProjectRoot
  case duplicateProjectID(ProjectID)
  case duplicateProjectRoot(URL)
  case unsupportedPlatform
  case projectNotFound(ProjectID)
  case worktreeNotFound(WorktreeID)
  case projectRootUnavailable(ProjectID, ClairWorkspaceRootState)
  case worktreeRootUnavailable(WorktreeID, ClairWorkspaceRootState)
  case rootIdentityChanged(URL)
  case rootCapabilityUnavailable(URL)
  case repositoryNotFound(ProjectID)
  case gitExecutableUnavailable
  case gitCommandFailed(operation: String, status: Int32)
  case gitOutputTooLarge(operation: String, maximumBytes: Int)
  case gitOutputInvalidEncoding(operation: String)
  case gitOutputMalformed(operation: String)
  case gitPathNotChanged(ClairWorkspacePath)
  case invalidPath
  case pathEscapesRoot
  case pathNotFound(ClairWorkspacePath)
  case pathIsSymlink(ClairWorkspacePath)
  case pathPermissionDenied(ClairWorkspacePath)
  case pathNotDirectory(ClairWorkspacePath)
  case pathNotRegularFile(ClairWorkspacePath)
  case directoryReadFailed(ClairWorkspacePath)
  case fileTooLarge(path: ClairWorkspacePath, size: UInt64, maximumBytes: Int)
  case binaryFile(ClairWorkspacePath)
  case invalidEncoding(ClairWorkspacePath)

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
    case .rootIdentityChanged(let url):
      "The Clair workspace root changed while its launch capability was being acquired: \(url.path)."
    case .rootCapabilityUnavailable(let url):
      "The Clair workspace root capability could not be acquired: \(url.path)."
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
    case .gitPathNotChanged(let path):
      "The workspace path has no Git change to display: \(path)."
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
public struct ClairWorkspaceRuntime: Sendable {
  public let limits: ClairWorkspaceLimits

  private let projectsByID: [ProjectID: ClairProjectRoot]

  public init(
    projects: [ClairProjectRoot],
    limits: ClairWorkspaceLimits = .standard
  ) throws {
    var byID: [ProjectID: ClairProjectRoot] = [:]
    var roots: Set<String> = []
    for project in projects {
      guard byID.updateValue(project, forKey: project.id) == nil else {
        throw ClairWorkspaceError.duplicateProjectID(project.id)
      }
      guard roots.insert(project.rootURL.path).inserted else {
        throw ClairWorkspaceError.duplicateProjectRoot(project.rootURL)
      }
    }
    self.projectsByID = byID
    self.limits = limits
  }

  public var projectRoots: [ClairProjectRoot] {
    projectsByID.values.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  public func catalog() throws -> ClairWorkspaceCatalog {
    #if os(macOS)
      return try ClairWorkspaceCatalogReader(limits: limits).read(
        projects: projectRoots
      )
    #else
      throw ClairWorkspaceError.unsupportedPlatform
    #endif
  }

  public func projectCatalog() throws -> ClairWorkspaceCatalog {
    try catalog()
  }

  /// Resolves a launch root from one catalog snapshot and retains a stable
  /// descriptor plus device/inode identity for consumers that create a
  /// process. The snapshot overload lets callers keep the catalog selection
  /// and capability acquisition in one H02 boundary without reopening an
  /// untrusted path by name.
  public func launchRootCapability(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil
  ) throws -> ClairWorkspaceRootCapability {
    #if os(macOS)
      return try launchRootCapability(
        from: catalog(),
        projectID: projectID,
        worktreeID: worktreeID
      )
    #else
      throw ClairWorkspaceError.unsupportedPlatform
    #endif
  }

  public func launchRootCapability(
    from catalog: ClairWorkspaceCatalog,
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil
  ) throws -> ClairWorkspaceRootCapability {
    #if os(macOS)
      guard let registeredProject = projectsByID[projectID] else {
        throw ClairWorkspaceError.projectNotFound(projectID)
      }
      guard let suppliedProject = catalog.projects.first(where: { $0.id == projectID }) else {
        throw ClairWorkspaceError.projectNotFound(projectID)
      }

      // A catalog is a caller-visible snapshot, not an authority. Re-read the
      // registered scope and compare the selected root identity before using
      // any URL or device/inode values supplied by that snapshot.
      let authoritativeCatalog = try self.catalog()
      guard
        let authoritativeProject = authoritativeCatalog.projects.first(where: {
          $0.id == projectID
        })
      else {
        throw ClairWorkspaceError.projectNotFound(projectID)
      }
      let suppliedProjectRoot = suppliedProject.rootURL.standardizedFileURL
      let registeredProjectRoot = registeredProject.rootURL.standardizedFileURL
      let authoritativeProjectRoot = authoritativeProject.rootURL.standardizedFileURL
      guard suppliedProjectRoot == registeredProjectRoot,
        authoritativeProjectRoot == registeredProjectRoot
      else {
        throw ClairWorkspaceError.rootIdentityChanged(suppliedProjectRoot)
      }
      guard !catalog.isTruncated,
        !suppliedProject.isTruncated,
        !authoritativeCatalog.isTruncated,
        !authoritativeProject.isTruncated,
        suppliedProjectRoot == authoritativeProjectRoot,
        suppliedProject.state == authoritativeProject.state,
        suppliedProject.rootDevice == authoritativeProject.rootDevice,
        suppliedProject.rootInode == authoritativeProject.rootInode,
        suppliedProject.repositoryRootURL?.standardizedFileURL
          == authoritativeProject.repositoryRootURL?.standardizedFileURL
      else {
        throw ClairWorkspaceError.rootIdentityChanged(suppliedProjectRoot)
      }

      let rootURL: URL
      let expectedDevice: UInt64?
      let expectedInode: UInt64?
      if let worktreeID {
        guard
          let suppliedWorktree = suppliedProject.worktrees.first(where: {
            $0.id == worktreeID
          }),
          suppliedWorktree.projectID == projectID,
          let authoritativeWorktree = authoritativeProject.worktrees.first(
            where: { $0.id == worktreeID }
          ),
          authoritativeWorktree.projectID == projectID
        else {
          throw ClairWorkspaceError.worktreeNotFound(worktreeID)
        }
        let suppliedWorktreeRoot = suppliedWorktree.rootURL.standardizedFileURL
        guard suppliedWorktreeRoot == authoritativeWorktree.rootURL.standardizedFileURL,
          suppliedWorktree.repositoryRootURL.standardizedFileURL
            == authoritativeWorktree.repositoryRootURL.standardizedFileURL,
          suppliedWorktree.rootDevice == authoritativeWorktree.rootDevice,
          suppliedWorktree.rootInode == authoritativeWorktree.rootInode,
          suppliedWorktree.state == authoritativeWorktree.state
        else {
          throw ClairWorkspaceError.rootIdentityChanged(suppliedWorktreeRoot)
        }
        guard suppliedWorktree.state == .available else {
          throw ClairWorkspaceError.worktreeRootUnavailable(
            worktreeID,
            suppliedWorktree.state
          )
        }
        rootURL = suppliedWorktreeRoot
        expectedDevice = suppliedWorktree.rootDevice
        expectedInode = suppliedWorktree.rootInode
      } else {
        guard suppliedProject.state == .available else {
          throw ClairWorkspaceError.projectRootUnavailable(projectID, suppliedProject.state)
        }
        rootURL = suppliedProjectRoot
        expectedDevice = suppliedProject.rootDevice
        expectedInode = suppliedProject.rootInode
      }
      guard let expectedDevice, let expectedInode else {
        throw ClairWorkspaceError.rootCapabilityUnavailable(rootURL)
      }
      return try ClairWorkspacePOSIX.openRootCapability(
        at: rootURL,
        expectedDevice: expectedDevice,
        expectedInode: expectedInode
      )
    #else
      throw ClairWorkspaceError.unsupportedPlatform
    #endif
  }

  public func fileTree(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    path: ClairWorkspacePath = .root,
    options: ClairFileTreeOptions = .standard
  ) throws -> ClairFileTree {
    #if os(macOS)
      let root = try resolveRoot(projectID: projectID, worktreeID: worktreeID)
      let effectiveOptions = ClairFileTreeOptions(
        uncheckedMaximumDepth: min(options.maximumDepth, limits.maximumTreeDepth),
        uncheckedMaximumEntries: min(options.maximumEntries, limits.maximumTreeEntries)
      )
      return try ClairWorkspaceFileSystem.readTree(
        root: root,
        path: path,
        options: effectiveOptions
      )
    #else
      throw ClairWorkspaceError.unsupportedPlatform
    #endif
  }

  public func readFile(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    path: ClairWorkspacePath,
    maximumBytes: Int? = nil
  ) throws -> ClairFileReadResult {
    #if os(macOS)
      let root = try resolveRoot(projectID: projectID, worktreeID: worktreeID)
      let effectiveMaximumBytes = maximumBytes ?? limits.maximumFileReadBytes
      guard effectiveMaximumBytes > 0,
        effectiveMaximumBytes <= limits.maximumFileReadBytes
      else {
        throw ClairWorkspaceError.invalidLimits
      }
      return try ClairWorkspaceFileSystem.readText(
        root: root,
        path: path,
        maximumBytes: effectiveMaximumBytes
      )
    #else
      throw ClairWorkspaceError.unsupportedPlatform
    #endif
  }

  public func changedFileSummary(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    catalog: ClairWorkspaceCatalog? = nil
  ) throws -> ClairChangedFileSummary {
    #if os(macOS)
      let root = try resolveRoot(
        projectID: projectID,
        worktreeID: worktreeID,
        catalog: catalog
      )
      return try ClairWorkspaceGit.changedFileSummary(
        projectID: projectID,
        root: root,
        limits: limits
      )
    #else
      throw ClairWorkspaceError.unsupportedPlatform
    #endif
  }

  public func changedFileSummary(
    from catalog: ClairWorkspaceCatalog,
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil
  ) throws -> ClairChangedFileSummary {
    try changedFileSummary(
      projectID: projectID,
      worktreeID: worktreeID,
      catalog: catalog
    )
  }

  public func changedFiles(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    catalog: ClairWorkspaceCatalog? = nil
  ) throws -> ClairChangedFileSummary {
    try changedFileSummary(
      projectID: projectID,
      worktreeID: worktreeID,
      catalog: catalog
    )
  }

  /// Returns the current read-only Git status for a registered root.
  public func gitStatus(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    catalog: ClairWorkspaceCatalog? = nil
  ) throws -> ClairChangedFileSummary {
    try changedFileSummary(
      projectID: projectID,
      worktreeID: worktreeID,
      catalog: catalog
    )
  }

  public func gitStatus(
    from catalog: ClairWorkspaceCatalog,
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil
  ) throws -> ClairChangedFileSummary {
    try gitStatus(
      projectID: projectID,
      worktreeID: worktreeID,
      catalog: catalog
    )
  }

  /// Returns the bounded changed-file list without exposing any Git command
  /// output or filesystem path outside the registered root.
  public func changedFileList(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    catalog: ClairWorkspaceCatalog? = nil
  ) throws -> [ClairChangedFile] {
    try changedFileSummary(
      projectID: projectID,
      worktreeID: worktreeID,
      catalog: catalog
    ).files
  }

  public func gitDiff(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    path: ClairWorkspacePath,
    basis: ClairGitDiffBasis = .workingTree,
    catalog: ClairWorkspaceCatalog? = nil
  ) throws -> ClairGitDiff {
    #if os(macOS)
      let root = try resolveRoot(
        projectID: projectID,
        worktreeID: worktreeID,
        catalog: catalog
      )
      return try ClairWorkspaceGit.diff(
        root: root,
        path: path,
        basis: basis,
        limits: limits
      )
    #else
      throw ClairWorkspaceError.unsupportedPlatform
    #endif
  }

  public func gitDiff(
    from catalog: ClairWorkspaceCatalog,
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    path: ClairWorkspacePath,
    basis: ClairGitDiffBasis = .workingTree
  ) throws -> ClairGitDiff {
    try gitDiff(
      projectID: projectID,
      worktreeID: worktreeID,
      path: path,
      basis: basis,
      catalog: catalog
    )
  }

  public func diff(
    projectID: ProjectID,
    worktreeID: WorktreeID? = nil,
    path: ClairWorkspacePath,
    basis: ClairGitDiffBasis = .workingTree,
    catalog: ClairWorkspaceCatalog? = nil
  ) throws -> ClairGitDiff {
    try gitDiff(
      projectID: projectID,
      worktreeID: worktreeID,
      path: path,
      basis: basis,
      catalog: catalog
    )
  }

  #if os(macOS)

    private func resolveRoot(
      projectID: ProjectID,
      worktreeID: WorktreeID?,
      catalog: ClairWorkspaceCatalog? = nil
    ) throws -> ClairWorkspaceRootReference {
      guard projectsByID[projectID] != nil else {
        throw ClairWorkspaceError.projectNotFound(projectID)
      }
      let snapshot = try catalog ?? self.catalog()
      let capability = try launchRootCapability(
        from: snapshot,
        projectID: projectID,
        worktreeID: worktreeID
      )
      return ClairWorkspaceRootReference(
        projectID: projectID,
        worktreeID: worktreeID,
        rootURL: capability.rootURL,
        device: capability.device,
        inode: capability.inode
      )
    }

  #endif
}

#if os(macOS)

  private struct ClairWorkspaceRootReference: Equatable, Sendable {
    let projectID: ProjectID
    let worktreeID: WorktreeID?
    let rootURL: URL
    let device: UInt64
    let inode: UInt64
  }

  private enum ClairWorkspacePOSIXFileKind {
    case directory
    case regularFile
    case symlink
    case other
  }

  private struct ClairWorkspacePOSIXMetadata {
    let kind: ClairWorkspacePOSIXFileKind
    let byteCount: UInt64
    let device: UInt64
    let inode: UInt64
  }

  private enum ClairWorkspacePOSIXLookupError: Error {
    case errno(Int32)
  }

  private enum ClairWorkspacePOSIX {
    static func rootState(at url: URL) -> ClairWorkspaceRootState {
      rootProbe(at: url).state
    }

    static func rootProbe(at url: URL) -> (
      state: ClairWorkspaceRootState,
      device: UInt64?,
      inode: UInt64?
    ) {
      let fileMetadata: ClairWorkspacePOSIXMetadata
      do {
        fileMetadata = try metadata(at: url)
      } catch ClairWorkspacePOSIXLookupError.errno(let errorNumber) {
        return (state(for: errorNumber), nil, nil)
      } catch {
        return (.inaccessible, nil, nil)
      }

      switch fileMetadata.kind {
      case .symlink:
        return (.symlink, nil, nil)
      case .regularFile, .other:
        return (.notDirectory, nil, nil)
      case .directory:
        let descriptor = Darwin.open(
          url.path,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
          return (state(for: errno), nil, nil)
        }
        var descriptorInformation = stat()
        guard Darwin.fstat(descriptor, &descriptorInformation) == 0,
          descriptorInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          UInt64(descriptorInformation.st_dev) == fileMetadata.device,
          UInt64(descriptorInformation.st_ino) == fileMetadata.inode
        else {
          Darwin.close(descriptor)
          return (.inaccessible, nil, nil)
        }
        Darwin.close(descriptor)
        return (
          .available,
          UInt64(descriptorInformation.st_dev),
          UInt64(descriptorInformation.st_ino)
        )
      }
    }

    static func metadata(at url: URL) throws -> ClairWorkspacePOSIXMetadata {
      var information = stat()
      guard Darwin.lstat(url.path, &information) == 0 else {
        throw ClairWorkspacePOSIXLookupError.errno(errno)
      }

      let fileType = information.st_mode & mode_t(S_IFMT)
      let kind: ClairWorkspacePOSIXFileKind
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
      return ClairWorkspacePOSIXMetadata(
        kind: kind,
        byteCount: information.st_size > 0 ? UInt64(information.st_size) : 0,
        device: UInt64(information.st_dev),
        inode: UInt64(information.st_ino)
      )
    }

    static func openRootCapability(
      at url: URL,
      expectedDevice: UInt64,
      expectedInode: UInt64
    ) throws -> ClairWorkspaceRootCapability {
      let pathMetadata: ClairWorkspacePOSIXMetadata
      do {
        pathMetadata = try metadata(at: url)
      } catch {
        throw ClairWorkspaceError.rootIdentityChanged(url)
      }
      guard pathMetadata.kind == .directory,
        pathMetadata.device == expectedDevice,
        pathMetadata.inode == expectedInode
      else {
        throw ClairWorkspaceError.rootIdentityChanged(url)
      }

      let descriptor = Darwin.open(
        url.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        throw ClairWorkspaceError.rootCapabilityUnavailable(url)
      }

      var descriptorInformation = stat()
      guard Darwin.fstat(descriptor, &descriptorInformation) == 0 else {
        Darwin.close(descriptor)
        throw ClairWorkspaceError.rootCapabilityUnavailable(url)
      }
      guard descriptorInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
        UInt64(descriptorInformation.st_dev) == expectedDevice,
        UInt64(descriptorInformation.st_ino) == expectedInode
      else {
        Darwin.close(descriptor)
        throw ClairWorkspaceError.rootIdentityChanged(url)
      }
      return ClairWorkspaceRootCapability(
        rootURL: url,
        descriptor: descriptor,
        device: expectedDevice,
        inode: expectedInode
      )
    }

    static func state(for errorNumber: Int32) -> ClairWorkspaceRootState {
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

  private enum ClairWorkspaceFileSystem {
    static func readTree(
      root: ClairWorkspaceRootReference,
      path: ClairWorkspacePath,
      options: ClairFileTreeOptions
    ) throws -> ClairFileTree {
      let directoryURL = try resolve(
        root: root,
        path: path,
        expected: .directory
      )
      var entries: [ClairFileTreeEntry] = []
      var isTruncated = false
      try ensureDirectoryCanBeOpened(at: directoryURL, path: path)
      guard
        let enumerator = FileManager.default.enumerator(
          at: directoryURL,
          includingPropertiesForKeys: nil,
          options: []
        )
      else {
        throw ClairWorkspaceError.directoryReadFailed(path)
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
          throw ClairWorkspaceError.directoryReadFailed(path)
        }
        let childURL = rawChildURL.standardizedFileURL
        guard childURL.path.hasPrefix(basePrefix)
        else {
          throw ClairWorkspaceError.directoryReadFailed(path)
        }
        let suffix = String(childURL.path.dropFirst(basePrefix.count))
        guard !suffix.isEmpty else {
          throw ClairWorkspaceError.directoryReadFailed(path)
        }
        let childPath = try ClairWorkspacePath(
          path == .root ? suffix : "\(path.rawValue)/\(suffix)"
        )
        let metadata: ClairWorkspacePOSIXMetadata
        do {
          metadata = try ClairWorkspacePOSIX.metadata(at: childURL)
        } catch ClairWorkspacePOSIXLookupError.errno(let errorNumber) {
          if ClairWorkspacePOSIX.isMissingError(errorNumber) {
            throw ClairWorkspaceError.pathNotFound(childPath)
          }
          if ClairWorkspacePOSIX.isPermissionError(errorNumber) {
            throw ClairWorkspaceError.pathPermissionDenied(childPath)
          }
          throw ClairWorkspaceError.directoryReadFailed(path)
        }

        let kind: ClairFileTreeEntryKind
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
          ClairFileTreeEntry(
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
      return ClairFileTree(
        root: path,
        entries: entries,
        maximumDepth: options.maximumDepth,
        maximumEntries: options.maximumEntries,
        isTruncated: isTruncated
      )
    }

    static func readText(
      root: ClairWorkspaceRootReference,
      path: ClairWorkspacePath,
      maximumBytes: Int
    ) throws -> ClairFileReadResult {
      _ = try resolve(root: root, path: path, expected: .regularFile)
      let (descriptor, initialByteCount) = try openRegularFile(root: root, path: path)
      defer { Darwin.close(descriptor) }

      guard initialByteCount <= UInt64(maximumBytes) else {
        throw ClairWorkspaceError.fileTooLarge(
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
            throw ClairWorkspaceError.fileTooLarge(
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
        if ClairWorkspacePOSIX.isPermissionError(errno) {
          throw ClairWorkspaceError.pathPermissionDenied(path)
        }
        if ClairWorkspacePOSIX.isMissingError(errno) {
          throw ClairWorkspaceError.pathNotFound(path)
        }
        throw ClairWorkspaceError.directoryReadFailed(path)
      }

      if data.contains(0) {
        throw ClairWorkspaceError.binaryFile(path)
      }
      guard let content = String(data: data, encoding: .utf8) else {
        throw ClairWorkspaceError.invalidEncoding(path)
      }
      return ClairFileReadResult(
        path: path,
        content: content,
        byteCount: data.count,
        maximumBytes: maximumBytes
      )
    }

    private static func resolve(
      root: ClairWorkspaceRootReference,
      path: ClairWorkspacePath,
      expected: ClairWorkspacePOSIXFileKind
    ) throws -> URL {
      let rootState = ClairWorkspacePOSIX.rootState(at: root.rootURL)
      guard rootState == .available else {
        if let worktreeID = root.worktreeID {
          throw ClairWorkspaceError.worktreeRootUnavailable(worktreeID, rootState)
        }
        throw ClairWorkspaceError.projectRootUnavailable(root.projectID, rootState)
      }

      var currentURL = root.rootURL
      var currentPath = ""
      for component in path.components {
        currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
        currentURL.appendPathComponent(component, isDirectory: false)
        let metadata: ClairWorkspacePOSIXMetadata
        do {
          metadata = try ClairWorkspacePOSIX.metadata(at: currentURL)
        } catch ClairWorkspacePOSIXLookupError.errno(let errorNumber) {
          guard let partialPath = try? ClairWorkspacePath(currentPath) else {
            throw ClairWorkspaceError.invalidPath
          }
          if ClairWorkspacePOSIX.isMissingError(errorNumber) {
            throw ClairWorkspaceError.pathNotFound(partialPath)
          }
          if ClairWorkspacePOSIX.isPermissionError(errorNumber) {
            throw ClairWorkspaceError.pathPermissionDenied(partialPath)
          }
          throw ClairWorkspaceError.directoryReadFailed(partialPath)
        }
        guard metadata.kind != .symlink else {
          guard let partialPath = try? ClairWorkspacePath(currentPath) else {
            throw ClairWorkspaceError.invalidPath
          }
          throw ClairWorkspaceError.pathIsSymlink(partialPath)
        }
        if component != path.components.last, metadata.kind != .directory {
          throw ClairWorkspaceError.pathNotDirectory(path)
        }
      }

      let metadata: ClairWorkspacePOSIXMetadata
      do {
        metadata = try ClairWorkspacePOSIX.metadata(at: currentURL)
      } catch ClairWorkspacePOSIXLookupError.errno(let errorNumber) {
        if ClairWorkspacePOSIX.isMissingError(errorNumber) {
          throw ClairWorkspaceError.pathNotFound(path)
        }
        if ClairWorkspacePOSIX.isPermissionError(errorNumber) {
          throw ClairWorkspaceError.pathPermissionDenied(path)
        }
        throw ClairWorkspaceError.directoryReadFailed(path)
      }
      guard metadata.kind == expected else {
        switch expected {
        case .directory:
          throw ClairWorkspaceError.pathNotDirectory(path)
        case .regularFile:
          throw ClairWorkspaceError.pathNotRegularFile(path)
        default:
          throw ClairWorkspaceError.invalidPath
        }
      }
      return currentURL
    }

    private static func ensureDirectoryCanBeOpened(
      at url: URL,
      path: ClairWorkspacePath
    ) throws {
      let descriptor = Darwin.open(
        url.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard descriptor >= 0 else {
        if ClairWorkspacePOSIX.isPermissionError(errno) {
          throw ClairWorkspaceError.pathPermissionDenied(path)
        }
        if ClairWorkspacePOSIX.isMissingError(errno) {
          throw ClairWorkspaceError.pathNotFound(path)
        }
        if errno == ELOOP {
          throw ClairWorkspaceError.pathIsSymlink(path)
        }
        throw ClairWorkspaceError.directoryReadFailed(path)
      }
      Darwin.close(descriptor)
    }

    private static func openRegularFile(
      root: ClairWorkspaceRootReference,
      path: ClairWorkspacePath
    ) throws -> (descriptor: Int32, byteCount: UInt64) {
      let rootDescriptor = Darwin.open(
        root.rootURL.path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard rootDescriptor >= 0 else {
        let state = ClairWorkspacePOSIX.rootState(at: root.rootURL)
        if let worktreeID = root.worktreeID {
          throw ClairWorkspaceError.worktreeRootUnavailable(worktreeID, state)
        }
        throw ClairWorkspaceError.projectRootUnavailable(root.projectID, state)
      }

      var directoryDescriptor = rootDescriptor
      var currentPath = ""
      let components = path.components
      guard let fileName = components.last else {
        Darwin.close(rootDescriptor)
        throw ClairWorkspaceError.pathNotRegularFile(path)
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
          guard let partialPath = try? ClairWorkspacePath(currentPath) else {
            throw ClairWorkspaceError.invalidPath
          }
          if errorNumber == ELOOP {
            throw ClairWorkspaceError.pathIsSymlink(partialPath)
          }
          if ClairWorkspacePOSIX.isPermissionError(errorNumber) {
            throw ClairWorkspaceError.pathPermissionDenied(partialPath)
          }
          if ClairWorkspacePOSIX.isMissingError(errorNumber) {
            throw ClairWorkspaceError.pathNotFound(partialPath)
          }
          throw ClairWorkspaceError.pathNotDirectory(partialPath)
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
          throw ClairWorkspaceError.pathIsSymlink(path)
        }
        if ClairWorkspacePOSIX.isPermissionError(errorNumber) {
          throw ClairWorkspaceError.pathPermissionDenied(path)
        }
        if ClairWorkspacePOSIX.isMissingError(errorNumber) {
          throw ClairWorkspaceError.pathNotFound(path)
        }
        throw ClairWorkspaceError.pathNotRegularFile(path)
      }
      Darwin.close(rootDescriptor)

      var information = stat()
      guard Darwin.fstat(fileDescriptor, &information) == 0 else {
        Darwin.close(fileDescriptor)
        throw ClairWorkspaceError.pathNotRegularFile(path)
      }
      guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        Darwin.close(fileDescriptor)
        throw ClairWorkspaceError.pathNotRegularFile(path)
      }
      return (fileDescriptor, information.st_size > 0 ? UInt64(information.st_size) : 0)
    }
  }

  private struct ClairGitCommandOutput {
    let data: Data
    let isTruncated: Bool
  }

  private enum ClairGitCommandError: Error {
    case executableUnavailable
    case failed(operation: String, status: Int32)
  }

  private struct ClairGitWorktree {
    let rootURL: URL
    let headRevision: String?
    let branch: String?
    let isDetached: Bool
    let isLocked: Bool
    let isPrunable: Bool
  }

  private enum ClairWorkspaceGit {
    static func repositoryRoot(at rootURL: URL, limits: ClairWorkspaceLimits) throws -> URL? {
      do {
        let output = try run(
          ["rev-parse", "--show-toplevel"],
          at: rootURL,
          operation: "find repository root",
          maximumOutputBytes: limits.maximumGitOutputBytes
        )
        guard !output.isTruncated else {
          throw ClairWorkspaceError.gitOutputTooLarge(
            operation: "find repository root",
            maximumBytes: limits.maximumGitOutputBytes
          )
        }
        guard let text = String(data: output.data, encoding: .utf8) else {
          throw ClairWorkspaceError.gitOutputInvalidEncoding(
            operation: "find repository root"
          )
        }
        let lines = text.split(whereSeparator: { $0 == "\n" })
        guard lines.count == 1 else {
          throw ClairWorkspaceError.gitOutputMalformed(operation: "find repository root")
        }
        let path = String(lines[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
          throw ClairWorkspaceError.gitOutputMalformed(operation: "find repository root")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
      } catch ClairGitCommandError.failed(_, let status) where status == 128 {
        return nil
      } catch ClairGitCommandError.executableUnavailable {
        throw ClairWorkspaceError.gitExecutableUnavailable
      } catch ClairGitCommandError.failed(let operation, let status) {
        throw ClairWorkspaceError.gitCommandFailed(operation: operation, status: status)
      }
    }

    static func worktrees(
      repositoryRoot: URL,
      projectID: ProjectID,
      limits: ClairWorkspaceLimits
    ) throws -> (entries: [ClairWorktreeCatalogEntry], isTruncated: Bool) {
      let operation = "list worktrees"
      let output: ClairGitCommandOutput
      do {
        output = try run(
          ["worktree", "list", "--porcelain", "-z"],
          at: repositoryRoot,
          operation: operation,
          maximumOutputBytes: limits.maximumGitOutputBytes
        )
      } catch ClairGitCommandError.executableUnavailable {
        throw ClairWorkspaceError.gitExecutableUnavailable
      } catch ClairGitCommandError.failed(let operation, let status) {
        throw ClairWorkspaceError.gitCommandFailed(operation: operation, status: status)
      }

      let parsed = try parseWorktrees(output.data, isTruncated: output.isTruncated)
      var paths = Set<String>()
      var worktreeIDs = Set<WorktreeID>()
      var entries: [ClairWorktreeCatalogEntry] = []
      for worktree in parsed {
        guard paths.insert(canonicalPath(worktree.rootURL)).inserted else {
          throw ClairWorkspaceError.gitOutputMalformed(operation: operation)
        }
        let worktreeID = try makeWorktreeID(
          projectID: projectID,
          repositoryRoot: repositoryRoot,
          rootURL: worktree.rootURL
        )
        guard worktreeIDs.insert(worktreeID).inserted else {
          throw ClairWorkspaceError.gitOutputMalformed(operation: operation)
        }
        let rootProbe = ClairWorkspacePOSIX.rootProbe(at: worktree.rootURL)
        entries.append(
          ClairWorktreeCatalogEntry(
            id: worktreeID,
            projectID: projectID,
            repositoryRootURL: repositoryRoot,
            rootURL: worktree.rootURL,
            rootDevice: rootProbe.device,
            rootInode: rootProbe.inode,
            headRevision: worktree.headRevision,
            branch: worktree.branch,
            state: rootProbe.state,
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
      root: ClairWorkspaceRootReference,
      limits: ClairWorkspaceLimits
    ) throws -> ClairChangedFileSummary {
      try verifyRoot(root)
      guard try repositoryRoot(at: root.rootURL, limits: limits) != nil else {
        throw ClairWorkspaceError.repositoryNotFound(projectID)
      }
      try verifyRoot(root)
      let operation = "summarize changed files"
      let output: ClairGitCommandOutput
      do {
        output = try run(
          ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
          at: root.rootURL,
          operation: operation,
          maximumOutputBytes: limits.maximumChangedOutputBytes
        )
      } catch ClairGitCommandError.executableUnavailable {
        throw ClairWorkspaceError.gitExecutableUnavailable
      } catch ClairGitCommandError.failed(let operation, let status) {
        throw ClairWorkspaceError.gitCommandFailed(operation: operation, status: status)
      }

      try verifyRoot(root)

      let parsed = try parseChanges(
        output.data,
        isTruncated: output.isTruncated,
        maximumFiles: limits.maximumChangedFiles
      )
      return ClairChangedFileSummary(
        files: parsed.files.sorted { $0.path.rawValue < $1.path.rawValue },
        isTruncated: output.isTruncated || parsed.isTruncated,
        outputBytes: output.data.count,
        maximumOutputBytes: limits.maximumChangedOutputBytes,
        maximumFiles: limits.maximumChangedFiles
      )
    }

    static func diff(
      root: ClairWorkspaceRootReference,
      path: ClairWorkspacePath,
      basis: ClairGitDiffBasis,
      limits: ClairWorkspaceLimits
    ) throws -> ClairGitDiff {
      try verifyRoot(root)
      guard try repositoryRoot(at: root.rootURL, limits: limits) != nil else {
        throw ClairWorkspaceError.repositoryNotFound(root.projectID)
      }
      try verifyRoot(root)

      let status = try changedFileSummary(
        projectID: root.projectID,
        root: root,
        limits: limits
      )
      let changedFile = status.files.first { file in
        file.path == path || file.originalPath == path
      }
      guard let changedFile else {
        throw ClairWorkspaceError.gitPathNotChanged(path)
      }

      let operation = "read \(basis.rawValue) diff"
      var arguments = [
        "--literal-pathspecs",
        "diff",
        "--no-ext-diff",
        "--no-color",
        "--full-index",
        "--find-renames",
        "--find-copies",
        "--unified=3",
      ]
      if basis == .staged {
        arguments.append("--cached")
      }

      let output: ClairGitCommandOutput
      let isUntracked = changedFile.kind == .untracked
      if isUntracked {
        guard basis == .workingTree else {
          return ClairGitDiff(
            path: path,
            basis: basis,
            kind: .text,
            text: "",
            hunks: [],
            isTruncated: false,
            outputBytes: 0,
            maximumOutputBytes: limits.maximumChangedOutputBytes
          )
        }
        output = try run(
          [
            "--literal-pathspecs",
            "diff",
            "--no-index",
            "--no-ext-diff",
            "--no-color",
            "--unified=3",
            "--",
            "/dev/null",
            path.rawValue,
          ],
          at: root.rootURL,
          operation: operation,
          maximumOutputBytes: limits.maximumChangedOutputBytes,
          acceptableStatuses: [0, 1]
        )
      } else {
        arguments.append(contentsOf: ["--", path.rawValue])
        output = try run(
          arguments,
          at: root.rootURL,
          operation: operation,
          maximumOutputBytes: limits.maximumChangedOutputBytes
        )
      }

      try verifyRoot(root)
      let text = try decodeGitOutput(
        output.data,
        isTruncated: output.isTruncated,
        operation: operation
      )
      let parsed = try parseDiff(
        text,
        path: path,
        originalPath: changedFile.originalPath,
        basis: basis,
        isTruncated: output.isTruncated
      )
      return ClairGitDiff(
        path: parsed.path,
        originalPath: parsed.originalPath,
        basis: basis,
        kind: parsed.kind,
        text: parsed.kind == .binary ? nil : text,
        hunks: parsed.hunks,
        isTruncated: output.isTruncated || parsed.isTruncated,
        outputBytes: output.data.count,
        maximumOutputBytes: limits.maximumChangedOutputBytes
      )
    }

    private static func verifyRoot(_ root: ClairWorkspaceRootReference) throws {
      let probe = ClairWorkspacePOSIX.rootProbe(at: root.rootURL)
      guard probe.state == .available,
        probe.device == root.device,
        probe.inode == root.inode
      else {
        throw ClairWorkspaceError.rootIdentityChanged(root.rootURL)
      }
    }

    private static func decodeGitOutput(
      _ data: Data,
      isTruncated: Bool,
      operation: String
    ) throws -> String {
      if let text = String(data: data, encoding: .utf8) {
        return text
      }
      guard isTruncated else {
        throw ClairWorkspaceError.gitOutputInvalidEncoding(operation: operation)
      }

      // A bounded read is allowed to stop in the middle of a UTF-8 scalar.
      // Remove only an incomplete trailing scalar; invalid bytes earlier in
      // the output remain a typed failure.
      for suffixLength in 1...3 where data.count >= suffixLength {
        let prefix = data.dropLast(suffixLength)
        if let text = String(data: prefix, encoding: .utf8) {
          return text
        }
      }
      throw ClairWorkspaceError.gitOutputInvalidEncoding(operation: operation)
    }

    private static func parseDiff(
      _ text: String,
      path: ClairWorkspacePath,
      originalPath: ClairWorkspacePath?,
      basis: ClairGitDiffBasis,
      isTruncated: Bool
    ) throws -> (
      path: ClairWorkspacePath,
      originalPath: ClairWorkspacePath?,
      kind: ClairGitDiffKind,
      hunks: [ClairGitDiffHunk],
      isTruncated: Bool
    ) {
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      var resolvedPath = path
      var resolvedOriginalPath = originalPath
      var hunks: [ClairGitDiffHunk] = []
      var parserTruncated = false
      var isBinary = false

      for line in lines {
        if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
          isBinary = true
          continue
        }
        if line.hasPrefix("rename from ") {
          let rawPath = String(line.dropFirst("rename from ".count))
          resolvedOriginalPath = try? ClairWorkspacePath(rawPath)
          continue
        }
        if line.hasPrefix("rename to ") {
          let rawPath = String(line.dropFirst("rename to ".count))
          if let renamePath = try? ClairWorkspacePath(rawPath) {
            resolvedPath = renamePath
          }
          continue
        }
        guard line.hasPrefix("@@ ") else { continue }
        guard let hunk = parseHunkHeader(line, index: hunks.count) else {
          if isTruncated {
            parserTruncated = true
            break
          }
          throw ClairWorkspaceError.gitOutputMalformed(operation: "read \(basis.rawValue) diff")
        }
        hunks.append(hunk)
      }

      return (
        resolvedPath,
        resolvedOriginalPath,
        isBinary ? .binary : .text,
        hunks,
        parserTruncated
      )
    }

    private static func parseHunkHeader(
      _ line: String,
      index: Int
    ) -> ClairGitDiffHunk? {
      guard line.hasPrefix("@@ "), let end = line.range(of: " @@") else {
        return nil
      }
      let range = line[line.index(line.startIndex, offsetBy: 3)..<end.lowerBound]
      let sides = range.split(separator: " ")
      guard sides.count == 2,
        let old = parseHunkSide(String(sides[0]), prefix: "-"),
        let new = parseHunkSide(String(sides[1]), prefix: "+")
      else {
        return nil
      }
      return ClairGitDiffHunk(
        id: "hunk-\(index)",
        header: line,
        oldStart: old.start,
        oldCount: old.count,
        newStart: new.start,
        newCount: new.count
      )
    }

    private static func parseHunkSide(
      _ value: String,
      prefix: String
    ) -> (start: Int, count: Int)? {
      guard value.hasPrefix(prefix) else { return nil }
      let components = value.dropFirst().split(separator: ",")
      guard !components.isEmpty, let start = Int(components[0]), start >= 0 else {
        return nil
      }
      let count = components.count == 2 ? Int(components[1]) : 1
      guard let count, count >= 0 else { return nil }
      return (start, count)
    }

    private static func run(
      _ arguments: [String],
      at rootURL: URL,
      operation: String,
      maximumOutputBytes: Int,
      acceptableStatuses: Set<Int32> = [0]
    ) throws -> ClairGitCommandOutput {
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
        throw ClairGitCommandError.executableUnavailable
      }

      let process = Process()
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = arguments
      process.currentDirectoryURL = rootURL
      var environment = ProcessInfo.processInfo.environment
      for key in [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_WORK_TREE",
      ] {
        environment.removeValue(forKey: key)
      }
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
        throw ClairGitCommandError.executableUnavailable
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

      guard isTruncated || acceptableStatuses.contains(process.terminationStatus) else {
        throw ClairGitCommandError.failed(
          operation: operation,
          status: process.terminationStatus
        )
      }
      return ClairGitCommandOutput(data: data, isTruncated: isTruncated)
    }

    private static func parseWorktrees(
      _ data: Data,
      isTruncated: Bool
    ) throws -> [ClairGitWorktree] {
      guard let text = String(data: data, encoding: .utf8) else {
        throw ClairWorkspaceError.gitOutputInvalidEncoding(operation: "list worktrees")
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
          throw ClairWorkspaceError.gitOutputMalformed(operation: "list worktrees")
        }
        fields = []
      }

      var worktrees: [ClairGitWorktree] = []
      for fields in records {
        guard let worktreeField = fields.first, worktreeField.hasPrefix("worktree ") else {
          throw ClairWorkspaceError.gitOutputMalformed(operation: "list worktrees")
        }
        let path = String(worktreeField.dropFirst("worktree ".count))
        guard path.hasPrefix("/") else {
          throw ClairWorkspaceError.gitOutputMalformed(operation: "list worktrees")
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
          ClairGitWorktree(
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
        throw ClairWorkspaceError.gitOutputMalformed(operation: "list worktrees")
      }
      return worktrees
    }

    private static func parseChanges(
      _ data: Data,
      isTruncated: Bool,
      maximumFiles: Int
    ) throws -> (files: [ClairChangedFile], isTruncated: Bool) {
      let bytes = Array(data)
      let tokens = bytes.split(separator: 0, omittingEmptySubsequences: true)
      var files: [ClairChangedFile] = []
      var index = 0
      var parserTruncated = isTruncated && data.last != 0

      while index < tokens.count {
        let token = Data(tokens[index])
        guard let header = String(data: token, encoding: .utf8) else {
          throw ClairWorkspaceError.gitOutputInvalidEncoding(
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
          throw ClairWorkspaceError.gitOutputMalformed(
            operation: "summarize changed files"
          )
        }

        let indexStatus = String(headerCharacters[0])
        let worktreeStatus = String(headerCharacters[1])
        let pathString = String(header.dropFirst(3))
        guard let path = try? ClairWorkspacePath(pathString) else {
          throw ClairWorkspaceError.gitOutputMalformed(
            operation: "summarize changed files"
          )
        }

        var originalPath: ClairWorkspacePath?
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
            let typedOriginalPath = try? ClairWorkspacePath(originalString)
          else {
            throw ClairWorkspaceError.gitOutputMalformed(
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
            ClairChangedFile(
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
    ) -> ClairChangedFileKind {
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
        throw ClairWorkspaceError.gitOutputMalformed(operation: "list worktrees")
      }
    }
  }

  private struct ClairWorkspaceCatalogReader {
    let limits: ClairWorkspaceLimits

    func read(projects: [ClairProjectRoot]) throws -> ClairWorkspaceCatalog {
      let entries = try projects.map(read)
      return ClairWorkspaceCatalog(
        projects: entries.sorted { $0.id.rawValue < $1.id.rawValue },
        isTruncated: entries.contains(where: \.isTruncated)
      )
    }

    func worktree(
      project: ClairProjectRoot,
      id: WorktreeID
    ) throws -> ClairWorktreeCatalogEntry {
      let entry = try read(project: project)
      guard let worktree = entry.worktrees.first(where: { $0.id == id }) else {
        throw ClairWorkspaceError.worktreeNotFound(id)
      }
      return worktree
    }

    private func read(project: ClairProjectRoot) throws -> ClairProjectCatalogEntry {
      let rootProbe = ClairWorkspacePOSIX.rootProbe(at: project.rootURL)
      let state = rootProbe.state
      guard state == .available else {
        return ClairProjectCatalogEntry(
          id: project.id,
          rootURL: project.rootURL,
          state: state,
          rootDevice: rootProbe.device,
          rootInode: rootProbe.inode
        )
      }

      guard
        let repositoryRoot = try ClairWorkspaceGit.repositoryRoot(
          at: project.rootURL,
          limits: limits
        )
      else {
        return ClairProjectCatalogEntry(
          id: project.id,
          rootURL: project.rootURL,
          state: state,
          rootDevice: rootProbe.device,
          rootInode: rootProbe.inode
        )
      }
      let repositoryState = ClairWorkspacePOSIX.rootState(at: repositoryRoot)
      guard repositoryState == .available else {
        return ClairProjectCatalogEntry(
          id: project.id,
          rootURL: project.rootURL,
          state: repositoryState,
          rootDevice: rootProbe.device,
          rootInode: rootProbe.inode,
          repositoryRootURL: repositoryRoot
        )
      }
      let worktreeResult = try ClairWorkspaceGit.worktrees(
        repositoryRoot: repositoryRoot,
        projectID: project.id,
        limits: limits
      )
      return ClairProjectCatalogEntry(
        id: project.id,
        rootURL: project.rootURL,
        state: state,
        rootDevice: rootProbe.device,
        rootInode: rootProbe.inode,
        repositoryRootURL: repositoryRoot,
        worktrees: worktreeResult.entries,
        isTruncated: worktreeResult.isTruncated
      )
    }
  }

#endif

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

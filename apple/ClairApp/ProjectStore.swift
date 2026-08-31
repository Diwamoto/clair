import Foundation

final class ProjectStore {
  let fileURL: URL?

  var workspaceFileURL: URL? {
    fileURL?.deletingLastPathComponent().appendingPathComponent(
      "workspace-v1.json",
      isDirectory: false
    )
  }

  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(fileURL: URL?, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    self.encoder = encoder
    self.decoder = JSONDecoder()
  }

  static func makeDefault(
    for profile: ClairRuntimeProfile,
    fileManager: FileManager = .default
  ) -> ProjectStore {
    let baseDirectory = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first
    let dataDirectory = baseDirectory.map(profile.applicationSupportURL)
    let fileURL = dataDirectory?.appendingPathComponent("projects-v1.json", isDirectory: false)
    return ProjectStore(fileURL: fileURL, fileManager: fileManager)
  }

  func load() throws -> ProjectStoreSnapshot {
    guard let fileURL else {
      throw ProjectError.storeUnavailable
    }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return .empty
    }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw ProjectError.storeIO(error.localizedDescription)
    }

    let snapshot: ProjectStoreSnapshot
    do {
      snapshot = try decoder.decode(ProjectStoreSnapshot.self, from: data)
    } catch {
      throw ProjectError.malformedStore
    }

    guard snapshot.schemaVersion == ProjectStoreSnapshot.currentSchemaVersion else {
      throw ProjectError.unsupportedStoreVersion(snapshot.schemaVersion)
    }
    return snapshot
  }

  func save(_ snapshot: ProjectStoreSnapshot) throws {
    guard let fileURL else {
      throw ProjectError.storeUnavailable
    }

    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
      )
      let data = try encoder.encode(snapshot)
      try data.write(to: fileURL, options: [.atomic])
    } catch let error as ProjectError {
      throw error
    } catch {
      throw ProjectError.storeIO(error.localizedDescription)
    }
  }

  func loadWorkspace() throws -> ProjectWorkspaceStoreSnapshot {
    guard let workspaceFileURL else {
      throw ProjectError.workspaceUnavailable
    }
    guard fileManager.fileExists(atPath: workspaceFileURL.path) else {
      return .empty
    }

    let data: Data
    do {
      data = try Data(contentsOf: workspaceFileURL)
    } catch {
      throw ProjectError.workspaceIO(error.localizedDescription)
    }

    let snapshot: ProjectWorkspaceStoreSnapshot
    do {
      snapshot = try decoder.decode(ProjectWorkspaceStoreSnapshot.self, from: data)
    } catch {
      throw ProjectError.malformedWorkspaceStore
    }

    guard snapshot.schemaVersion == ProjectWorkspaceStoreSnapshot.currentSchemaVersion else {
      throw ProjectError.unsupportedWorkspaceVersion(snapshot.schemaVersion)
    }
    return snapshot
  }

  func saveWorkspace(_ snapshot: ProjectWorkspaceStoreSnapshot) throws {
    guard let workspaceFileURL else {
      throw ProjectError.workspaceUnavailable
    }

    do {
      try fileManager.createDirectory(
        at: workspaceFileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
      )
      let data = try encoder.encode(snapshot)
      try data.write(to: workspaceFileURL, options: [.atomic])
    } catch let error as ProjectError {
      throw error
    } catch {
      throw ProjectError.workspaceIO(error.localizedDescription)
    }
  }
}

import Foundation
import SwiftUI

@MainActor
final class ProjectWorkspaceModel: ObservableObject {
  let store: ProjectStore
  let rootChecker: any ProjectRootChecking
  let commandRegistry: CommandRegistry

  @Published private(set) var projects: [Project] = []
  @Published private(set) var activeProjectID: UUID?
  @Published private(set) var lastErrorMessage: String?

  private var records: [ProjectRecord] = []

  init(
    store: ProjectStore,
    rootChecker: any ProjectRootChecking = FileSystemProjectRootChecker(),
    commandRegistry: CommandRegistry = CommandRegistry()
  ) {
    self.store = store
    self.rootChecker = rootChecker
    self.commandRegistry = commandRegistry

    do {
      let snapshot = try store.load()
      records = Self.normalizedRecords(snapshot.projects)
      activeProjectID = snapshot.activeProjectID
    } catch let error as ProjectError {
      lastErrorMessage = error.localizedDescription
    } catch {
      lastErrorMessage = error.localizedDescription
    }

    refreshPublishedState()
  }

  var activeProject: Project? {
    guard let activeProjectID else {
      return nil
    }
    return projects.first { $0.id == activeProjectID }
  }

  func dismissError() {
    lastErrorMessage = nil
  }

  func preflight(_ command: ClairCommand) -> CommandPreflight {
    commandRegistry.preflight(command, state: commandState)
  }

  @discardableResult
  func execute(_ command: ClairCommand) -> Result<ClairCommandResult, CommandError> {
    let preflight = preflight(command)
    guard preflight.availability.isAvailable else {
      let reason = preflight.availability.reason ?? "The command is not available."
      let error = CommandError.unavailable(commandID: command.id, reason: reason)
      lastErrorMessage = error.localizedDescription
      return .failure(error)
    }

    do {
      let result = try apply(command)
      lastErrorMessage = nil
      return .success(result)
    } catch let error as ProjectError {
      lastErrorMessage = error.localizedDescription
      return .failure(.project(error))
    } catch {
      let projectError = ProjectError.storeIO(error.localizedDescription)
      lastErrorMessage = projectError.localizedDescription
      return .failure(.project(projectError))
    }
  }

  func moveProject(id: UUID, by offset: Int) {
    guard let currentIndex = projects.firstIndex(where: { $0.id == id }) else {
      return
    }
    let targetIndex = currentIndex + offset
    _ = execute(
      .reorderProject(
        ReorderProjectCommand(projectID: id, targetIndex: targetIndex)
      )
    )
  }

  private var commandState: ProjectCommandState {
    ProjectCommandState(
      openProjectIDs: Set(projects.map(\.id)),
      activeProjectID: activeProjectID
    )
  }

  private func apply(_ command: ClairCommand) throws -> ClairCommandResult {
    switch command {
    case .openProject(let input):
      return .project(try openProject(at: input.rootURL))
    case .switchProject(let input):
      try switchProject(to: input.projectID)
      return .none
    case .renameProject(let input):
      return .project(try renameProject(id: input.projectID, name: input.name))
    case .setProjectColor(let input):
      return .project(try setProjectColor(id: input.projectID, color: input.color))
    case .reorderProject(let input):
      try reorderProject(id: input.projectID, targetIndex: input.targetIndex)
      return .none
    case .closeProject(let input):
      try closeProject(id: input.projectID)
      return .none
    }
  }

  private func openProject(at rootURL: URL) throws -> Project {
    let canonicalURL = try rootChecker.validate(rootURL)

    if let existingIndex = records.firstIndex(where: {
      rootChecker.canonicalURL(for: URL(fileURLWithPath: $0.rootPath, isDirectory: true))
        == canonicalURL
    }) {
      if records[existingIndex].isOpen {
        throw ProjectError.duplicateRoot(existingProjectID: records[existingIndex].id)
      }

      var nextRecords = records
      nextRecords[existingIndex].isOpen = true
      nextRecords[existingIndex].rootPath = canonicalURL.path
      nextRecords[existingIndex].order = openRecords.count
      try commit(nextRecords, activeID: nextRecords[existingIndex].id)
      return try project(id: nextRecords[existingIndex].id)
    }

    let name =
      canonicalURL.lastPathComponent.isEmpty
      ? canonicalURL.path
      : canonicalURL.lastPathComponent
    let record = ProjectRecord(
      id: UUID(),
      rootPath: canonicalURL.path,
      name: name,
      color: .blue,
      isOpen: true,
      order: openRecords.count
    )
    var nextRecords = records
    nextRecords.append(record)
    try commit(nextRecords, activeID: record.id)
    return try project(id: record.id)
  }

  private func switchProject(to projectID: UUID) throws {
    guard records.contains(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }
    try commit(records, activeID: projectID)
  }

  private func renameProject(id projectID: UUID, name: String) throws -> Project {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw ProjectError.invalidName
    }
    guard let index = records.firstIndex(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }

    var nextRecords = records
    nextRecords[index].name = normalizedName
    try commit(nextRecords, activeID: activeProjectID)
    return try project(id: projectID)
  }

  private func setProjectColor(id projectID: UUID, color: ProjectColor) throws -> Project {
    guard let index = records.firstIndex(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }

    var nextRecords = records
    nextRecords[index].color = color
    try commit(nextRecords, activeID: activeProjectID)
    return try project(id: projectID)
  }

  private func reorderProject(id projectID: UUID, targetIndex: Int) throws {
    guard records.contains(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }
    guard openRecords.indices.contains(targetIndex) else {
      throw ProjectError.invalidOrder(targetIndex)
    }

    var ordered = openRecords
    guard let currentIndex = ordered.firstIndex(where: { $0.id == projectID }) else {
      throw ProjectError.projectNotFound(projectID)
    }
    let moved = ordered.remove(at: currentIndex)
    ordered.insert(moved, at: targetIndex)

    var nextRecords = records
    for (order, record) in ordered.enumerated() {
      guard let index = nextRecords.firstIndex(where: { $0.id == record.id }) else {
        throw ProjectError.projectNotFound(record.id)
      }
      nextRecords[index].order = order
    }
    try commit(nextRecords, activeID: activeProjectID)
  }

  private func closeProject(id projectID: UUID) throws {
    guard let index = records.firstIndex(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }

    var nextRecords = records
    nextRecords[index].isOpen = false
    let nextActiveID: UUID?
    if activeProjectID == projectID {
      nextActiveID = openRecords.first { $0.id != projectID }?.id
    } else {
      nextActiveID = activeProjectID
    }
    try commit(nextRecords, activeID: nextActiveID)
  }

  private var openRecords: [ProjectRecord] {
    records.filter(\.isOpen).sorted {
      if $0.order == $1.order {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.order < $1.order
    }
  }

  private func project(id projectID: UUID) throws -> Project {
    guard let record = records.first(where: { $0.id == projectID && $0.isOpen }) else {
      throw ProjectError.projectNotOpen(projectID)
    }
    return makeProject(from: record)
  }

  private func commit(_ nextRecords: [ProjectRecord], activeID: UUID?) throws {
    let previousRecords = records
    let previousActiveID = activeProjectID
    records = Self.normalizedRecords(nextRecords)
    activeProjectID = activeID
    refreshPublishedState()

    let snapshot = ProjectStoreSnapshot(
      schemaVersion: ProjectStoreSnapshot.currentSchemaVersion,
      projects: records,
      activeProjectID: activeProjectID
    )
    do {
      try store.save(snapshot)
    } catch {
      records = previousRecords
      activeProjectID = previousActiveID
      refreshPublishedState()
      throw error
    }
  }

  private func refreshPublishedState() {
    projects = openRecords.map(makeProject(from:))
    if let activeProjectID, projects.contains(where: { $0.id == activeProjectID }) {
      return
    }
    activeProjectID = projects.first?.id
  }

  private func makeProject(from record: ProjectRecord) -> Project {
    let rootURL = URL(fileURLWithPath: record.rootPath, isDirectory: true)
    return Project(
      id: record.id,
      rootURL: rootURL,
      name: record.name,
      color: record.color,
      availability: rootChecker.availability(for: rootURL)
    )
  }

  private static func normalizedRecords(_ records: [ProjectRecord]) -> [ProjectRecord] {
    var normalized = records
    let openIDs =
      normalized
      .filter(\.isOpen)
      .sorted {
        if $0.order == $1.order {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.order < $1.order
      }
      .map(\.id)

    for (order, id) in openIDs.enumerated() {
      guard let index = normalized.firstIndex(where: { $0.id == id }) else {
        continue
      }
      normalized[index].order = order
    }
    return normalized
  }
}

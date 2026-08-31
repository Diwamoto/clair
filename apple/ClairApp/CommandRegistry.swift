import Foundation

enum ClairCommandID: String, CaseIterable, Codable, Hashable, Sendable {
  case openProject = "project.open"
  case switchProject = "project.switch"
  case renameProject = "project.rename"
  case setProjectColor = "project.setColor"
  case reorderProject = "project.reorder"
  case closeProject = "project.close"
}

enum CommandRisk: String, Codable, Equatable, Sendable {
  case read
  case additive
  case write
  case destructive
  case external
}

struct CommandAvailability: Equatable, Sendable {
  let isAvailable: Bool
  let reason: String?

  static let available = CommandAvailability(isAvailable: true, reason: nil)

  static func unavailable(_ reason: String) -> CommandAvailability {
    CommandAvailability(isAvailable: false, reason: reason)
  }
}

struct CommandDescriptor: Identifiable, Equatable, Sendable {
  let id: ClairCommandID
  let title: String
  let risk: CommandRisk
  let aiAvailable: Bool
}

struct ProjectCommandState: Sendable {
  let openProjectIDs: Set<UUID>
  let activeProjectID: UUID?

  var openProjectCount: Int {
    openProjectIDs.count
  }
}

struct OpenProjectCommand: Sendable {
  let rootURL: URL
}

struct SwitchProjectCommand: Sendable {
  let projectID: UUID
}

struct RenameProjectCommand: Sendable {
  let projectID: UUID
  let name: String
}

struct SetProjectColorCommand: Sendable {
  let projectID: UUID
  let color: ProjectColor
}

struct ReorderProjectCommand: Sendable {
  let projectID: UUID
  let targetIndex: Int
}

struct CloseProjectCommand: Sendable {
  let projectID: UUID
}

enum ClairCommand: Sendable {
  case openProject(OpenProjectCommand)
  case switchProject(SwitchProjectCommand)
  case renameProject(RenameProjectCommand)
  case setProjectColor(SetProjectColorCommand)
  case reorderProject(ReorderProjectCommand)
  case closeProject(CloseProjectCommand)

  var id: ClairCommandID {
    switch self {
    case .openProject:
      .openProject
    case .switchProject:
      .switchProject
    case .renameProject:
      .renameProject
    case .setProjectColor:
      .setProjectColor
    case .reorderProject:
      .reorderProject
    case .closeProject:
      .closeProject
    }
  }
}

enum ClairCommandResult: Equatable, Sendable {
  case project(Project)
  case none
}

struct CommandPreflight: Equatable, Sendable {
  let commandID: ClairCommandID
  let risk: CommandRisk
  let availability: CommandAvailability
}

enum CommandError: Error, Equatable, LocalizedError, Sendable {
  case unavailable(commandID: ClairCommandID, reason: String)
  case project(ProjectError)

  var errorDescription: String? {
    switch self {
    case .unavailable(let commandID, let reason):
      "Command \(commandID.rawValue) is unavailable: \(reason)"
    case .project(let error):
      error.localizedDescription
    }
  }
}

struct CommandRegistry: Sendable {
  let descriptors: [CommandDescriptor]

  init() {
    descriptors = [
      CommandDescriptor(
        id: .openProject,
        title: "Open Project Folder",
        risk: .additive,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .switchProject,
        title: "Switch Project",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .renameProject,
        title: "Rename Project",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .setProjectColor,
        title: "Set Project Color",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .reorderProject,
        title: "Reorder Projects",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .closeProject,
        title: "Close Project",
        risk: .write,
        aiAvailable: false
      ),
    ]
  }

  func descriptor(for commandID: ClairCommandID) -> CommandDescriptor? {
    descriptors.first { $0.id == commandID }
  }

  func preflight(
    _ command: ClairCommand,
    state: ProjectCommandState
  ) -> CommandPreflight {
    let descriptor =
      descriptor(for: command.id)
      ?? CommandDescriptor(
        id: command.id,
        title: command.id.rawValue,
        risk: .external,
        aiAvailable: false
      )

    let availability: CommandAvailability
    switch command {
    case .openProject:
      availability = .available
    case .switchProject(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "switch"
      )
    case .renameProject(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "rename"
      )
    case .setProjectColor(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "change color"
      )
    case .reorderProject(let input):
      if !state.openProjectIDs.contains(input.projectID) {
        availability = .unavailable("Project is not open.")
      } else if input.targetIndex < 0 || input.targetIndex >= state.openProjectCount {
        availability = .unavailable("Target position is outside the open Project list.")
      } else {
        availability = .available
      }
    case .closeProject(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "close"
      )
    }

    return CommandPreflight(
      commandID: command.id,
      risk: descriptor.risk,
      availability: availability
    )
  }

  private func projectAvailability(
    for projectID: UUID,
    in state: ProjectCommandState,
    action: String
  ) -> CommandAvailability {
    guard state.openProjectIDs.contains(projectID) else {
      return .unavailable("Cannot \(action) a Project that is not open.")
    }
    return .available
  }
}

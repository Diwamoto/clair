import Foundation

enum ClairCommandID: String, CaseIterable, Codable, Hashable, Sendable {
  case openProject = "project.open"
  case switchProject = "project.switch"
  case renameProject = "project.rename"
  case setProjectColor = "project.setColor"
  case reorderProject = "project.reorder"
  case closeProject = "project.close"
  case gitRefresh = "git.refresh"
  case gitShowDiff = "git.showDiff"
  case gitStage = "git.stage"
  case gitUnstage = "git.unstage"
  case gitCommit = "git.commit"
  case gitSwitchBranch = "git.switchBranch"
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

struct GitRefreshCommand: Sendable {
  let projectID: UUID
}

struct GitShowDiffCommand: Sendable {
  let projectID: UUID
  let relativePath: String
  let basis: ProjectGitDiffBasis
}

struct GitStageCommand: Sendable {
  let projectID: UUID
  let relativePath: String
}

struct GitUnstageCommand: Sendable {
  let projectID: UUID
  let relativePath: String
}

struct GitCommitCommand: Sendable {
  let projectID: UUID
  let message: String
}

struct GitSwitchBranchCommand: Sendable {
  let projectID: UUID
  let branch: String
}

enum ClairCommand: Sendable {
  case openProject(OpenProjectCommand)
  case switchProject(SwitchProjectCommand)
  case renameProject(RenameProjectCommand)
  case setProjectColor(SetProjectColorCommand)
  case reorderProject(ReorderProjectCommand)
  case closeProject(CloseProjectCommand)
  case gitRefresh(GitRefreshCommand)
  case gitShowDiff(GitShowDiffCommand)
  case gitStage(GitStageCommand)
  case gitUnstage(GitUnstageCommand)
  case gitCommit(GitCommitCommand)
  case gitSwitchBranch(GitSwitchBranchCommand)

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
    case .gitRefresh:
      .gitRefresh
    case .gitShowDiff:
      .gitShowDiff
    case .gitStage:
      .gitStage
    case .gitUnstage:
      .gitUnstage
    case .gitCommit:
      .gitCommit
    case .gitSwitchBranch:
      .gitSwitchBranch
    }
  }
}

enum ClairCommandResult: Equatable, Sendable {
  case project(Project)
  case gitStatus(ProjectGitSnapshot)
  case gitDiff(ProjectGitDiff)
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
  case git(ProjectGitError)

  var errorDescription: String? {
    switch self {
    case .unavailable(let commandID, let reason):
      "Command \(commandID.rawValue) is unavailable: \(reason)"
    case .project(let error):
      error.localizedDescription
    case .git(let error):
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
      CommandDescriptor(
        id: .gitRefresh,
        title: "Refresh Git Status",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .gitShowDiff,
        title: "Show Git Diff",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .gitStage,
        title: "Stage Git Change",
        risk: .write,
        aiAvailable: false
      ),
      CommandDescriptor(
        id: .gitUnstage,
        title: "Unstage Git Change",
        risk: .write,
        aiAvailable: false
      ),
      CommandDescriptor(
        id: .gitCommit,
        title: "Commit Git Changes",
        risk: .write,
        aiAvailable: false
      ),
      CommandDescriptor(
        id: .gitSwitchBranch,
        title: "Switch Git Branch",
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
    case .gitRefresh(let input):
      availability = gitProjectAvailability(
        for: input.projectID,
        in: state,
        action: "refresh Git status"
      )
    case .gitShowDiff(let input):
      availability = gitProjectAvailability(
        for: input.projectID,
        in: state,
        action: "show a Git diff",
        requiredValue: input.relativePath,
        valueName: "path"
      )
    case .gitStage(let input):
      availability = gitProjectAvailability(
        for: input.projectID,
        in: state,
        action: "stage a Git change",
        requiredValue: input.relativePath,
        valueName: "path"
      )
    case .gitUnstage(let input):
      availability = gitProjectAvailability(
        for: input.projectID,
        in: state,
        action: "unstage a Git change",
        requiredValue: input.relativePath,
        valueName: "path"
      )
    case .gitCommit(let input):
      availability = gitProjectAvailability(
        for: input.projectID,
        in: state,
        action: "commit Git changes",
        requiredValue: input.message,
        valueName: "commit message"
      )
    case .gitSwitchBranch(let input):
      availability = gitProjectAvailability(
        for: input.projectID,
        in: state,
        action: "switch Git branches",
        requiredValue: input.branch,
        valueName: "branch"
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

  private func gitProjectAvailability(
    for projectID: UUID,
    in state: ProjectCommandState,
    action: String,
    requiredValue: String? = nil,
    valueName: String? = nil
  ) -> CommandAvailability {
    guard state.openProjectIDs.contains(projectID) else {
      return .unavailable("Cannot \(action) a Project that is not open.")
    }
    guard state.activeProjectID == projectID else {
      return .unavailable("Git operations require the Project to be active.")
    }
    if let requiredValue,
      requiredValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let valueName
    {
      return .unavailable("The Git \(valueName) cannot be empty.")
    }
    return .available
  }
}

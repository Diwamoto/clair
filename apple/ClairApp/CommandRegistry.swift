import Foundation

enum ClairCommandID: String, CaseIterable, Codable, Hashable, Sendable {
  case openProject = "project.open"
  case switchProject = "project.switch"
  case renameProject = "project.rename"
  case setProjectColor = "project.setColor"
  case reorderProject = "project.reorder"
  case closeProject = "project.close"
  case navigationOpenFile = "navigation.openFile"
  case navigationQuickOpen = "navigation.quickOpen"
  case navigationSearch = "navigation.search"
  case editorSave = "editor.save"
  case editorUndo = "editor.undo"
  case editorRedo = "editor.redo"
  case paneSplit = "pane.split"
  case paneFocus = "pane.focus"
  case paneMoveTab = "pane.moveTab"
  case paneClose = "pane.close"
  case paneToggleMaximize = "pane.toggleMaximize"
  case paneEqualize = "pane.equalize"
  case terminalOpen = "terminal.open"
  case terminalStop = "terminal.stop"
  case terminalRecover = "terminal.recover"
  case agentList = "agent.list"
  case agentStatus = "agent.status"
  case agentLaunch = "agent.launch"
  case agentReveal = "agent.reveal"
  case agentInput = "agent.input"
  case agentInterrupt = "agent.interrupt"
  case agentStop = "agent.stop"
  case worktreeList = "worktree.list"
  case worktreeCreate = "worktree.create"
  case worktreePrepareCleanup = "worktree.prepareCleanup"
  case gitRefresh = "git.refresh"
  case gitShowDiff = "git.showDiff"
  case gitStage = "git.stage"
  case gitUnstage = "git.unstage"
  case gitCommit = "git.commit"
  case gitSwitchBranch = "git.switchBranch"
  case gitReview = "git.review"
  case gitPrepareAdoption = "git.prepareAdoption"
  case gitAdopt = "git.adopt"
  case notificationList = "notification.list"
  case notificationSetMute = "notification.setMute"
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

struct NavigationOpenFileCommand: Sendable {
  let path: String
  let line: Int?
  let column: Int?
}

struct NavigationQuickOpenCommand: Sendable {
  let projectID: UUID
  let query: String
}

struct NavigationSearchCommand: Sendable {
  let projectID: UUID
  let query: String
}

struct EditorCommand: Sendable {
  let projectID: UUID
  let tabID: String?
}

struct PaneSplitCommand: Sendable {
  let projectID: UUID
  let orientation: ProjectPaneOrientation
}

struct PaneTargetCommand: Sendable {
  let projectID: UUID
  let paneID: UUID
}

struct TerminalCommand: Sendable {
  let projectID: UUID
  let tabID: String?
}

struct LaunchAgentCommand: Sendable {
  let projectID: UUID
  let profileID: String
  let worktreeID: WorktreeID?
}

struct ListAgentsCommand: Sendable {
  let projectID: UUID?
}

struct AgentSessionCommand: Sendable {
  let sessionID: UUID
}

struct AgentInputCommand: Sendable {
  let sessionID: UUID
  let text: String
}

struct RevealAgentCommand: Sendable {
  let projectID: UUID
  let sessionID: UUID
}

struct WorktreeListCommand: Sendable {
  let projectID: UUID
}

struct WorktreeCreateCommand: Sendable {
  let projectID: UUID
  let branch: String
  let baseRevision: String
  let targetName: String
}

struct WorktreeCleanupCommand: Sendable {
  let projectID: UUID
  let worktreeID: WorktreeID
}

struct GitReviewCommand: Sendable {
  let projectID: UUID
  let worktreeID: WorktreeID
}

struct GitAdoptCommand: Sendable {
  let projectID: UUID
  let worktreeID: WorktreeID
  let confirmationID: UUID
}

struct NotificationListCommand: Sendable {
  let projectID: UUID
  let sessionID: UUID?
}

struct NotificationMuteCommand: Sendable {
  let projectID: UUID
  let sessionID: UUID?
  let muted: Bool
}

enum ClairCommand: Sendable {
  case openProject(OpenProjectCommand)
  case switchProject(SwitchProjectCommand)
  case renameProject(RenameProjectCommand)
  case setProjectColor(SetProjectColorCommand)
  case reorderProject(ReorderProjectCommand)
  case closeProject(CloseProjectCommand)
  case navigationOpenFile(NavigationOpenFileCommand)
  case navigationQuickOpen(NavigationQuickOpenCommand)
  case navigationSearch(NavigationSearchCommand)
  case editorSave(EditorCommand)
  case editorUndo(EditorCommand)
  case editorRedo(EditorCommand)
  case paneSplit(PaneSplitCommand)
  case paneFocus(PaneTargetCommand)
  case paneMoveTab(PaneTargetCommand)
  case paneClose(PaneTargetCommand)
  case paneToggleMaximize(ProjectTargetCommand)
  case paneEqualize(ProjectTargetCommand)
  case terminalOpen(ProjectTargetCommand)
  case terminalStop(TerminalCommand)
  case terminalRecover(TerminalCommand)
  case agentList(ListAgentsCommand)
  case agentStatus(AgentSessionCommand)
  case agentLaunch(LaunchAgentCommand)
  case agentReveal(RevealAgentCommand)
  case agentInput(AgentInputCommand)
  case agentInterrupt(AgentSessionCommand)
  case agentStop(AgentSessionCommand)
  case worktreeList(WorktreeListCommand)
  case worktreeCreate(WorktreeCreateCommand)
  case worktreePrepareCleanup(WorktreeCleanupCommand)
  case gitRefresh(GitRefreshCommand)
  case gitShowDiff(GitShowDiffCommand)
  case gitStage(GitStageCommand)
  case gitUnstage(GitUnstageCommand)
  case gitCommit(GitCommitCommand)
  case gitSwitchBranch(GitSwitchBranchCommand)
  case gitReview(GitReviewCommand)
  case gitPrepareAdoption(GitReviewCommand)
  case gitAdopt(GitAdoptCommand)
  case notificationList(NotificationListCommand)
  case notificationSetMute(NotificationMuteCommand)

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
    case .navigationOpenFile:
      .navigationOpenFile
    case .navigationQuickOpen:
      .navigationQuickOpen
    case .navigationSearch:
      .navigationSearch
    case .editorSave:
      .editorSave
    case .editorUndo:
      .editorUndo
    case .editorRedo:
      .editorRedo
    case .paneSplit:
      .paneSplit
    case .paneFocus:
      .paneFocus
    case .paneMoveTab:
      .paneMoveTab
    case .paneClose:
      .paneClose
    case .paneToggleMaximize:
      .paneToggleMaximize
    case .paneEqualize:
      .paneEqualize
    case .terminalOpen:
      .terminalOpen
    case .terminalStop:
      .terminalStop
    case .terminalRecover:
      .terminalRecover
    case .agentList:
      .agentList
    case .agentStatus:
      .agentStatus
    case .agentLaunch:
      .agentLaunch
    case .agentReveal:
      .agentReveal
    case .agentInput:
      .agentInput
    case .agentInterrupt:
      .agentInterrupt
    case .agentStop:
      .agentStop
    case .worktreeList:
      .worktreeList
    case .worktreeCreate:
      .worktreeCreate
    case .worktreePrepareCleanup:
      .worktreePrepareCleanup
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
    case .gitReview:
      .gitReview
    case .gitPrepareAdoption:
      .gitPrepareAdoption
    case .gitAdopt:
      .gitAdopt
    case .notificationList:
      .notificationList
    case .notificationSetMute:
      .notificationSetMute
    }
  }
}

struct ProjectTargetCommand: Sendable {
  let projectID: UUID
}

enum ClairCommandResult: Equatable, Sendable {
  case project(Project)
  case gitStatus(ProjectGitSnapshot)
  case gitDiff(ProjectGitDiff)
  case adapter(CommandAdapterResult)
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
  case navigation(ProjectNavigationError)
  case editor(ProjectEditorError)
  case worktree(ManagedWorktreeError)
  case review(ProjectBranchReviewError)
  case agent(AgentControlError)
  case adapter(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let commandID, let reason):
      "Command \(commandID.rawValue) is unavailable: \(reason)"
    case .project(let error):
      error.localizedDescription
    case .git(let error):
      error.localizedDescription
    case .navigation(let error):
      error.localizedDescription
    case .editor(let error):
      error.localizedDescription
    case .worktree(let error):
      error.localizedDescription
    case .review(let error):
      error.localizedDescription
    case .agent(let error):
      error.localizedDescription
    case .adapter(let message):
      message
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
        id: .navigationOpenFile,
        title: "Open File at Location",
        risk: .additive,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .navigationQuickOpen,
        title: "Quick Open File",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .navigationSearch,
        title: "Search Project Files",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .editorSave,
        title: "Save Editor Buffer",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .editorUndo,
        title: "Undo Editor Change",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .editorRedo,
        title: "Redo Editor Change",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .paneSplit,
        title: "Split Pane",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .paneFocus,
        title: "Focus Pane",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .paneMoveTab,
        title: "Move Active Tab",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .paneClose,
        title: "Close Pane",
        risk: .destructive,
        aiAvailable: false
      ),
      CommandDescriptor(
        id: .paneToggleMaximize,
        title: "Toggle Pane Maximize",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .paneEqualize,
        title: "Equalize Pane Splits",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .terminalOpen,
        title: "Open Terminal",
        risk: .additive,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .terminalStop,
        title: "Stop Terminal",
        risk: .destructive,
        aiAvailable: false
      ),
      CommandDescriptor(
        id: .terminalRecover,
        title: "Recover Terminal Session",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .agentList,
        title: "List Agent Sessions",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .agentStatus,
        title: "Show Agent Status",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .agentLaunch,
        title: "Launch Agent",
        risk: .external,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .agentReveal,
        title: "Reveal Agent Session",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .agentInput,
        title: "Send Agent Input",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .agentInterrupt,
        title: "Interrupt Agent",
        risk: .write,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .agentStop,
        title: "Stop Agent",
        risk: .destructive,
        aiAvailable: false
      ),
      CommandDescriptor(
        id: .worktreeList,
        title: "List Managed Worktrees",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .worktreeCreate,
        title: "Create Managed Worktree",
        risk: .external,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .worktreePrepareCleanup,
        title: "Prepare Worktree Cleanup",
        risk: .destructive,
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
      CommandDescriptor(
        id: .gitReview,
        title: "Review Git Worktree Branch",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .gitPrepareAdoption,
        title: "Prepare Git Branch Adoption",
        risk: .destructive,
        aiAvailable: false
      ),
      CommandDescriptor(
        id: .gitAdopt,
        title: "Adopt Git Worktree Branch",
        risk: .destructive,
        aiAvailable: false
      ),
      CommandDescriptor(
        id: .notificationList,
        title: "List Project Notifications",
        risk: .read,
        aiAvailable: true
      ),
      CommandDescriptor(
        id: .notificationSetMute,
        title: "Set Notification Mute",
        risk: .write,
        aiAvailable: true
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
    case .navigationOpenFile(let input):
      availability = pathAvailability(input.path, action: "open")
    case .navigationQuickOpen(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "quick open a file in"
      )
    case .navigationSearch(let input):
      availability = projectValueAvailability(
        projectID: input.projectID,
        value: input.query,
        valueName: "search query",
        in: state,
        action: "search"
      )
    case .editorSave(let input), .editorUndo(let input), .editorRedo(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "edit"
      )
    case .paneSplit(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "split"
      )
    case .paneFocus(let input), .paneMoveTab(let input), .paneClose(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "change the pane layout of"
      )
    case .paneToggleMaximize(let input), .paneEqualize(let input), .terminalOpen(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "change"
      )
    case .terminalStop(let input), .terminalRecover(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "change"
      )
    case .agentList, .agentStatus, .agentInput, .agentInterrupt, .agentStop:
      availability = .available
    case .agentLaunch(let input):
      availability = projectValueAvailability(
        projectID: input.projectID,
        value: input.profileID,
        valueName: "agent profile",
        in: state,
        action: "launch an agent in"
      )
    case .agentReveal(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "reveal an agent session in"
      )
    case .worktreeList(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "list worktrees in"
      )
    case .worktreeCreate(let input):
      availability = projectValueAvailability(
        projectID: input.projectID,
        value: input.branch,
        valueName: "worktree branch",
        in: state,
        action: "create a worktree in"
      )
    case .worktreePrepareCleanup(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "prepare worktree cleanup in"
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
    case .gitReview(let input), .gitPrepareAdoption(let input):
      availability = gitProjectAvailability(
        for: input.projectID,
        in: state,
        action: "review Git worktrees"
      )
    case .gitAdopt(let input):
      availability = gitProjectAvailability(
        for: input.projectID,
        in: state,
        action: "adopt a Git worktree branch"
      )
    case .notificationList(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "list notifications for"
      )
    case .notificationSetMute(let input):
      availability = projectAvailability(
        for: input.projectID,
        in: state,
        action: "change notification settings for"
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

  private func projectValueAvailability(
    projectID: UUID,
    value: String,
    valueName: String,
    in state: ProjectCommandState,
    action: String
  ) -> CommandAvailability {
    let projectState = projectAvailability(for: projectID, in: state, action: action)
    guard projectState.isAvailable else {
      return projectState
    }
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .unavailable("The \(valueName) cannot be empty.")
    }
    return .available
  }

  private func pathAvailability(_ path: String, action: String) -> CommandAvailability {
    guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .unavailable("The path to \(action) cannot be empty.")
    }
    return .available
  }

  func requiresApproval(for commandID: ClairCommandID) -> Bool {
    guard let descriptor = descriptor(for: commandID) else {
      return true
    }
    switch descriptor.risk {
    case .read:
      return false
    case .additive, .write, .destructive, .external:
      return true
    }
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

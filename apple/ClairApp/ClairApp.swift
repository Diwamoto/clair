import SwiftUI

@main
struct ClairApplication: App {
  private let bootstrapState: BootstrapState
  @StateObject private var projectWorkspace: ProjectWorkspaceModel
  @StateObject private var agentWorkflow: AgentWorkflowCoordinator
  @StateObject private var worktreeCoordinator: ProjectWorktreeCoordinator
  @StateObject private var commandSurface: CommandSurfaceModel

  init() {
    let profile = ClairRuntimeProfile.current
    bootstrapState = BootstrapState.load(profile: profile)
    let workspace = ProjectWorkspaceModel(
      store: ProjectStore.makeDefault(for: profile)
    )
    _projectWorkspace = StateObject(
      wrappedValue: workspace
    )
    _agentWorkflow = StateObject(
      wrappedValue: AgentWorkflowCoordinator(profile: profile)
    )
    _worktreeCoordinator = StateObject(
      wrappedValue: ProjectWorktreeCoordinator.makeDefault(for: profile)
    )
    _commandSurface = StateObject(
      wrappedValue: CommandSurfaceModel(workspace: workspace)
    )
  }

  var body: some Scene {
    WindowGroup {
      ContentView(
        state: bootstrapState,
        workspace: projectWorkspace,
        agentWorkflow: agentWorkflow,
        worktreeCoordinator: worktreeCoordinator
      )
    }
    .defaultSize(width: 980, height: 620)
    .commands {
      ClairCommandMenu(surface: commandSurface)
    }

    Window("Command Window", id: "command-window") {
      CommandWindowView(surface: commandSurface)
    }
    .defaultSize(width: 720, height: 560)
  }
}

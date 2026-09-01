import SwiftUI

@main
struct ClairApplication: App {
  private let bootstrapState: BootstrapState
  @StateObject private var projectWorkspace: ProjectWorkspaceModel
  @StateObject private var agentWorkflow: AgentWorkflowCoordinator
  @StateObject private var worktreeCoordinator: ProjectWorktreeCoordinator

  init() {
    let profile = ClairRuntimeProfile.current
    bootstrapState = BootstrapState.load(profile: profile)
    _projectWorkspace = StateObject(
      wrappedValue: ProjectWorkspaceModel(
        store: ProjectStore.makeDefault(for: profile)
      )
    )
    _agentWorkflow = StateObject(
      wrappedValue: AgentWorkflowCoordinator(profile: profile)
    )
    _worktreeCoordinator = StateObject(
      wrappedValue: ProjectWorktreeCoordinator.makeDefault(for: profile)
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
  }
}

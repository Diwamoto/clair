import SwiftUI

@main
struct ClairApplication: App {
  private let bootstrapState: BootstrapState
  @StateObject private var projectWorkspace: ProjectWorkspaceModel
  @StateObject private var agentWorkflow: AgentWorkflowCoordinator

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
  }

  var body: some Scene {
    WindowGroup {
      ContentView(
        state: bootstrapState,
        workspace: projectWorkspace,
        agentWorkflow: agentWorkflow
      )
    }
    .defaultSize(width: 980, height: 620)
  }
}

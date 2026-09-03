import SwiftUI

@main
struct ClairApplication: App {
  @NSApplicationDelegateAdaptor(ClairApplicationDelegate.self)
  private var applicationDelegate
  private let bootstrapState: BootstrapState
  @StateObject private var projectWorkspace: ProjectWorkspaceModel
  @StateObject private var agentWorkflow: AgentWorkflowCoordinator
  @StateObject private var worktreeCoordinator: ProjectWorktreeCoordinator
  @StateObject private var commandSurface: CommandSurfaceModel
  @StateObject private var commandServer: CommandIPCServer
  @StateObject private var updater: ClairUpdateCoordinator

  init() {
    let profile = ClairRuntimeProfile.current
    bootstrapState = BootstrapState.load(profile: profile)
    let updateConfiguration = ClairUpdateConfiguration.live(profile: profile)
    ClairUpdateRecovery.markSuccessfulLaunchIfNeeded(
      profile: profile,
      applicationSupportURL: updateConfiguration.applicationSupportURL
    )
    let workspace = ProjectWorkspaceModel(
      store: ProjectStore.makeDefault(for: profile)
    )
    _projectWorkspace = StateObject(
      wrappedValue: workspace
    )
    let agentWorkflow = AgentWorkflowCoordinator(profile: profile)
    agentWorkflow.registerExistingSessions(in: workspace)
    workspace.reattachRuntimeSessions()
    let worktreeCoordinator = ProjectWorktreeCoordinator.makeDefault(for: profile)
    _agentWorkflow = StateObject(wrappedValue: agentWorkflow)
    _worktreeCoordinator = StateObject(wrappedValue: worktreeCoordinator)
    _commandSurface = StateObject(
      wrappedValue: CommandSurfaceModel(workspace: workspace)
    )
    let router = CommandAdapterRouter(
      workspace: workspace,
      agentWorkflow: agentWorkflow,
      worktreeCoordinator: worktreeCoordinator
    )
    let commandServer = CommandIPCServer(profile: profile, router: router)
    _commandServer = StateObject(wrappedValue: commandServer)
    commandServer.start()

    let updater = ClairUpdateCoordinator(
      profile: profile,
      configuration: updateConfiguration,
      restartHandler: {
        (NSApp.delegate as? ClairApplicationDelegate)?.prepareForUpdateRestart()
        NSApplication.shared.terminate(nil)
      }
    )
    _updater = StateObject(wrappedValue: updater)
    applicationDelegate.onNormalTermination = { [weak workspace] in
      workspace?.terminateAllTerminalSessions()
    }
    updater.startAutomaticChecks()
  }

  var body: some Scene {
    WindowGroup {
      ContentView(
        state: bootstrapState,
        workspace: projectWorkspace,
        agentWorkflow: agentWorkflow,
        worktreeCoordinator: worktreeCoordinator,
        updater: updater
      )
    }
    .defaultSize(width: 980, height: 620)
    .commands {
      ClairCommandMenu(surface: commandSurface)
      ClairUpdateCommands(updater: updater)
    }

    Window("Command Window", id: "command-window") {
      CommandWindowView(surface: commandSurface)
    }
    .defaultSize(width: 720, height: 560)
  }
}

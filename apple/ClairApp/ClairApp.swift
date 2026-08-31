import SwiftUI

@main
struct ClairApplication: App {
  private let bootstrapState: BootstrapState
  @StateObject private var projectWorkspace: ProjectWorkspaceModel

  init() {
    let profile = ClairRuntimeProfile.current
    bootstrapState = BootstrapState.load(profile: profile)
    _projectWorkspace = StateObject(
      wrappedValue: ProjectWorkspaceModel(
        store: ProjectStore.makeDefault(for: profile)
      )
    )
  }

  var body: some Scene {
    WindowGroup {
      ContentView(state: bootstrapState, workspace: projectWorkspace)
    }
    .defaultSize(width: 980, height: 620)
  }
}

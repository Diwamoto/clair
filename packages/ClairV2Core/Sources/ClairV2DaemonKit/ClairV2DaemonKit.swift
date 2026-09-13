import ClairV2Agent
import ClairV2Shared
import ClairV2Terminal
import ClairV2Workspace

public enum ClairV2DaemonModule {
  public static let component = ClairV2Component.daemon
  public static let name = "ClairV2Daemon"
  public static let foundationVersion = ClairV2Foundation.version
  public static let dependencies = [
    ClairV2AgentModule.name,
    ClairV2TerminalModule.name,
    ClairV2WorkspaceModule.name,
  ]

}

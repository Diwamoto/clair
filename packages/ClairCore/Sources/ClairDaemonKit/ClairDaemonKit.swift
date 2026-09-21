import ClairAgent
import ClairShared
import ClairTerminal
import ClairWorkspace

public enum ClairDaemonModule {
  public static let component = ClairComponent.daemon
  public static let name = "ClairDaemon"
  public static let foundationVersion = ClairFoundation.version
  public static let dependencies = [
    ClairAgentModule.name,
    ClairTerminalModule.name,
    ClairWorkspaceModule.name,
  ]

}

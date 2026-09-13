import ClairV2Agent
import ClairV2DaemonKit
import ClairV2Review
import ClairV2Shared
import ClairV2Terminal
import ClairV2Workspace

public enum ClairV2AppComposition {
  public static let packageName = "ClairV2Core"
  public static let componentNames = [
    ClairV2WorkspaceModule.name,
    ClairV2AgentModule.name,
    ClairV2ReviewModule.name,
    ClairV2TerminalModule.name,
    ClairV2DaemonModule.name,
  ]

}

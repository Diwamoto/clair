import ClairAgent
import ClairDaemonKit
import ClairReview
import ClairShared
import ClairTerminal
import ClairWorkspace

public enum ClairAppComposition {
  public static let packageName = "Clair"
  public static let componentNames = [
    ClairWorkspaceModule.name,
    ClairAgentModule.name,
    ClairReviewModule.name,
    ClairTerminalModule.name,
    ClairDaemonModule.name,
  ]

}

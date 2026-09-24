import ClairAgent
import ClairReview
import ClairShared
import ClairTransport
import ClairWorkspace

public enum ClairMobileModule {
  public static let component = ClairComponent.mobile
  public static let name = "ClairMobileKit"
  public static let dependencies = [
    ClairAgentModule.name,
    ClairReviewModule.name,
    ClairWorkspaceModule.name,
  ]

}

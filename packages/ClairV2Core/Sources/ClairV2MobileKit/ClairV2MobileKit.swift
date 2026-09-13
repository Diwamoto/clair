import ClairV2Agent
import ClairV2Review
import ClairV2Shared
import ClairV2Transport
import ClairV2Workspace

public enum ClairV2MobileModule {
  public static let component = ClairV2Component.mobile
  public static let name = "ClairV2MobileKit"
  public static let dependencies = [
    ClairV2AgentModule.name,
    ClairV2ReviewModule.name,
    ClairV2WorkspaceModule.name,
  ]

}

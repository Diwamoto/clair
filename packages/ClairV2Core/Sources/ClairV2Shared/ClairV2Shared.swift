/// The small, dependency-free identity shared by every v2 target.
public enum ClairV2Component: String, CaseIterable, Sendable {
  case workspace
  case agent
  case review
  case terminal
  case daemon
  case mobile
}

public enum ClairV2Foundation {
  public static let version = "0.1.0"
  public static let components = ClairV2Component.allCases

}

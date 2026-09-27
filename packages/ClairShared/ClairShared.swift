/// The small, dependency-free identity shared by every target.
public enum ClairComponent: String, CaseIterable, Sendable {
  case workspace
  case agent
  case review
  case terminal
  case daemon
  case mobile
}

public enum ClairFoundation {
  public static let version = "0.1.0"
  public static let components = ClairComponent.allCases

}

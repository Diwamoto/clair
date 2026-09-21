import Testing

@testable import ClairAgent
@testable import ClairAppKit
@testable import ClairDaemonKit
@testable import ClairMobileKit
@testable import ClairReview
@testable import ClairShared
@testable import ClairTerminal
@testable import ClairWorkspace

@Test
func coreDeclaresTheAcceptedModuleBoundaries() {
  #expect(ClairFoundation.version == "0.1.0")
  #expect(
    ClairFoundation.components == [.workspace, .agent, .review, .terminal, .daemon, .mobile])
  #expect(ClairWorkspaceModule.component == .workspace)
  #expect(ClairAgentModule.component == .agent)
  #expect(ClairReviewModule.component == .review)
  #expect(ClairTerminalModule.component == .terminal)
  #expect(ClairDaemonModule.component == .daemon)
  #expect(ClairMobileModule.component == .mobile)
}

@Test
func appCompositionUsesOnlyClairComponents() {
  #expect(ClairAppComposition.packageName == "ClairCore")
  #expect(
    ClairAppComposition.componentNames == [
      "ClairWorkspace",
      "ClairAgent",
      "ClairReview",
      "ClairTerminal",
      "ClairDaemon",
    ])
}

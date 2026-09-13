import Testing

@testable import ClairV2Agent
@testable import ClairV2AppKit
@testable import ClairV2DaemonKit
@testable import ClairV2MobileKit
@testable import ClairV2Review
@testable import ClairV2Shared
@testable import ClairV2Terminal
@testable import ClairV2Workspace

@Test
func v2CoreDeclaresTheAcceptedModuleBoundaries() {
  #expect(ClairV2Foundation.version == "0.1.0")
  #expect(
    ClairV2Foundation.components == [.workspace, .agent, .review, .terminal, .daemon, .mobile])
  #expect(ClairV2WorkspaceModule.component == .workspace)
  #expect(ClairV2AgentModule.component == .agent)
  #expect(ClairV2ReviewModule.component == .review)
  #expect(ClairV2TerminalModule.component == .terminal)
  #expect(ClairV2DaemonModule.component == .daemon)
  #expect(ClairV2MobileModule.component == .mobile)
}

@Test
func v2AppCompositionUsesOnlyV2Components() {
  #expect(ClairV2AppComposition.packageName == "ClairV2Core")
  #expect(
    ClairV2AppComposition.componentNames == [
      "ClairV2Workspace",
      "ClairV2Agent",
      "ClairV2Review",
      "ClairV2Terminal",
      "ClairV2Daemon",
    ])
}

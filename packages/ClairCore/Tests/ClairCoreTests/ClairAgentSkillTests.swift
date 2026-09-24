import XCTest

@testable import ClairWorkspace

final class ClairAgentSkillTests: XCTestCase {
  func testShippedSkillMatchesRepoSkill() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../.agents/skills/clair-agents/SKILL.md")
    XCTAssertEqual(ClairAgentSkill.markdown, try String(contentsOf: repo, encoding: .utf8))
  }

  func testInstallWritesEveryTarget() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-skill-\(UUID().uuidString)")
    XCTAssertFalse(ClairAgentSkill.isInstalled(home: home))
    try ClairAgentSkill.install(home: home)
    XCTAssertTrue(ClairAgentSkill.isInstalled(home: home))
  }
}

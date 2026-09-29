import XCTest

@testable import ClairWorkspace

final class ClairPreviewSkillTests: XCTestCase {
  func testShippedSkillMatchesRepoSkill() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../.agents/skills/clair-preview/SKILL.md")
    XCTAssertEqual(ClairPreviewSkill.markdown, try String(contentsOf: repo, encoding: .utf8))
  }

  func testBundleInstallsAndRemovesBothSkills() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-skills-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertFalse(ClairSkills.isInstalled(home: home))
    try ClairSkills.install(home: home)
    XCTAssertTrue(ClairSkills.isInstalled(home: home))
    try ClairSkills.uninstall(home: home)
    XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/clair-preview").path))
  }

  func testBundleDoesNotOverwriteEditedSkill() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-skills-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    try ClairAgentSkill.install(home: home)
    let edited = ClairAgentSkill.targets(home: home)[0]
    try "mine".write(to: edited, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try ClairSkills.install(home: home))
    XCTAssertEqual(try String(contentsOf: edited, encoding: .utf8), "mine")
    XCTAssertFalse(ClairPreviewSkill.isInstalled(home: home))
  }
}

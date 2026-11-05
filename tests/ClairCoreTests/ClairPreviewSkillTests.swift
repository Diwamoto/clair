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

  func testBundleBacksUpEditedSkillAndUpdates() throws {
    let home = URL.temporaryDirectory.appending(path: "clair-skills-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let edited = ClairSkills.todoTargets(home)[0]
    try FileManager.default.createDirectory(at: edited.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "old".write(to: edited, atomically: true, encoding: .utf8)
    try ClairSkills.install(home: home)
    XCTAssertTrue(ClairSkills.isInstalled(home: home))
    XCTAssertEqual(try String(contentsOf: edited.appendingPathExtension("bak"), encoding: .utf8), "old")
  }
}

import Testing
@testable import ClairWorkspace

@Suite struct AutoApproveTests {
  @Test func offByDefaultAndOnlyForClairTerminals() {
    var s = WorkbenchState()
    #expect(!s.autoApproves("agent.launch", risk: .external, caller: "root#1"))
    s.toggles[WorkbenchState.autoApproveKey("agent.launch")] = true
    #expect(s.autoApproves("agent.launch", risk: .external, caller: "root#1"))
    #expect(!s.autoApproves("agent.launch", risk: .external, caller: nil))
  }

  @Test func neverAboveTheFixedRiskOrOutsideTheList() {
    var s = WorkbenchState()
    for id in ["tab.close", "git.commit"] { s.toggles[WorkbenchState.autoApproveKey(id)] = true }
    #expect(s.autoApproves("tab.close", risk: .write, caller: "root#1"))
    #expect(!s.autoApproves("tab.close", risk: .destructive, caller: "root#1"))  // dirty tab
    #expect(!s.autoApproves("git.commit", risk: .write, caller: "root#1"))
  }

  @Test func listedCommandsAreAIAvailableAndSettingsAreUserOnly() {
    let r = CommandRegistry.workbench
    for id in WorkbenchState.autoApproveCommands.keys { #expect(r.commands.first { $0.id == id }?.aiAvailable == true, "\(id)") }
    #expect(r.commands.first { $0.id == "settings.set" }?.aiAvailable == false)
  }
}

import Foundation
import XCTest

@testable import ClairWorkspace

/// V03 threat tests: the gate, not the adapter, is the authority.
final class WorkbenchMCPTests: XCTestCase {
  private let reg = CommandRegistry.workbench
  private func gate(_ id: String, _ input: CommandInput = [:], state: WorkbenchState = WorkbenchState(), approve: Bool = false)
    -> (Result<CommandResult, CommandError>, asked: Int, ran: Int)
  {
    var asked = 0, ran = 0
    let r = MCPGate.handle(
      WorkbenchIPCRequest(command: id, input: input, via: .mcp), registry: reg, snapshot: { state },
      approve: { _, _, _ in asked += 1; return approve }, run: { _, _ in ran += 1; return .success(.ok) })
    return (r, asked, ran)
  }

  func testAIUnavailableCommandRejectedWithoutPrompt() {
    for id in ["agent.launch", "project.open", "settings.set", "palette.commands"] {
      let g = gate(id, ["path": .string("/"), "profile": .string("claude"), "key": .string("showQuota"), "value": .bool(true)])
      XCTAssertEqual(try? g.0.get(), nil); XCTAssertEqual(g.asked + g.ran, 0, id)
      if case .failure(let e) = g.0 { XCTAssertEqual(e.code, .notAvailableToAI, id) }
    }
  }

  func testWriteAndDestructiveNeedApprovalAndDenialBlocks() {
    var s = WorkbenchState(); s.dirty.insert(s.active!)
    let denied = gate("tab.close", state: s)
    XCTAssertEqual(denied.asked, 1); XCTAssertEqual(denied.ran, 0)
    if case .failure(let e) = denied.0 { XCTAssertEqual(e.code, .denied) } else { XCTFail() }
    let ok = gate("tab.close", state: s, approve: true)
    XCTAssertEqual(ok.ran, 1)
    // read risk runs with no prompt
    let read = gate("state.snapshot"); XCTAssertEqual(read.asked, 0); XCTAssertEqual(read.ran, 1)
  }

  func testInvalidInputFailsBeforePrompt() {
    let g = gate("pane.focus", ["id": .int(99)])
    XCTAssertEqual(g.asked + g.ran, 0)
  }

  func testAdapterListsOnlyAIAvailableAndIgnoresClaimedRisk() throws {
    var seen: WorkbenchIPCRequest?
    let list = try XCTUnwrap(MCPServer.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, call: { _ in WorkbenchIPCReply() }))
    XCTAssertTrue(list.contains("state.snapshot")); XCTAssertFalse(list.contains("agent.launch")); XCTAssertFalse(list.contains("settings.set"))
    let denied = MCPServer.respond(to: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agent.launch","arguments":{"profile":"claude","risk":"read"}}}"#, call: { seen = $0; return WorkbenchIPCReply() })
    XCTAssertNil(seen); XCTAssertTrue(try XCTUnwrap(denied).contains("unknown tool"))
    _ = MCPServer.respond(to: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"pane.focus","arguments":{"id":1}}}"#, call: { seen = $0; return WorkbenchIPCReply() })
    XCTAssertEqual(seen?.via, .mcp)
    XCTAssertNil(MCPServer.respond(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, call: { _ in WorkbenchIPCReply() }))
  }
}
